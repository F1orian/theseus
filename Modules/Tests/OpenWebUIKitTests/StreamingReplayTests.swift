import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Folds every recorded event for `messageID` into a `ResponseState`, like a Conversation does.
func replay(_ fixture: StreamFixture, messageID: String) throws -> (state: ResponseState, chatEvents: [ChatEvent]) {
    var state = ResponseState()
    var all: [ChatEvent] = []
    for (envelope, ackID) in try fixture.envelopes() {
        for event in ChatEventDecoder.decode(envelope, ackID: ackID) {
            all.append(event)
            if event.messageID == messageID, case .response(let response) = event.kind {
                state.apply(response)
            }
        }
    }
    return (state, all)
}

/// The stored Chat of a fixture, decoded through the real endpoint.
func storedChat(_ fixture: StreamFixture, _ suffix: String = "chat.final.json") async throws -> Chat {
    let transport = StubTransport()
    let ids = try fixture.ids()
    let chatID = try #require(ids.chatID)
    transport.stub("GET", "api/v1/chats/\(chatID)", body: try fixture.data(suffix))
    let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
    return try await client.send(.chat(id: chatID)).chat
}

@Suite("Recorded streams reduce to the stored Response")
struct StreamingReplayTests {
    @Test(arguments: ["plain", "reasoning", "stop", "websearch", "interleaved", "askuser"])
    func reducedOutputMatchesTheStoredMessage(_ name: String) async throws {
        let fixture = StreamFixture(name)
        let ids = try fixture.ids()
        let (state, _) = try replay(fixture, messageID: ids.assistantMessageID)
        let stored = try #require(try await storedChat(fixture).tree[ids.assistantMessageID])

        #expect(state.text == stored.response.text)
        #expect(state.output.map(\.type) == stored.output.map(\.type))
        #expect(state.isFinished)
    }

    @Test func plainStreamsTextTitleAndAFollowUpTurn() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let (first, events) = try replay(fixture, messageID: ids.assistantMessageID)
        #expect(first.phase == .completed)
        #expect(first.text.contains("**"))
        #expect(events.contains { $0.kind == .title("Maze Definition") })
        #expect(events.contains { $0.kind == .active(true) })

        let followUp = try #require(ids.followUp)
        let (second, _) = try replay(fixture, messageID: followUp.assistant)
        #expect(second.text.contains("```swift"))

        let chat = try await storedChat(fixture)
        #expect(chat.title == "Maze Definition")
        #expect(chat.tree.activePath.map(\.id) == [ids.userMessageID, ids.assistantMessageID, followUp.user, followUp.assistant])
        #expect(chat.modelIDs == ["claude-haiku-5-5"])
    }

    @Test func reasoningBecomesAThinkingPartBeforeTheAnswer() throws {
        let fixture = StreamFixture("reasoning")
        let (state, _) = try replay(fixture, messageID: try fixture.ids().assistantMessageID)
        guard case .thinking(_, let text, _, let streaming, _) = state.parts.first else {
            Issue.record("expected Thinking first, got \(state.parts)")
            return
        }
        #expect(text.contains("17 × 20"))
        #expect(!streaming)
        #expect(state.parts.last == .text(id: "msg_000000000000000000000032", markdown: "17 × 23 = **391**", isStreaming: false))
    }

    @Test func stopKeepsThePartialResponse() async throws {
        let fixture = StreamFixture("stop")
        let ids = try fixture.ids()
        let (state, _) = try replay(fixture, messageID: ids.assistantMessageID)
        #expect(state.phase == .stopped)
        #expect(state.text.hasPrefix("**The Long Way Round**"))
        let stored = try #require(try await storedChat(fixture).tree[ids.assistantMessageID])
        #expect(stored.response.phase == .stopped)
    }

    @Test func providerErrorsSurfaceOnTheMessage() async throws {
        let fixture = StreamFixture("error")
        let ids = try fixture.ids()
        let (state, events) = try replay(fixture, messageID: ids.assistantMessageID)
        #expect(state.phase == .failed)
        #expect(state.error == "max_tokens: must be greater than or equal to 0")
        // The title still arrives after the failure.
        #expect(events.contains { if case .title = $0.kind { true } else { false } })
        let stored = try #require(try await storedChat(fixture).tree[ids.assistantMessageID])
        #expect(stored.response.error == state.error)
    }

    @Test func webSearchShowsToolStepsAndSources() throws {
        let fixture = StreamFixture("websearch")
        let (state, _) = try replay(fixture, messageID: try fixture.ids().assistantMessageID)
        let tools = state.parts.compactMap { part -> [ToolActivity]? in
            if case .tools(_, let tools) = part { return tools }
            return nil
        }.flatMap { $0 }
        #expect(tools.first?.title == "Searched the web")
        #expect(tools.contains { $0.title.hasPrefix("Read ") })
        #expect(tools.allSatisfy { !$0.isRunning })
        let citations = Citation.list(from: state.sources)
        #expect(citations.count == 2)
        #expect(citations.first?.host == "github.com")
    }

    @Test func askUserPausesWithQuestionsThenContinues() throws {
        let fixture = StreamFixture("askuser")
        let ids = try fixture.ids()
        var state = ResponseState()
        var paused: ClarifyingQuestions?
        for (envelope, ackID) in try fixture.envelopes() {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) where event.messageID == ids.assistantMessageID {
                guard case .response(let response) = event.kind else { continue }
                state.apply(response)
                if paused == nil, state.phase == .awaitingAnswer { paused = state.pendingQuestions }
            }
        }
        let questions = try #require(paused)
        #expect(questions.questions.map(\.id) == ["destination_type", "budget"])
        #expect(questions.questions.first?.options.count == 2)
        #expect(state.phase == .completed)
        guard case .answers(_, let answers) = state.parts.first else {
            Issue.record("expected the Q/A card first, got \(state.parts)")
            return
        }
        #expect(answers.entries.first?.answer == "Nature getaway")
    }

    @Test func resumeOverlayIsInProgressAndTheRejoinedStreamFinishes() async throws {
        let fixture = StreamFixture("resume")
        let ids = try fixture.ids()
        let overlay = try #require(try await storedChat(fixture, "chat.overlay.json").tree[ids.assistantMessageID])
        #expect(!overlay.isDone)
        var state = overlay.response
        #expect(!state.isFinished)

        // Only the second connection's events reach the reopened Chat.
        for (envelope, ackID) in try fixture.envelopes(connection: 1) {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) where event.messageID == ids.assistantMessageID {
                if case .response(let response) = event.kind { state.apply(response) }
            }
        }
        let final = try #require(try await storedChat(fixture).tree[ids.assistantMessageID])
        #expect(state.phase == .completed)
        #expect(state.text == final.response.text)
    }
}

