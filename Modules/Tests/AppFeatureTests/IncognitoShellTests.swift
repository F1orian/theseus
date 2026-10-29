@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// The shell's side of Incognito chats (INCOG-01/02): the route, and the policy from the
/// Account's `chat.temporary` / `chat.temporary_enforced` permissions.
@MainActor
@Suite("Incognito in the shell")
struct IncognitoShellTests {
    let transport = StubTransport()
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    /// The recorded Account, as a regular user with the given `chat.*` permissions.
    func signedInShell(chat permissions: [String: Bool]) async throws -> MainShellModel {
        var user = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("auths.json")).objectValue ?? [:]
        user["role"] = .string("user")
        var tree = user["permissions"]?.objectValue ?? [:]
        var chat = tree["chat"]?.objectValue ?? [:]
        for (key, value) in permissions { chat[key] = .bool(value) }
        tree["chat"] = .object(chat)
        tree["features"] = .object(["folders": .bool(true)])
        user["permissions"] = .object(tree)
        transport.stub("GET", "api/v1/auths/", body: try JSONEncoder().encode(JSONValue.object(user)))
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        let shell = MainShellModel(
            account: account,
            client: OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: FixedTokenAuthorizer(token: "jwt")),
            database: nil,
            onSignOut: {}
        )
        await shell.refresh()
        await shell.tearDown()
        return shell
    }

    @Test func theGhostButtonOpensAnIncognitoChatAndTheXLeavesIt() async throws {
        let shell = try await signedInShell(chat: ["temporary": true])
        #expect(shell.incognitoPolicy == .available)
        #expect(shell.route == .newChat())
        shell.navigate(to: .incognitoChat)
        #expect(shell.route == .incognitoChat)
        #expect(shell.route.drawerSection == nil && shell.route.chatID == nil)
        shell.navigate(to: .newChat())
        #expect(shell.route == .newChat())
        #expect(shell.library.capabilities.contains(.projects))
    }

    @Test func withoutThePermissionThereIsNoIncognito() async throws {
        let shell = try await signedInShell(chat: ["temporary": false])
        #expect(shell.incognitoPolicy == .unavailable)
        #expect(!shell.library.capabilities.contains(.incognitoChat))
    }

    @Test func whenEnforcedEveryNewChatIsIncognitoAndProjectsAreGone() async throws {
        let shell = try await signedInShell(chat: ["temporary": true, "temporary_enforced": true])
        #expect(shell.incognitoPolicy == .enforced)
        #expect(shell.route == .incognitoChat, "the home is an Incognito chat")
        shell.navigate(to: .chatsList)
        shell.navigate(to: .newChat())
        #expect(shell.route == .incognitoChat)
        let generation = shell.incognitoGeneration
        shell.navigate(to: .newChat(projectID: "p"))
        #expect(shell.route == .incognitoChat)
        #expect(shell.incognitoGeneration == generation + 1, "New chat starts a fresh Incognito chat")
        #expect(!shell.library.capabilities.contains(.projects))
        #expect(!shell.projects.capabilities.contains(.projects))
    }
}
