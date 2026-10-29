import ChatDomain
import Foundation
@testable import LibraryFeature
import Fixtures
import OpenWebUIKit
import Persistence
import Testing

/// The drawer rows' long-press menu, shared with the Chats list (CHATS-09, #171).
@MainActor
@Suite("Drawer row menu")
struct DrawerRowsTests {
    // MARK: Long-press menu (#171)

    @Test func aChatOffersStarRenameAndARedDelete() {
        let actions = ChatRowAction.actions(for: summary("a", updated: 1), canDelete: true, canAddToProject: false)
        #expect(actions == [.star, .rename, .delete])
        #expect(ChatRowAction.delete.isDestructive)
        #expect(!ChatRowAction.star.isDestructive)
    }

    @Test func aStarredChatOffersUnstar() {
        let actions = ChatRowAction.actions(for: summary("a", updated: 1, starred: true), canDelete: true, canAddToProject: false)
        #expect(actions.first == .unstar)
        #expect(ChatRowAction.unstar.title == "Unstar")
    }

    @Test func addToProjectAndDeleteOnlyWhenAvailable() {
        let chat = summary("a", updated: 1)
        #expect(ChatRowAction.actions(for: chat, canDelete: false, canAddToProject: false) == [.star, .rename])
        #expect(ChatRowAction.actions(for: chat, canDelete: true, canAddToProject: true) == [.star, .rename, .addToProject, .delete])
    }

    @Test func starAndDeleteFromTheDrawerUpdateItsSections() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([summary(fixtureStarredID, updated: 10), summary("b", updated: 5)])
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/chats/\(fixtureStarredID)/pin", fixture: "chat.pin.json")
        transport.stub("DELETE", "api/v1/chats/\(fixtureStarredID)", body: Data("true".utf8))
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
        let library = ChatLibrary(client: client, database: database)
        library.capabilities = Capabilities(enabled: [.deleteChat])
        await library.loadCached()
        #expect(library.recents.map(\.id) == [fixtureStarredID, "b"])

        // Star: the row leaves Recents for Starred.
        await library.toggleStar(fixtureStarredID)
        #expect(library.starred.map(\.id) == [fixtureStarredID])
        #expect(library.recents.map(\.id) == ["b"])

        // Delete: it leaves the drawer.
        #expect(await library.delete(fixtureStarredID))
        #expect(library.starred.isEmpty)
        #expect(library.recents.map(\.id) == ["b"])
    }
}
