@testable import AppFeature
import Auth
import Fixtures
import LibraryFeature
import OpenWebUIKit
import Testing

/// The signed-in shell's routing: drawer, AppRoute and the Settings sheet (CHATS-01, CHATS-10).
@MainActor
@Suite("Main shell navigation")
struct MainShellNavigationTests {
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

    @Test func signedInShellStartsOnTheNewChatHome() {
        #expect(shell.route == .newChat())
        #expect(!shell.isDrawerOpen)
    }

    @Test func navigatingClosesTheDrawer() {
        shell.isDrawerOpen = true
        shell.navigate(to: .chat(id: "abc"))
        #expect(shell.route == .chat(id: "abc"))
        #expect(!shell.isDrawerOpen)
    }

    @Test func settingsOpensAsASheetOverTheCurrentScreen() {
        shell.navigate(to: .chatsList)
        shell.isDrawerOpen = true
        shell.navigate(to: .settings)
        #expect(shell.isSettingsPresented)
        #expect(shell.route == .chatsList)
        #expect(!shell.isDrawerOpen)
    }

    @Test func libraryDestinationsMapOntoRoutes() {
        #expect(AppRoute(LibraryDestination.newChat(projectID: "p")) == .newChat(projectID: "p"))
        #expect(AppRoute(LibraryDestination.chat(id: "c")) == .chat(id: "c"))
        #expect(AppRoute(LibraryDestination.chatsList) == .chatsList)
        #expect(AppRoute(LibraryDestination.settings) == .settings)
        #expect(AppRoute.chatsList.drawerSection == .chats)
        #expect(AppRoute.chat(id: "c").chatID == "c")
        #expect(AppRoute.newChat().drawerSection == nil)
    }
}

/// A new Chat that gets its id keeps its screen (ADR 0130): the route changes for the drawer and
/// menus, but the screen isn't rebuilt mid-animation.
@MainActor
@Suite("Main shell new-chat promotion")
struct MainShellPromotionTests {
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

    @Test func promotingANewChatKeepsItsScreen() {
        shell.navigate(to: .newChat())
        shell.promoteNewChat(to: "abc")
        #expect(shell.route == .chat(id: "abc"))
        #expect(shell.screenRoute == .newChat())
    }

    @Test func navigatingAfterwardsBuildsTheNextScreen() {
        shell.promoteNewChat(to: "abc")
        let generation = shell.screenGeneration
        shell.navigate(to: .newChat())
        // Same route as the promoted screen's, but a new screen: a fresh new Chat.
        #expect(shell.screenRoute == .newChat())
        #expect(shell.screenGeneration == generation + 1)
        shell.navigate(to: .chat(id: "def"))
        #expect(shell.screenGeneration == generation + 1)
        #expect(shell.screenRoute == .chat(id: "def"))
    }
}