@Suite("ChatEventDecoder")
struct ChatEventDecoderTests {
    func envelope(_ type: String, _ data: JSONValue, shared: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["chat_id": "c", "message_id": "m", "data": ["type": .string(type), "data": data]]
        if shared { object["shared"] = true }
        return .object(object)
    }

    @Test func skipsSharedCopies() {
        #expect(ChatEventDecoder.decode(envelope("status", ["description": "x"], shared: true)).isEmpty)
    }

    @Test func mapsSideChannels() throws {
        let status = ChatEventDecoder.decode(envelope("status", ["action": "web_search", "description": "Searching the web", "done": false]))
        #expect(status.first?.kind == .response(.status(StatusUpdate(action: "web_search", description: "Searching the web"))))
        #expect(ChatEventDecoder.decode(envelope("chat:title", "A title")).first?.kind == .title("A title"))
        #expect(ChatEventDecoder.decode(envelope("chat:message:follow_ups", ["follow_ups": ["a", "b"]])).first?.kind == .response(.followUps(["a", "b"])))
        #expect(ChatEventDecoder.decode(envelope("replace", ["content": "new"])).first?.kind == .response(.legacyText("new")))
        #expect(ChatEventDecoder.decode(envelope("message", ["content": "+"])).first?.kind == .response(.legacyTextDelta("+")))
        #expect(ChatEventDecoder.decode(envelope("source", ["type": "code_execution", "id": "x"])).isEmpty)
        #expect(ChatEventDecoder.decode(envelope("something:new", [:])).first?.kind == .ignored(type: "something:new"))
    }

    @Test func browserOnlyCallsNeedARefusal() {
        let events = ChatEventDecoder.decode(envelope("execute:python", ["code": "1"]), ackID: 4)
        #expect(events.first?.kind == .unsupportedCall(type: "execute:python", ackID: 4))
    }

    @Test func liveQuestionsCarryTheirAck() throws {
        let data: JSONValue = [
            "interaction_id": "i1",
            "questions": [["id": "q", "header": "H", "question": "Q?", "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]],
            "allow_other": true,
            "timeout_ms": 120_000,
        ]
        let events = ChatEventDecoder.decode(envelope("request:user_input", data), ackID: 9)
        guard case .questionsRequested(let questions, let ackID)? = events.first?.kind else {
            Issue.record("got \(events)"); return
        }
        #expect(ackID == 9)
        #expect(questions.callID == "i1")
        #expect(questions.questions.first?.options.map(\.label) == ["A", "B"])
    }

    @Test func chatCompletionCanCarrySeveralFacts() {
        let events = ChatEventDecoder.decode(envelope("chat:completion", [
            "done": true,
            "output": [["type": "message", "id": "x", "content": [["type": "output_text", "text": "Hi"]]]],
            "title": "T",
        ]))
        #expect(events.map(\.kind) == [
            .response(.completed(output: [.text(TextOutput(id: "x", parts: ["Hi"]))])),
            .title("T"),
        ])
        let legacy = ChatEventDecoder.decode(envelope("chat:completion", ["choices": [["delta": ["content": "Hel"]]]]))
        #expect(legacy.map(\.kind) == [.response(.legacyTextDelta("Hel"))])
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}
