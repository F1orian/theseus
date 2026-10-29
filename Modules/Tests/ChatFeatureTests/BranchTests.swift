@testable import ChatFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// The recorded `branches` scenario: send, retry (same user Message, new Response), edit the
/// first Message (a sibling root), then switch Branches.
private struct BranchIDs: Decodable {
    let chatID: String
    let first: [String]
    let regenerate: [String]
    let edit: [String]
}

/// A socket that only completes the recorded handshake and then stays open; tests feed the
/// recorded events themselves.
private func handshakeOnly(_ scenario: String) throws -> SocketReplay {
    let log = String(decoding: try Fixture.data("stream/\(scenario).frames.jsonl"), as: UTF8.self)
    var lines: [Substring] = []
    for line in log.split(separator: "\n") {
        if line.contains("POST /api/chat/completions") { break }
        lines.append(line)
    }
    return try SocketReplay(log: lines.joined(separator: "\n"))
}

@Suite("Branches: retry, edit, switch (MSG-03/04/05)", .serialized)
@MainActor
struct BranchTests {
    let fixture = StreamFixture("branches")

    private func ids() throws -> BranchIDs {
        try JSONDecoder().decode(BranchIDs.self, from: fixture.data("ids.json"))
    }

    /// Replays the recorded events of one Response into the model.
    private func replay(_ assistantID: String, into model: ConversationModel) throws {
        for (envelope, ackID) in try fixture.envelopes() where envelope[path: "message_id"]?.stringValue == assistantID {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) { model.handle(event) }
        }
    }

    private func loadedModel(_ transport: StubTransport, replay: SocketReplay?, ids: BranchIDs, chat: String = "chat.after-first.json") async throws -> (ChatServices, ConversationModel) {
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data(chat))
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.conversation(chatID: ids.chatID)
        await model.load()
        #expect(model.loadState == .loaded)
        return (services, model)
    }

    @Test func retryStreamsANewBranchInPlace() async throws {
        let ids = try ids()
        let transport = StubTransport()
        let bodies = Mutex<[JSONValue]>([])
        let completion = try fixture.data("completion.regenerate.json")
        transport.stub("POST", "api/chat/completions") { request in
            if let body = request.httpBody, let json = try? JSONDecoder().decode(JSONValue.self, from: body) {
                bodies.withLock { $0.append(json) }
            }
            return (200, completion)
        }
        let (services, model) = try await loadedModel(transport, replay: try handshakeOnly("branches"), ids: ids)
        #expect(model.thread.map(\.id) == ids.first)
        #expect(model.branchPosition(of: ids.first[1]) == nil, "a single Response has no pager")
        #expect(model.canChangeThread)

        model.idGenerator = IDSequence([ids.regenerate[1]]).next
        await model.regenerate(ids.first[1])
        let sent = try #require(bodies.withLock { $0.last })
        #expect(sent[path: "user_message.id"]?.stringValue == ids.first[0], "the same user Message")
        #expect(sent[path: "parent_id"] == .null)
        #expect(sent[path: "chat_id"]?.stringValue == ids.chatID)
        #expect(model.thread.map(\.id) == ids.regenerate)
        #expect(model.isStreaming)
        #expect(!model.canChangeThread)

        try replay(ids.regenerate[1], into: model)
        #expect(await until { !model.isStreaming })
        #expect(model.response(for: model.thread[1]).text == "Blue")
        #expect(model.branchPosition(of: ids.regenerate[1]) == .init(index: 1, count: 2))
        #expect(model.siblingModelIDs(of: ids.regenerate[1]) == ["claude-haiku-5-5"])
        await services.stop()
    }

    @Test func switchingBranchesShowsTheSiblingAndSavesTheChoice() async throws {
        let ids = try ids()
        let transport = StubTransport()
        let saved = Mutex<JSONValue?>(nil)
        let switched = try fixture.data("chat.switched.json")
        transport.stub("POST", "api/v1/chats/\(ids.chatID)") { request in
            saved.withLock { $0 = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
            return (200, switched)
        }
        let (services, model) = try await loadedModel(transport, replay: nil, ids: ids, chat: "chat.after-edit.json")
        #expect(model.thread.map(\.id) == ids.edit)
        #expect(model.branchPosition(of: ids.edit[0]) == .init(index: 1, count: 2))

        await model.showBranch(of: ids.edit[0], offset: -1)
        // The first root, followed down its newest Response (the retry).
        #expect(model.thread.map(\.id) == ids.regenerate)
        #expect(saved.withLock { $0 }?[path: "chat.history.currentId"]?.stringValue == ids.regenerate[1])

        await model.showBranch(of: ids.regenerate[1], offset: -1)
        #expect(model.thread.map(\.id) == ids.first)
        #expect(model.branchPosition(of: ids.first[1]) == .init(index: 0, count: 2))

        // Past the first Branch nothing happens.
        await model.showBranch(of: ids.first[1], offset: -1)
        #expect(model.thread.map(\.id) == ids.first)
        #expect(model.notice == nil)
        await services.stop()
    }

    @Test func aFailedSaveKeepsTheBranchAndExplains() async throws {
        let ids = try ids()
        let transport = StubTransport()
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        let (services, model) = try await loadedModel(transport, replay: nil, ids: ids, chat: "chat.after-edit.json")
        await model.showBranch(of: ids.edit[0], offset: -1)
        #expect(model.thread.map(\.id) == ids.regenerate)
        #expect(model.notice?.contains("boom") == true)
        await services.stop()
    }

    @Test func editSendsANewUserMessageNextToTheOriginal() async throws {
        let ids = try ids()
        let transport = StubTransport()
        let bodies = Mutex<[JSONValue]>([])
        let completion = try fixture.data("completion.edit.json")
        transport.stub("POST", "api/chat/completions") { request in
            if let body = request.httpBody, let json = try? JSONDecoder().decode(JSONValue.self, from: body) {
                bodies.withLock { $0.append(json) }
            }
            return (200, completion)
        }
        let (services, model) = try await loadedModel(transport, replay: try handshakeOnly("branches"), ids: ids, chat: "chat.after-regenerate.json")
        #expect(model.thread.map(\.id) == ids.regenerate)

        model.idGenerator = IDSequence(ids.edit).next
        await model.edit(ids.first[0], to: "  [theseus-test] Name one fruit. Answer with one word.  ")
        let sent = try #require(bodies.withLock { $0.last })
        #expect(sent[path: "user_message.id"]?.stringValue == ids.edit[0])
        #expect(sent[path: "user_message.parentId"] == .null, "same parent as the original (a root)")
        #expect(sent[path: "user_message.content"]?.stringValue == "[theseus-test] Name one fruit. Answer with one word.")
        #expect(sent[path: "chat_id"]?.stringValue == ids.chatID)
        #expect(model.thread.map(\.id) == ids.edit)

        try replay(ids.edit[1], into: model)
        #expect(await until { !model.isStreaming })
        #expect(model.response(for: model.thread[1]).text == "Apple")
        #expect(model.branchPosition(of: ids.edit[0]) == .init(index: 1, count: 2))
        // The original is still there, one Branch back.
        #expect(model.message(id: ids.first[0])?.content.contains("colour") == true)
        await services.stop()
    }

    @Test func editIgnoresBlankTextAndAssistantMessages() async throws {
        let ids = try ids()
        let transport = StubTransport()
        let (services, model) = try await loadedModel(transport, replay: nil, ids: ids)
        await model.edit(ids.first[0], to: "   ")
        await model.edit(ids.first[1], to: "Hello")
        #expect(model.thread.map(\.id) == ids.first)
        #expect(!transport.requests.contains { $0.httpMethod == "POST" })
        await services.stop()
    }

    @Test func retryOverSSESendsOnlyTheThreadAboveTheUserMessage() async throws {
        let ids = try ids()
        let transport = StubTransport()
        let sent = Mutex<JSONValue?>(nil)
        let sse = try StreamFixture("sse").data("plain.txt")
        transport.stub("POST", "api/chat/completions") { request in
            sent.withLock { $0 = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
            return (200, sse)
        }
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.after-regenerate.json"))
        let (services, model) = try await loadedModel(transport, replay: nil, ids: ids)
        await model.regenerate(ids.first[1])
        #expect(await until { !model.isStreaming })
        guard case .array(let messages)? = sent.withLock({ $0 })?[path: "messages"] else {
            Issue.record("no SSE body")
            return
        }
        // Only the user prompt: the Response being replaced isn't sent as history.
        #expect(messages.count == 1)
        #expect(messages.first?[path: "role"] == .string("user"))
        await services.stop()
    }

    @Test func annotationsUpdateTheVisibleMessage() async throws {
        let ids = try ids()
        let (services, model) = try await loadedModel(StubTransport(), replay: nil, ids: ids)
        model.setAnnotation(MessageAnnotation(rating: .good, feedbackID: "f"), for: ids.first[1])
        #expect(model.thread[1].annotation?.rating == .good)
        #expect(model.message(id: ids.first[1])?.annotation?.feedbackID == "f")
        model.setAnnotation(nil, for: ids.first[1])
        #expect(model.thread[1].annotation == nil)
        await services.stop()
    }
}
