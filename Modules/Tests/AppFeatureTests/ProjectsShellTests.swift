@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OpenWebUIKit
import ProjectsFeature
import Testing

/// The shell's side of Projects: Capability hand-off after loading and the Chats library refresh
/// after a Project is deleted (PROJ-01, PROJ-08).
@MainActor
@Suite("Projects in the shell")
struct ProjectsShellTests {
    let transport = StubTransport()
    let shell: MainShellModel

    init() throws {
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        try transport.stub("GET", "api/v1/folders/", fixture: "projects.json")
        try transport.stub("GET", "api/v1/folders/00000000-0000-4000-8000-000000000500", fixture: "project.json")
        try transport.stub("DELETE", "api/v1/folders/00000000-0000-4000-8000-000000000500", fixture: "project.delete.json")
        shell = MainShellModel(
            account: Account(
                server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
                userID: "00000000-0000-4000-8000-000000000001",
                name: "Test User",
                email: "user@example.com"
            ),
            client: OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: FixedToken()),
            database: nil,
            onSignOut: {}
        )
    }

    @Test func projectsFollowTheAccountCapabilities() async {
        #expect(shell.projects.isAvailable == false)
        await shell.refresh()
        // The recorded Server has folders enabled; `folder_max_file_count` is empty (no limit).
        #expect(shell.projects.isAvailable)
        #expect(shell.projects.maxKnowledgeFiles == nil)
    }

    @Test func deletingAProjectRefreshesTheChats() async {
        await shell.refresh()
        await shell.projects.refresh()
        let chatRequests = transport.requests.count { $0.url?.path() == "/api/v1/chats/" }
        #expect(await shell.projects.delete("00000000-0000-4000-8000-000000000500", deleteChats: true))
        #expect(transport.requests.count { $0.url?.path() == "/api/v1/chats/" } == chatRequests + 1)
    }
}

private struct FixedToken: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}
