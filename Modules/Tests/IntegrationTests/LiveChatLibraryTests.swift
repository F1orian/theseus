import Auth
import ChatDomain
import Foundation
import LibraryFeature
import OpenWebUIKit
import Persistence
import Testing

/// #146 against the test Server (read-only): the Chats list's infinite scroll reaches Chats
/// older than page 3 and, scrolled to the end, holds every Chat the Server lists.
@Suite(
    "Live Chat library (opt-in: THESEUS_INTEGRATION=1 + .env)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
@MainActor
struct LiveChatLibraryTests {
    @Test func infiniteScrollReachesChatsOlderThanPageThree() async throws {
        let settings = try #require(LiveServer.settings)
        let transport = URLSessionTransport()
        let server = ServerProfile(url: settings.url, name: "Live")
        guard case .signedIn(let signedIn) = try await PasswordSignIn(server: server, transport: transport)
            .signIn(email: settings.email, password: settings.password)
        else {
            Issue.record("sign-in failed")
            return
        }
        let authenticator = SessionAuthenticator(token: signedIn.token) { throw OpenWebUIError.unauthorized(detail: nil) }
        let client = OpenWebUIClient(server: settings.url, transport: transport, authorizer: authenticator)
        defer { Task { _ = try? await client.send(.signOut) } }

        // The target: the first Chat on page 4 of the Server's own list.
        let pageFour = try await client.send(.chats(page: 4, includeStarred: true, includeProjects: true))
        let target = try #require(pageFour.first, "the test Account needs more than 180 Chats")

        let library = ChatLibrary(client: client, database: try AccountDatabase.inMemory())
        await library.refresh()
        #expect(library.state == .loaded)
        var calls = 0
        while library.hasMore, library.chat(id: target.id) == nil, calls < 10 {
            await library.loadMore()
            calls += 1
        }
        #expect(library.chat(id: target.id) != nil, "page 4's first Chat is reachable by scrolling")
        #expect(calls == 3, "one scroll-to-the-end per page")

        // To the end: every Chat the Server lists, once.
        while library.hasMore, calls < 100 {
            await library.loadMore()
            calls += 1
        }
        #expect(!library.hasMore)
        #expect(library.errorMessage == nil)
        #expect(Set(library.chats.map(\.id)).count == library.chats.count)
        #expect(library.chats.count > 180)
    }
}
