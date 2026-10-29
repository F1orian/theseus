import ChatDomain
import Fixtures
import Foundation
@testable import LibraryFeature
import OpenWebUIKit
import Persistence
import Testing

/// A pagination fixture for `GET /api/v1/chats/?page=` (#146): the Server's list of `chats`,
/// newest first, served 60 per page in the wire shape recorded in `chats.page-1.json`. An empty
/// page follows the last one, as on the real Server.
final class PagedChatsServer: Sendable {
    let chats: [ChatSummary]
    let transport = StubTransport()

    /// `count` Chats, one minute apart, the newest first. `ties` gives runs of equal times.
    init(count: Int, start: TimeInterval = 1_800_000_000, sameTime: (Int) -> Bool = { _ in false }) {
        var time = start
        var chats: [ChatSummary] = []
        for index in 0..<count {
            if index > 0, !sameTime(index) { time -= 60 }
            chats.append(summary(String(format: "chat-%04d", index), updated: time))
        }
        self.chats = chats
        install()
    }

    init(chats: [ChatSummary]) {
        self.chats = chats
        install()
    }

    private func install() {
        let chats = chats
        transport.stub("GET", "api/v1/chats/") { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let number = Int(items.first { $0.name == "page" }?.value ?? "1") ?? 1
            let start = (number - 1) * 60
            let slice = start < chats.count ? Array(chats[start..<min(start + 60, chats.count)]) : []
            return (200, Self.wire(slice))
        }
        transport.stub("GET", "api/v1/chats/pinned", body: Data("[]".utf8))
    }

    /// The page numbers requested so far.
    var requestedPages: [Int] {
        transport.requests.compactMap { request -> Int? in
            guard request.url?.path() == "/api/v1/chats/" else { return nil }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first { $0.name == "page" }.flatMap { $0.value.flatMap(Int.init) }
        }
    }

    static func wire(_ chats: [ChatSummary]) -> Data {
        let rows: [[String: Any]] = chats.map { chat in
            [
                "id": chat.id,
                "title": chat.title,
                "updated_at": Int(chat.updatedAt.timeIntervalSince1970),
                "created_at": Int(chat.createdAt.timeIntervalSince1970),
                "last_read_at": NSNull(),
                "snippet": NSNull(),
                "active": false,
                "archived": false,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: rows)
    }
}

@MainActor
@Suite("Chat list pagination (#146)")
struct ChatPaginationTests {
    let database: AccountDatabase

    init() throws {
        database = try AccountDatabase.inMemory()
    }

    func makeLibrary(_ server: PagedChatsServer) -> ChatLibrary {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: server.transport, authorizer: StaticAuthorizer())
        return ChatLibrary(client: client, database: database)
    }

    /// Scrolls to the end the way the list does: asks for more until the Server has no more.
    func scrollToTheEnd(_ library: ChatLibrary, limit: Int = 100) async {
        var calls = 0
        while library.hasMore, calls < limit {
            await library.loadMore()
            calls += 1
        }
    }

    @Test func infiniteScrollReachesEveryChat() async throws {
        let server = PagedChatsServer(count: 1_031)
        let library = makeLibrary(server)
        await library.refresh()
        #expect(library.chats.count == 60)

        await scrollToTheEnd(library)
        #expect(library.chats.map(\.id) == server.chats.map(\.id))
        #expect(!library.hasMore)
        #expect(server.requestedPages == Array(1...18), "pages 1…18 hold 1,031 Chats; the 18th is short")

        // The mirror holds every Chat for the next launch and for offline search.
        #expect(try await database.chatSummaries().count == 1_031)
        let oldest = try #require(server.chats.last)
        #expect(await library.searchLocally(oldest.title).map(\.id) == [oldest.id])
    }

    @Test func aRelaunchWithAPartialCacheDoesNotStallAtItsEnd() async throws {
        // The device's root cause: the mirror held 2 pages from an earlier launch, refresh() re-read
        // page 1 only, and the next "load more" re-fetched page 2, which added nothing at the bottom,
        // so the last row never changed and the list never asked again.
        let server = PagedChatsServer(count: 200)
        try await database.saveChatSummaries(Array(server.chats.prefix(120)))
        let library = makeLibrary(server)
        await library.loadCached()
        await library.refresh()
        #expect(library.chats.count == 120)

        await library.loadMore()
        #expect(library.chats.count == 180, "one call reaches past the cache: pages 2 and 3")
        #expect(library.chats.last?.id == server.chats[179].id)
        #expect(server.requestedPages == [1, 2, 3])
    }

