@testable import ChatFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// A token source for tests.
final class StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

let haiku = Model(
    id: "claude-haiku-5-5",
    name: "Claude Haiku",
    ownedBy: "openai",
    capabilities: ModelCapabilities(raw: ["citations": true, "web_search": true]),
    defaultFeatureIDs: ["web_search"]
)

@MainActor
func makeServices(transport: StubTransport, replay: SocketReplay?, capabilities: Set<Capability> = Set(Capability.allCases)) -> ChatServices {
    let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
    let socket = replay.map { replay in
        SocketIOClient(server: Fixture.serverURL, connector: replay, backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20))) { "jwt" }
    }
    let session = CompletionSession(client: client, socket: socket, joinTimeout: .milliseconds(800))
    let services = ChatServices(client: client, session: session, models: [haiku], defaultModelID: haiku.id) { _ in
        Capabilities(enabled: capabilities)
    }
    return services
}

/// Polls the main actor until `condition` holds (bounded).
@MainActor
func until(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Feeds the recorded ids into the next sends, so replayed events match.
@MainActor
func send(_ model: ConversationModel, _ prompt: String) async {
    model.draft = prompt
    await model.send()
}

@Suite("ConversationModel", .serialized)
@MainActor
struct ConversationModelTests {
    @Test func newChatStreamsAdoptsTheServerChatIDAndTitle() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { request in
            replay.open(.completion)
            // Echo the recorded response for the recorded user id only.
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        var listChanges = 0
        services.onChatListChanged = { listChanges += 1 }

        #expect(model.isNewChat)
        #expect(!model.canSend)
        await send(model, "[theseus-test] What is a maze?")
        #expect(model.thread.map(\.role) == [.user, .assistant])
        #expect(model.isStreaming || model.response(for: model.thread[1]).isFinished)

        #expect(await until { !model.isStreaming })
        let response = model.response(for: model.thread[1])
        #expect(response.phase == .completed)
        #expect(response.text.hasPrefix("A maze is a branching puzzle"))
        #expect(model.chatID == ids.chatID)
        #expect(await until { model.title == "Maze Definition" })
        #expect(listChanges > 0)
        // The finished Response is written back into the tree.
        #expect(model.thread[1].isDone)
        #expect(services.conversation(chatID: try #require(ids.chatID)) === model)
        await services.stop()
    }

    @Test func stopEndsTheStreamAndKeepsText() async throws {
        let fixture = StreamFixture("stop")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "stop")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        transport.stub("POST", "api/tasks/chat/\(chatID)/stop") { _ in
            replay.open(.stop)
            return (200, (try? fixture.data("stop.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        await send(model, "story")
        #expect(await until { model.chatID != nil })
        #expect(model.isStreaming)
        await model.stop()
        #expect(await until { !model.isStreaming })
        let response = model.response(for: model.thread[1])
        #expect(response.phase == .stopped)
        #expect(response.text.hasPrefix("**The Long Way Round**"))
        await services.stop()
    }

    @Test func providerErrorShowsInlineAndRetryRegeneratesUnderTheSameUserMessage() async throws {
        let fixture = StreamFixture("error")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "error")
        let bodies = Mutex<[Data]>([])
        transport.stub("POST", "api/chat/completions") { request in
            bodies.withLock { $0.append(request.httpBody ?? Data()) }
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID, "retry-assistant"]).next
        await send(model, "Say hi.")
        #expect(await until { !model.isStreaming })
        let failed = model.response(for: model.thread[1])
        #expect(failed.phase == .failed)
        #expect(failed.error == "max_tokens: must be greater than or equal to 0")

        await model.retry(ids.assistantMessageID)
        let retried = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.withLock { $0.last }))
        #expect(retried[path: "user_message.id"]?.stringValue == ids.userMessageID)
        #expect(retried[path: "message_ids"].flatMap { if case .array(let items) = $0 { items.first?[path: "message_id"]?.stringValue } else { nil } } == "retry-assistant")
        #expect(retried[path: "chat_id"]?.stringValue == ids.chatID)
        #expect(model.thread.map(\.id) == [ids.userMessageID, "retry-assistant"])
        await services.stop()
    }

    @Test func sendFailuresAreRetriedAsAFreshSend() async throws {
        let transport = StubTransport()
        transport.stub("POST", "api/chat/completions", status: 503, body: Data(#"{"detail":"Upstream unavailable"}"#.utf8))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.newConversation()
        await send(model, "Hello")
        let assistant = try #require(model.thread.last)
        #expect(model.response(for: assistant).error == "Upstream unavailable")
        #expect(!model.isStreaming)

        transport.stub("POST", "api/chat/completions", body: try StreamFixture("sse").data("plain.txt"))
        transport.stub("POST", "api/v1/chats/new", body: try StreamFixture("plain").data("chat.after-first.json"))
        await model.retry(assistant.id)
        #expect(model.thread.count == 2)
        #expect(model.thread.first?.content == "Hello")
        #expect(await until { !model.isStreaming })
        #expect(model.response(for: try #require(model.thread.last)).text.hasPrefix("Theseus's mouse was"))
    }

    @Test func reopeningAnInProgressChatResumesTheStream() async throws {
        let fixture = StreamFixture("resume")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(chatID)", body: try fixture.data("chat.overlay.json"))
        transport.stub("GET", "api/tasks/chat/\(chatID)", body: try fixture.data("tasks.json"))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.streamingMessageID == ids.assistantMessageID)
        #expect(model.response(for: model.thread[1]).phase == .waiting)

        // Replayed deltas from the re-joined socket land on the resumed Response.
        for (envelope, ackID) in try fixture.envelopes(connection: 1) {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) { model.handle(event) }
        }
        #expect(await until { !model.isStreaming })
        let final = try await OpenWebUIClient(server: Fixture.serverURL, transport: {
            let stub = StubTransport()
            stub.stub("GET", "api/v1/chats/\(chatID)", body: (try? fixture.data("chat.final.json")) ?? Data())
            return stub
        }(), authorizer: StaticAuthorizer()).send(.chat(id: chatID)).chat
        #expect(model.response(for: model.thread[1]).text == final.tree[ids.assistantMessageID]?.response.text)
    }

    @Test func aStaleOverlayWithNoRunningTaskFinishesFromTheStoredChat() async throws {
        let fixture = StreamFixture("resume")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let transport = StubTransport()
        let served = Mutex(0)
        transport.stub("GET", "api/v1/chats/\(chatID)") { _ in
            let count = served.withLock { $0 += 1; return $0 }
            return (200, (try? fixture.data(count == 1 ? "chat.overlay.json" : "chat.final.json")) ?? Data())
        }
        transport.stub("GET", "api/tasks/chat/\(chatID)", body: try fixture.data("tasks.after.json"))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        #expect(!model.isStreaming)
        #expect(model.response(for: model.thread[1]).phase == .completed)
        #expect(!model.response(for: model.thread[1]).text.isEmpty)
    }

    @Test func clarifyingQuestionsPauseAndAnsweringResumes() async throws {
        let fixture = StreamFixture("askuser")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "askuser")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        transport.stub("POST", "api/v1/chats/\(chatID)/messages/\(ids.assistantMessageID)/resolve") { _ in
            replay.open(.resolve)
            return (200, (try? fixture.data("resolve.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        await send(model, "trip")
        #expect(await until { model.pendingQuestion != nil })
        #expect(!model.isStreaming)
        #expect(!model.canSend)
        let pending = try #require(model.pendingQuestion)
        #expect(pending.questions.questions.count == 2)

        let options = pending.questions.questions.map { ($0.id, ClarifyingQuestions.Answer.option(index: 0, $0.options[0])) }
        model.answer(Dictionary(uniqueKeysWithValues: options))
        #expect(model.pendingQuestion == nil)
        #expect(model.isStreaming)
        #expect(await until(.seconds(15)) { !model.isStreaming })
        let response = model.response(for: model.thread[1])
        #expect(response.phase == .completed)
        guard case .answers? = response.parts.first else {
            Issue.record("expected the Q/A card, got \(response.parts)")
            return
        }
        await services.stop()
    }

    @Test func sendingIsDisabledWhenTheServerIsUnreachable() {
        let services = makeServices(transport: StubTransport(), replay: nil)
        let model = services.newConversation()
        model.draft = "Hello"
        #expect(model.canSend)
        services.setConnectionForTesting(.offline)
        #expect(!model.canSend)
        services.setConnectionForTesting(.reconnecting)
        #expect(model.canSend)
        #expect(!ConnectionStatus.serverUnreachable.allowsSending)
    }

    @Test func eventsForOtherChatsAreIgnored() async throws {
        let services = makeServices(transport: StubTransport(), replay: nil)
        let model = services.newConversation()
        model.handle(ChatEvent(chatID: "other", messageID: "m", kind: .title("Not ours")))
        #expect(model.title.isEmpty)
    }
}

/// Hands out fixed ids, then random ones.
final class IDSequence: Sendable {
    private let ids: Mutex<[String]>

    init(_ ids: [String]) {
        self.ids = Mutex(ids)
    }

    @Sendable func next() -> String {
        ids.withLock { $0.isEmpty ? UUID().uuidString.lowercased() : $0.removeFirst() }
    }
}
