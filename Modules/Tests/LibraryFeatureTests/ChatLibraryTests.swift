import ChatDomain
import Fixtures
import Foundation
@testable import LibraryFeature
import OpenWebUIKit
import Persistence
import Testing

/// Static token so `.required` endpoints are sent.
struct StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

/// Every request fails as if the device were offline.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw OpenWebUIError.transport(.notConnectedToInternet)
    }
}

func summary(_ id: String, _ title: String? = nil, updated: TimeInterval, starred: Bool = false) -> ChatSummary {
    ChatSummary(
        id: id,
        title: title ?? "Chat \(id)",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: updated),
        isStarred: starred
    )
}

let fixtureStarredID = "00000000-0000-4000-8000-000000000200"

@MainActor
@Suite("ChatLibrary")
struct ChatLibraryTests {
    let transport = StubTransport()
    let database: AccountDatabase

    init() throws {
        database = try AccountDatabase.inMemory()
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
    }

    func makeLibrary(
        transport: (any HTTPTransport)? = nil,
        capabilities: Set<Capability> = [.deleteChat]
    ) -> ChatLibrary {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport ?? self.transport, authorizer: StaticAuthorizer())
        let library = ChatLibrary(client: client, database: database)
        library.capabilities = Capabilities(enabled: capabilities)
        return library
    }

    // MARK: Loading

    @Test func cachedChatsShowBeforeTheNetworkAnswers() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10), summary("s", updated: 20, starred: true)])
        let library = makeLibrary()
        await library.loadCached()
        #expect(library.chats.map(\.id) == ["s", "a"])
        #expect(library.starred.map(\.id) == ["s"])
        #expect(library.recents.map(\.id) == ["a"])
        #expect(transport.requests.isEmpty)
    }

    @Test func refreshMirrorsTheNewestPageAndTheStarredChats() async throws {
        let library = makeLibrary()
        await library.refresh()

        #expect(library.state == .loaded)
        #expect(library.chats.count == 61)
        #expect(library.starred.map(\.id) == [fixtureStarredID])
        #expect(library.recents.count == 60)
        #expect(!library.recents.contains { $0.isStarred })
        #expect(library.hasMore, "a full page means there may be more")

        let listRequest = try #require(transport.requests.first { $0.url?.path() == "/api/v1/chats/" })
        let query = listRequest.url?.query() ?? ""
        #expect(query.contains("page=1") && query.contains("include_pinned=true") && query.contains("include_folders=true"))

        // The mirror now serves the next launch.
        let relaunched = makeLibrary()
        await relaunched.loadCached()
        #expect(relaunched.chats == library.chats)
    }

    @Test func refreshDropsChatsDeletedOnAnotherDevice() async throws {
        let gone = summary("gone", updated: 1_900_000_000)
        try await database.saveChatSummaries([gone])
        let library = makeLibrary()
        await library.loadCached()
        #expect(library.chats.map(\.id) == ["gone"])

        await library.refresh()
        #expect(!library.chats.contains { $0.id == "gone" })
    }

    @Test func offlineRefreshKeepsTheCacheAndReportsTheError() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10)])
        let library = makeLibrary(transport: OfflineTransport())
        await library.loadCached()
        await library.refresh()
        #expect(library.chats.map(\.id) == ["a"])
        #expect(library.state == .failed(OpenWebUIError.transport(.notConnectedToInternet).message))
    }

    @Test func loadMoreAppendsTheNextPageUntilAShortPage() async throws {
        let library = makeLibrary()
        await library.refresh()
        transport.stub("GET", "api/v1/chats/") { request in
            #expect(request.url?.query()?.contains("page=2") == true)
            let body = #"[{"id":"older","title":"Older chat","updated_at":1000,"created_at":900,"last_read_at":null,"snippet":null,"active":false,"archived":false}]"#
            return (200, Data(body.utf8))
        }
        await library.loadMore()
        #expect(library.chats.last?.id == "older")
        #expect(!library.hasMore)

        let before = transport.requests.count
        await library.loadMore()
        #expect(transport.requests.count == before, "no request after the last page")
    }

    // MARK: Star (CHATS-05)

    @Test func starringMovesAChatToStarred() async throws {
        try await database.saveChatSummaries([summary(fixtureStarredID, updated: 10)])
        try transport.stub("POST", "api/v1/chats/\(fixtureStarredID)/pin", fixture: "chat.pin.json")
        let library = makeLibrary()
        await library.loadCached()

        await library.toggleStar(fixtureStarredID)

        #expect(library.starred.map(\.id) == [fixtureStarredID])
        #expect(library.recents.isEmpty)
        #expect(try await database.starredChatSummaries().map(\.id) == [fixtureStarredID])
        #expect(transport.requests.last?.httpMethod == "POST")
    }

    @Test func aFailedStarIsRolledBack() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10)])
        transport.stub("POST", "api/v1/chats/a/pin", status: 500, body: Data(#"{"detail":"Boom"}"#.utf8))
        let library = makeLibrary()
        await library.loadCached()

        await library.toggleStar("a")

        #expect(library.starred.isEmpty)
        #expect(library.errorMessage == "Boom")
        #expect(try await database.starredChatSummaries().isEmpty)
    }

    // MARK: Rename (CHATS-06)

    @Test func renameTrimsAndPersistsTheTitle() async throws {
        try await database.saveChatSummaries([summary(fixtureStarredID, "Old", updated: 10)])
        try transport.stub("POST", "api/v1/chats/\(fixtureStarredID)", fixture: "chat.rename.json")
        let library = makeLibrary()
        await library.loadCached()

        await library.rename(fixtureStarredID, to: "  [theseus-test] renamed \n")

        let body = try #require(transport.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"chat":{"title":"[theseus-test] renamed"}}"#)
        #expect(library.chat(id: fixtureStarredID)?.title == "[theseus-test] renamed")
        #expect(try await database.chatSummaries().first?.title == "[theseus-test] renamed")
    }

    @Test func blankOrUnchangedTitlesAreNotSent() async throws {
        try await database.saveChatSummaries([summary("a", "Same", updated: 10)])
        let library = makeLibrary()
        await library.loadCached()
        await library.rename("a", to: "   ")
        await library.rename("a", to: "Same")
        #expect(transport.requests.isEmpty)
        #expect(library.chat(id: "a")?.title == "Same")
    }

    @Test func aFailedRenameRestoresTheOldTitle() async throws {
        try await database.saveChatSummaries([summary("a", "Old", updated: 10)])
        let library = makeLibrary(transport: OfflineTransport())
        await library.loadCached()
        await library.rename("a", to: "New")
        #expect(library.chat(id: "a")?.title == "Old")
        #expect(library.errorMessage != nil)
    }

    // MARK: Delete (CHATS-07)

    @Test func deleteRemovesTheChatEverywhere() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10), summary("b", updated: 5)])
        try transport.stub("DELETE", "api/v1/chats/a", fixture: "chat.delete.json")
        let library = makeLibrary()
        await library.loadCached()

        let deleted = await library.delete("a")

        #expect(deleted)
        #expect(library.chats.map(\.id) == ["b"])
        #expect(try await database.chatSummaries().map(\.id) == ["b"])
    }

    @Test func deleteNeedsTheDeleteChatCapability() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10)])
        let library = makeLibrary(capabilities: [])
        await library.loadCached()
        #expect(!library.canDelete)
        let deleted = await library.delete("a")
        #expect(!deleted)
        #expect(library.chats.map(\.id) == ["a"])
        #expect(transport.requests.isEmpty)
    }

    @Test func aFailedDeleteBringsTheChatBack() async throws {
        try await database.saveChatSummaries([summary("a", updated: 10), summary("b", updated: 5)])
        transport.stub("DELETE", "api/v1/chats/a", status: 403, body: Data(#"{"detail":"Not allowed"}"#.utf8))
        let library = makeLibrary()
        await library.loadCached()

        let deleted = await library.delete("a")

        #expect(!deleted)
        #expect(library.chats.map(\.id) == ["a", "b"])
        #expect(library.errorMessage == "Not allowed")
        #expect(try await database.chatSummaries().map(\.id) == ["a", "b"])
    }

    // MARK: Other epics

    @Test func upsertedChatsAppearInOrder() async throws {
        let library = makeLibrary()
        library.upsert(summary("old", updated: 1))
        library.upsert(summary("new", updated: 5))
        library.upsert(summary("old", "Titled", updated: 9))
        #expect(library.chats.map(\.id) == ["old", "new"])
        #expect(library.chat(id: "old")?.title == "Titled")
    }
}