    @Test func eachPageDropsCachedChatsTheServerNoLongerLists() async throws {
        let server = PagedChatsServer(count: 130)
        // Deleted on another device: one inside page 2's time range, one older than every Chat.
        let middle = server.chats[90].updatedAt.addingTimeInterval(30)
        let ghosts = [
            summary("ghost-page-2", updated: middle.timeIntervalSince1970),
            summary("ghost-oldest", updated: 1),
        ]
        try await database.saveChatSummaries(ghosts)
        let library = makeLibrary(server)
        await library.loadCached()
        await library.refresh()
        #expect(library.chats.contains { $0.id == "ghost-page-2" }, "older than page 1: not judged yet")

        // The cached ghost stays the last row until the last page, so one call walks to the end.
        await library.loadMore()
        #expect(server.requestedPages == [1, 2, 3])
        #expect(library.chats.map(\.id) == server.chats.map(\.id))
        #expect(try await database.chatSummaries().map(\.id) == server.chats.map(\.id))
    }

    @Test func chatsWithTheSameTimeAcrossAPageBoundaryStay() async throws {
        // Rows 55…65 share one time, so they straddle pages 1 and 2.
        let server = PagedChatsServer(count: 100, sameTime: { (56...65).contains($0) })
        try await database.saveChatSummaries(server.chats)
        let library = makeLibrary(server)
        await library.loadCached()
        await library.refresh()
        #expect(library.chats.count == 100, "the boundary's rows on page 2 aren't stale")

        await scrollToTheEnd(library)
        #expect(Set(library.chats.map(\.id)) == Set(server.chats.map(\.id)))
    }

    @Test func concurrentRequestsShareThePages() async throws {
        let server = PagedChatsServer(count: 200)
        let library = makeLibrary(server)
        await library.refresh()
        async let first: Void = library.loadMore()
        async let second: Void = library.loadMore()
        _ = await (first, second)
        #expect(server.requestedPages == [1, 2], "the second caller waits for the first one's page")
        #expect(library.chats.count == 120)
    }

    @Test func archivedAndProjectChatsKeepTheirCachedState() async throws {
        let server = PagedChatsServer(count: 70)
        var archived = summary("archived", updated: server.chats[65].updatedAt.timeIntervalSince1970 + 1)
        archived.isArchived = true
        var inProject = server.chats[65]
        inProject.projectID = "project-1"
        try await database.saveChatSummaries([archived, inProject])
        let library = makeLibrary(server)
        await library.refresh()
        await scrollToTheEnd(library)
        #expect(library.chat(id: inProject.id)?.projectID == "project-1")
        #expect(try await database.chatSummaries(includeArchived: true).contains { $0.id == "archived" })
    }

    // MARK: Reducers

    @Test func mergeInsertsAPageAndDropsOnlyUnlistedChatsInItsRange() {
        let chats = [
            summary("newer", updated: 100),
            summary("kept-in-range", updated: 80, starred: true),
            summary("gone-in-range", updated: 70),
            summary("boundary-tie", updated: 60),
            summary("older", updated: 10),
        ]
        let page = [summary("kept-in-range", "Renamed", updated: 80), summary("new", updated: 75), summary("lower", updated: 60)]
        let merged = ChatLibrary.merge(
            page: page,
            into: chats,
            newerThan: Date(timeIntervalSince1970: 60),
            upTo: Date(timeIntervalSince1970: 90),
            listed: Set(page.map(\.id))
        )
        #expect(merged.map(\.id) == ["newer", "kept-in-range", "new", "lower", "boundary-tie", "older"])
        #expect(merged[1].title == "Renamed")
        #expect(merged[1].isStarred, "list rows don't know Starred; the known flag stays")
    }

    @Test func theCursorBoundsEachPageByTheOldestTimeSeen() {
        var cursor = PageCursor()
        let first = [summary("a", updated: 100), summary("b", updated: 90)]
        #expect(cursor.range(of: first, isLast: false) == (Date(timeIntervalSince1970: 90), nil))
        cursor.record(first)
        let second = [summary("c", updated: 80), summary("d", updated: 70)]
        #expect(cursor.range(of: second, isLast: false) == (Date(timeIntervalSince1970: 70), Date(timeIntervalSince1970: 90)))
        #expect(cursor.range(of: second, isLast: true) == (nil, Date(timeIntervalSince1970: 90)))
        cursor.record(second)
        #expect(cursor.pages == 2)
        #expect(cursor.seenIDs == ["a", "b", "c", "d"])
    }

    // MARK: Search

    @Test func serverSearchPagesThroughEveryMatch() async throws {
        let server = PagedChatsServer(count: 0)
        let hits = (0..<75).map { summary("hit-\($0)", "Hit \($0)", updated: TimeInterval(1_000 - $0)) }
        server.transport.stub("GET", "api/v1/chats/search") { request in
            let page = request.url?.query()?.contains("page=2") == true ? Array(hits[60...]) : Array(hits[..<60])
            return (200, PagedChatsServer.wire(page))
        }
        let library = makeLibrary(server)
        let search = ChatSearch(library: library)
        search.query = "hit"
        await search.run(debounce: .zero)
        #expect(search.results.count == 60)
        #expect(search.hasMore)

        await search.loadMore()
        #expect(search.results.map(\.id) == hits.map(\.id))
        #expect(!search.hasMore)
    }
}
