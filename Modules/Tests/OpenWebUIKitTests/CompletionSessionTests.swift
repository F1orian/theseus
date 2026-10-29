import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Synchronization
import Testing

/// A connector whose connections never open (WebSocket blocked by a proxy).
struct RefusingConnector: WebSocketConnecting {
    func connect(to url: URL) async throws -> any WebSocketConnection {
        throw URLError(.cannotConnectToHost)
    }
}

/// Collects `ChatEvent`s for one Message until `until` says stop (bounded by a timeout).
func collect(
    _ events: AsyncStream<ChatEvent>,
    messageID: String,
    timeout: Duration = .seconds(10),
    until done: @escaping @Sendable (ResponseState, ChatEvent) -> Bool = { state, _ in state.isFinished }
) async -> (state: ResponseState, events: [ChatEvent]) {
    await withTaskGroup(of: (ResponseState, [ChatEvent])?.self) { group in
        group.addTask {
            var state = ResponseState()
            var seen: [ChatEvent] = []
            for await event in events where event.messageID == messageID {
                seen.append(event)
                if case .response(let response) = event.kind { state.apply(response) }
                if done(state, event) { break }
            }
            return (state, seen)
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? (ResponseState(), [])
    }
}

@Suite("CompletionSession")
struct CompletionSessionTests {
    let transport = StubTransport()

    func session(replay: SocketReplay?, connector: (any WebSocketConnecting)? = nil) -> CompletionSession {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
        let socketConnector = connector ?? replay
        let socket = socketConnector.map { connector in
            SocketIOClient(server: Fixture.serverURL, connector: connector, backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20))) { "jwt" }
        }
        return CompletionSession(client: client, socket: socket, joinTimeout: .milliseconds(500))
    }

    func body(of request: URLRequest?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request?.httpBody))
    }

    @Test func socketModeSendsTheWebClientShapeAndStreamsEvents() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let session = session(replay: replay)
        let events = await session.events()
        await session.start()

        let receipt = try await session.send(CompletionRequest(
            chatID: nil,
            modelID: "claude-haiku-5-5",
            prompt: "[theseus-test] In two short sentences, what is a maze?",
            userMessageID: ids.userMessageID,
            assistantMessageID: ids.assistantMessageID,
            features: ["web_search": false]
        ))
        #expect(receipt.transport == .socket)
        #expect(receipt.chatID == ids.chatID)

        let sent = try body(of: transport.requests.last)
        #expect(sent[path: "session_id"]?.stringValue == "gh5iwfrnuZ-cZvaJAAAF")
        #expect(sent[path: "parent_id"] == .null)
        #expect(sent[path: "chat_id"] == nil)
        #expect(sent[path: "user_message.id"]?.stringValue == ids.userMessageID)
        #expect(sent[path: "background_tasks.title_generation"]?.boolValue == true)
        guard case .array(let messageIDs)? = sent[path: "message_ids"] else { Issue.record("no message_ids"); return }
        #expect(messageIDs.first?[path: "message_id"]?.stringValue == ids.assistantMessageID)

        let (state, seen) = await collect(events, messageID: ids.assistantMessageID)
        #expect(state.phase == .completed)
        #expect(state.text.hasPrefix("A maze is a branching puzzle"))
        #expect(seen.contains { $0.kind == .title("Maze Definition") })
        await session.shutdown()
    }

    @Test func stopEndsTheResponseAndKeepsThePartialText() async throws {
        let fixture = StreamFixture("stop")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let replay = try SocketReplay(scenario: "stop")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        transport.stub("POST", "api/tasks/chat/\(chatID)/stop") { _ in
            replay.open(.stop)
            return (200, (try? fixture.data("stop.json")) ?? Data())
        }
        let session = session(replay: replay)
        let events = await session.events()
        await session.start()
        _ = try await session.send(CompletionRequest(
            chatID: nil, modelID: "claude-haiku-5-5", prompt: "story",
            userMessageID: ids.userMessageID, assistantMessageID: ids.assistantMessageID
        ))
        let streaming = await collect(events, messageID: ids.assistantMessageID) { state, _ in state.phase == .streaming }
        #expect(streaming.state.phase == .streaming)
        try await session.stop(chatID: chatID)

        let (state, _) = await collect(events, messageID: ids.assistantMessageID)
        #expect(state.phase == .stopped)
        #expect(state.text.hasPrefix("**The Long Way Round**"))
        await session.shutdown()
    }

    @Test func answeringAClarifyingQuestionResolvesThePausedToolCall() async throws {
        let fixture = StreamFixture("askuser")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let replay = try SocketReplay(scenario: "askuser")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        transport.stub("POST", "api/v1/chats/\(chatID)/messages/\(ids.assistantMessageID)/resolve") { _ in
            replay.open(.resolve)
            return (200, (try? fixture.data("resolve.json")) ?? Data())
        }
        let session = session(replay: replay)
        let events = await session.events()
        await session.start()
        _ = try await session.send(CompletionRequest(
            chatID: nil, modelID: "claude-haiku-5-5", prompt: "trip",
            userMessageID: ids.userMessageID, assistantMessageID: ids.assistantMessageID
        ))
        let paused = await collect(events, messageID: ids.assistantMessageID) { state, _ in state.phase == .awaitingAnswer }
        let questions = try #require(paused.state.pendingQuestions)
        let first = try #require(questions.questions.first?.options.first)
        let second = try #require(questions.questions.last?.options.last)
        try await session.answer(
            questions,
            with: ["destination_type": .option(index: 0, first), "budget": .option(index: 1, second)],
            chatID: chatID,
            messageID: ids.assistantMessageID
        )

        let resolve = try body(of: transport.requests.last)
        #expect(resolve[path: "action"]?.stringValue == "answer")
        #expect(resolve[path: "call_id"]?.stringValue == questions.callID)
        #expect(resolve[path: "answers.budget.option_index"]?.intValue == 1)
        #expect(resolve[path: "answers.destination_type.label"]?.stringValue == first.label)

        let (state, _) = await collect(events, messageID: ids.assistantMessageID)
        #expect(state.phase == .completed)
        #expect(!state.text.isEmpty)
        await session.shutdown()
    }

    @Test func dismissingAQuestionRejectsTheCall() async throws {
        transport.stub("POST", "api/v1/chats/c/messages/m/resolve", body: Data(#"{"status":true,"task_ids":[]}"#.utf8))
        let session = session(replay: nil)
        let questions = ClarifyingQuestions(callID: "call", questions: [])
        try await session.answer(questions, with: nil, chatID: "c", messageID: "m")
        let sent = try body(of: transport.requests.last)
        #expect(sent[path: "action"]?.stringValue == "reject")
        #expect(sent[path: "answers"] == nil)
    }

    @Test func withoutASocketItStreamsSSEAndSavesTheTurn() async throws {
        let fixture = StreamFixture("sse")
        transport.stub("POST", "api/chat/completions", body: try fixture.data("reasoning.txt"))
        transport.stub("POST", "api/v1/chats/new", body: try StreamFixture("plain").data("chat.after-first.json"))
        let session = session(replay: nil)
        let events = await session.events()

        let request = CompletionRequest(chatID: nil, modelID: "claude-haiku-5-5", prompt: "6 × 7?", history: [.init(role: .user, content: "earlier")])
        let receipt = try await session.send(request)
        #expect(receipt.transport == .serverSentEvents)
        #expect(receipt.chatID == nil)
        let sent = try body(of: transport.requests.first)
        #expect(sent[path: "session_id"] == nil)
        #expect(sent[path: "chat_id"] == nil)
        guard case .array(let messages)? = sent[path: "messages"] else { Issue.record("no messages"); return }
        #expect(messages.count == 2)

        let (state, seen) = await collect(events, messageID: request.assistantMessageID) { _, event in
            if case .title = event.kind { return true }
            return false
        }
        #expect(state.phase == .completed)
        #expect(state.text == "42")
        #expect(state.parts.first.map { if case .thinking = $0 { true } else { false } } == true)
        #expect(seen.last?.chatID == "00000000-0000-4000-8000-0000000c0001")

        let saved = try body(of: transport.requests.last)
        #expect(saved[path: "chat.history.currentId"]?.stringValue == request.assistantMessageID)
        #expect(saved[path: "chat.history.messages.\(request.assistantMessageID).content"]?.stringValue == "42")
    }

    @Test func fallsBackToSSEWhenTheSocketCannotJoin() async throws {
        transport.stub("POST", "api/chat/completions", body: try StreamFixture("sse").data("plain.txt"))
        transport.stub("POST", "api/v1/chats/c1", body: try StreamFixture("plain").data("chat.final.json"))
        let session = session(replay: nil, connector: RefusingConnector())
        await session.start()
        let events = await session.events()
        let request = CompletionRequest(chatID: "c1", modelID: "claude-haiku-5-5", prompt: "Theseus?", parentMessageID: "a0")
        let receipt = try await session.send(request)
        #expect(receipt.transport == .serverSentEvents)
        let (state, _) = await collect(events, messageID: request.assistantMessageID)
        #expect(state.text.hasPrefix("Theseus's mouse was"))
        await session.shutdown()
    }

    @Test func httpRejectionsSurfaceAsErrors() async throws {
        transport.stub("POST", "api/chat/completions", status: 400, body: Data(#"{"detail":"Model not found"}"#.utf8))
        let session = session(replay: nil)
        await #expect(throws: OpenWebUIError.server(status: 400, detail: "Model not found")) {
            _ = try await session.send(CompletionRequest(chatID: nil, modelID: "nope", prompt: "hi"))
        }
    }

    @Test func sseErrorsMidStreamFailTheResponse() async throws {
        transport.stub("POST", "api/chat/completions", body: Data("data: {\"error\":{\"message\":\"upstream down\"}}\n\ndata: [DONE]\n\n".utf8))
        let session = session(replay: nil)
        let events = await session.events()
        let request = CompletionRequest(chatID: nil, modelID: "m", prompt: "hi")
        _ = try await session.send(request)
        let (state, _) = await collect(events, messageID: request.assistantMessageID)
        #expect(state.phase == .failed)
        #expect(state.error == "upstream down")
    }
}

@Suite("Chat endpoints")
struct ChatEndpointTests {
    let transport = StubTransport()
    var client: OpenWebUIClient {
        OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
    }

    @Test func tasksHealthAndStop() async throws {
        transport.stub("GET", "api/tasks/chat/c", body: try StreamFixture("resume").data("tasks.json"))
        transport.stub("GET", "health", body: Data(#"{"status":true}"#.utf8))
        transport.stub("POST", "api/tasks/chat/c/stop", body: try StreamFixture("stop").data("stop.json"))
        #expect(try await client.send(.chatTasks(id: "c")) == ["00000000-0000-4000-8000-0000000e0062"])
        #expect(try await client.send(.health))
        _ = try await client.send(.stopChat(id: "c"))
        #expect(transport.requests.last?.httpMethod == "POST")
    }
}
