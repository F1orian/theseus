import ChatDomain
import Fixtures
import Foundation
@testable import LibraryFeature
import OpenWebUIKit
import Persistence
import Testing

@MainActor
@Suite("ChatSearch")
struct ChatSearchTests {
    let transport = StubTransport()
    let database: AccountDatabase
    let library: ChatLibrary

    init() async throws {
        database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([
            summary("local-1", "Weekly dinner planning", updated: 1_900_000_000),
            summary("local-2", "Trip notes", updated: 1_800_000_000, starred: true),
        ])
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
        library = ChatLibrary(client: client, database: database)
        await library.loadCached()
    }

    @Test func blankQueriesShowNothingAndSendNothing() async {
        let search = ChatSearch(library: library)
        search.query = "   "
        await search.run(debounce: .zero)
        #expect(!search.isActive)
        #expect(search.results.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func mirrorTitleMatchesMergeWithServerResults() async throws {
        try transport.stub("GET", "api/v1/chats/search", fixture: "chats.search.json")
        let search = ChatSearch(library: library)
        search.query = "plan "
        await search.run(debounce: .zero)

        #expect(search.results.count == 61, "60 Server hits plus the local-only title match")
        #expect(search.results.first?.id == "local-1", "newest first")
        #expect(search.results.contains { $0.snippet == "...matching text 1..." })
        #expect(!search.isLocalOnly)
        let sent = try #require(transport.requests.last?.url?.query())
        #expect(sent.contains("text=plan"))
    }

    @Test func offlineSearchFallsBackToTheMirror() async {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: OfflineTransport(), authorizer: StaticAuthorizer())
        let offline = ChatLibrary(client: client, database: database)
        await offline.loadCached()
        let search = ChatSearch(library: offline)
        search.query = "trip"
        await search.run(debounce: .zero)
        #expect(search.results.map(\.id) == ["local-2"])
        #expect(search.results.first?.isStarred == true)
        #expect(search.isLocalOnly)
    }

    @Test func serverHitsKnowWhichChatsAreStarred() {
        let local = [summary("a", updated: 5, starred: true)]
        var hit = summary("a", updated: 5)
        hit.snippet = "...x..."
        let merged = ChatSearch.merge(local: local, remote: [hit, summary("b", updated: 9)])
        #expect(merged.map(\.id) == ["b", "a"])
        #expect(merged[1].isStarred)
        #expect(merged[1].snippet == "...x...")
    }

    @Test func clearResetsTheSearch() async throws {
        try transport.stub("GET", "api/v1/chats/search", fixture: "chats.search.json")
        let search = ChatSearch(library: library)
        search.query = "plan"
        await search.run(debounce: .zero)
        search.clear()
        #expect(search.query.isEmpty)
        #expect(search.results.isEmpty)
    }
}

@Suite("SearchHighlighter")
struct SearchHighlighterTests {
    private func bold(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.inlinePresentationIntent == .stronglyEmphasized ? String(text[run.range].characters) : nil
        }
    }

    @Test func boldsEveryOccurrenceIgnoringCaseAndAccents() {
        let text = SearchHighlighter.highlight("Casual greeting exchange, Greeting café", query: "greeting CAFE")
        #expect(bold(text) == ["greeting", "Greeting", "café"])
        #expect(String(text.characters) == "Casual greeting exchange, Greeting café")
    }

    @Test func noMatchLeavesThePlainTitle() {
        #expect(bold(SearchHighlighter.highlight("Untitled", query: "zebra")).isEmpty)
        #expect(bold(SearchHighlighter.highlight("Untitled", query: "")).isEmpty)
    }
}
