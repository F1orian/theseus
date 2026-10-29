@testable import ChatFeature
import ComposerFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// INCOG-01: an Incognito chat streams like any Chat but is never saved, listed or titled, and
/// every turn carries the whole conversation.
@Suite("Incognito chat", .serialized)
@MainActor
struct IncognitoChatTests {
    private func body(_ data: Data?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(data))
    }

    @Test func itStreamsWithoutEverBecomingASavedChat() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        let bodies = Mutex<[Data]>([])
        transport.stub("POST", "api/chat/completions") { request in
            let isFirst = bodies.withLock { list in
                list.append(request.httpBody ?? Data())
                return list.count == 1
            }
            if isFirst { replay.open(.completion) }
            return (200, Data(#"{"status":true,"task_ids":["t"]}"#.utf8))
        }
        let services = makeServices(transport: transport, replay: replay)
        services.personalization = { _ in ChatPersonalization(instructions: nil, preferredName: "Ada", usesMemory: true) }
        var listChanges = 0
        var titles = 0
        services.onChatListChanged = { listChanges += 1 }
        services.onChatTitleChanged = { _, _ in titles += 1 }
        services.start()
        let model = services.newIncognitoConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID, "u2", "a2"]).next
        #expect(model.isIncognito)
        #expect(model.isNewChat)
        #expect(model.composer.isIncognito && !model.composer.canAttachFiles && !model.composer.canAddToProject, "nothing uploads")

        await send(model, "[theseus-test] What is a maze?")
        let first = try body(bodies.withLock { $0.first })
        #expect(first[path: "chat_id"]?.stringValue?.hasPrefix("temporary:") == true)
        #expect(first[path: "features.memory"] == .bool(false))
        #expect(first[path: "background_tasks.title_generation"] == .bool(false))
        #expect(first[path: "messages"]?.arrayValue?.last?[path: "content"]?.stringValue == "[theseus-test] What is a maze?")

        #expect(await until { !model.isStreaming })
        let response = model.response(for: model.thread[1])
        #expect(response.phase == .completed)
        #expect(response.text.hasPrefix("A maze is a branching puzzle"))
        #expect(model.chatID == nil, "never adopts a saved Chat id")
        #expect(model.title.isEmpty)
        #expect(listChanges == 0)
        #expect(titles == 0)
        #expect(services.conversation(chatID: try #require(ids.chatID)) !== model)

        // The second turn sends everything so far: the Server keeps nothing.
        await send(model, "And a labyrinth?")
        let second = try body(bodies.withLock { $0.last })
        let messages = second[path: "messages"]?.arrayValue ?? []
        #expect(messages.compactMap { $0[path: "role"]?.stringValue } == ["user", "assistant", "user"])
        #expect(messages[1][path: "content"]?.stringValue?.hasPrefix("A maze is a branching puzzle") == true)
        #expect(second[path: "parent_id"]?.stringValue == ids.assistantMessageID)
        await services.stop()
    }

    @Test func filesAreRefusedWithANotice() {
        let services = makeServices(transport: StubTransport(), replay: nil)
        let model = services.newIncognitoConversation()
        model.composer.attach([PendingAttachment(data: Data("hi".utf8), filename: "a.txt", contentType: "text/plain", source: .files)])
        #expect(model.composer.attachments.isEmpty)
        #expect(model.composer.notice?.contains("Incognito") == true)
    }

    @Test func stopAddressesTheTemporaryChat() async throws {
        let transport = StubTransport()
        let stops = Mutex<[String]>([])
        transport.stub("POST", "api/chat/completions") { _ in (200, Data(#"{"status":true,"task_ids":["t"]}"#.utf8)) }
        let services = makeServices(transport: transport, replay: try SocketReplay(scenario: "plain"))
        services.start()
        let model = services.newIncognitoConversation()
        await send(model, "Write a long story.")
        #expect(model.isStreaming)
        let path = try #require(transport.requests.first { $0.url?.path() == "/api/chat/completions" })
            .httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?[path: "chat_id"]?.stringValue
        let chatID = try #require(path)
        transport.stub("POST", "api/tasks/chat/\(chatID)/stop") { request in
            stops.withLock { $0.append(request.url?.path() ?? "") }
            return (200, Data(#"{"status":true}"#.utf8))
        }
        await model.stop()
        #expect(stops.withLock { $0 }.count == 1)
        #expect(model.notice == nil)
        await services.stop()
    }
}
