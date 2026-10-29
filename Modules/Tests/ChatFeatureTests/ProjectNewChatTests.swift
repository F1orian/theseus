@testable import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// A new Chat started inside a Project (`AppRoute.newChat(projectID:)`, #127): the header shows the
/// Project, and the first completion files the Chat in it (`folder_id`).
@Suite("New Chat in a Project", .serialized)
@MainActor
struct ProjectNewChatTests {
    static let projectID = "00000000-0000-4000-8000-000000000500"

    @Test func theFirstSendFilesTheChatInTheProject() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        try transport.stub("GET", "api/v1/folders/\(Self.projectID)", fixture: "project.json")
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation(projectID: Self.projectID)
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next

        await model.load()
        #expect(model.projectID == Self.projectID)
        #expect(model.projectName == "[theseus-test] Fixture project")

        await send(model, "[theseus-test] What is a maze?")
        let request = try #require(transport.requests.first { $0.url?.path() == "/api/chat/completions" })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body[path: "folder_id"] == .string(Self.projectID))
        #expect(await until { !model.isStreaming })
        #expect(model.chatID == ids.chatID)
        await services.stop()
    }

    @Test func withoutTheProjectsCapabilityTheChatStaysOutside() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/folders/\(Self.projectID)", fixture: "project.json")
        let services = makeServices(transport: transport, replay: nil, capabilities: Set(Capability.allCases).subtracting([.projects]))
        let model = services.newConversation(projectID: Self.projectID)
        await model.load()
        #expect(model.projectName == nil)
        #expect(model.projectID == nil)
    }
}
