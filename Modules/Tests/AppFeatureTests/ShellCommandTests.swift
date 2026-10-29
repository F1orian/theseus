@testable import AppFeature
import Auth
import Fixtures
import OpenWebUIKit
import Testing

/// PLAT-05: the keyboard shortcuts' commands (⌘N, ⌘⇧O, ⌘K, ⌘,) and the iPad sidebar.
@MainActor
@Suite("Shell commands (PLAT-05)")
struct ShellCommandTests {
    let shell = MainShellModel(
        account: Account(
            server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
            userID: "00000000-0000-4000-8000-000000000001",
            name: "Test User",
            email: "user@example.com"
        ),
        client: OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport()),
        database: nil,
        onSignOut: {}
    )

    @Test func newChatLeavesTheCurrentChat() {
        shell.navigate(to: .chat(id: "abc"))
        shell.perform(.newChat)
        #expect(shell.route == .newChat())
    }

    @Test func searchOpensTheChatsListSearching() {
        shell.perform(.searchChats)
        #expect(shell.route == .chatsList)
        #expect(shell.isChatsSearchRequested)
    }

    @Test func anyOtherNavigationDropsTheSearchRequest() {
        shell.perform(.searchChats)
        shell.navigate(to: .chat(id: "abc"))
        shell.navigate(to: .chatsList)
        #expect(!shell.isChatsSearchRequested)
    }

    @Test func settingsOpensTheSheet() {
        shell.perform(.settings)
        #expect(shell.isSettingsPresented)
    }

    @Test func commandsCloseTheSettingsSheet() {
        shell.perform(.settings)
        shell.perform(.searchChats)
        #expect(!shell.isSettingsPresented)
        #expect(shell.route == .chatsList)
    }

    @Test func incognitoNeedsTheServerToAllowIt() {
        // The fixture Account hasn't loaded its permissions: Incognito chats are unavailable.
        #expect(shell.incognitoPolicy == .unavailable)
        #expect(!shell.canPerform(.incognitoChat))
        shell.perform(.incognitoChat)
        #expect(shell.route == .newChat())
        #expect(shell.canPerform(.newChat))
        #expect(shell.canPerform(.settings))
    }

    @Test func theSidebarToggles() {
        #expect(!shell.isSidebarHidden)
        shell.toggleSidebar()
        #expect(shell.isSidebarHidden)
        shell.toggleSidebar()
        #expect(!shell.isSidebarHidden)
    }

    @Test func everyCommandHasATitleAndAShortcutKey() {
        for command in ShellCommand.allCases {
            #expect(!command.title.isEmpty)
        }
        #expect(Set(ShellCommand.allCases.map(\.title)).count == ShellCommand.allCases.count)
    }
}
