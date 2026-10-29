public import ChatDomain
public import Foundation
public import Observation
import OpenWebUIKit

/// Search in the Chats list (CHATS-03). Each keystroke shows title matches from the mirror at
/// once (offline-capable FTS5), then, after a short pause, merges the Server's results, which
/// also match Message text and carry a snippet.
@MainActor
@Observable
public final class ChatSearch {
    public var query = ""
    /// Matches, newest first. Empty while `query` is blank.
    public private(set) var results: [ChatSummary] = []
    public private(set) var isSearchingServer = false
    /// The Server search failed (e.g. offline); `results` are local title matches only.
    public private(set) var isLocalOnly = false
    /// `true` while the Server may have more matches than `results` holds (#146).
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false

    @ObservationIgnored private let library: ChatLibrary
    @ObservationIgnored private var local: [ChatSummary] = []
    @ObservationIgnored private var remote: [ChatSummary] = []
    @ObservationIgnored private var remotePages = 0
    /// The query `remote` belongs to.
    @ObservationIgnored private var remoteQuery = ""
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?

    public init(library: ChatLibrary) {
        self.library = library
    }

    public var isActive: Bool { !trimmedQuery.isEmpty }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Runs the search for the current `query`. Call it from `.task(id: query)` so a new keystroke
    /// cancels the previous run; `debounce` delays only the Server request.
    public func run(debounce: Duration = .milliseconds(300)) async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            results = []
            isLocalOnly = false
            resetRemote()
            return
        }
        let local = await library.searchLocally(query)
        guard !Task.isCancelled, query == trimmedQuery else { return }
        self.local = local
        resetRemote()
        results = local

        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        isSearchingServer = true
        defer { isSearchingServer = false }
        do {
            let remote = try await library.searchServer(query, page: 1)
            guard !Task.isCancelled, query == trimmedQuery else { return }
            self.remote = remote
            remotePages = 1
            remoteQuery = query
            hasMore = remote.count >= Endpoint<[ChatSummary]>.searchPageSize
            results = Self.merge(local: local, remote: remote)
            isLocalOnly = false
        } catch {
            guard !Task.isCancelled else { return }
            isLocalOnly = true
        }
    }

    /// Loads the Server's next page of matches for the current query (infinite scroll, #146).
    /// Runs in its own task, so a restarting caller (a list row's `.task`) doesn't cancel it.
    public func loadMore() async {
        if let loadMoreTask {
            await loadMoreTask.value
            return
        }
        let query = trimmedQuery
        guard hasMore, query == remoteQuery else { return }
        isLoadingMore = true
        let task = Task { [weak self] in
            await self?.loadNextPage(query)
            self?.isLoadingMore = false
            self?.loadMoreTask = nil
        }
        loadMoreTask = task
        await task.value
    }

    private func loadNextPage(_ query: String) async {
        do {
            let page = try await library.searchServer(query, page: remotePages + 1)
            guard query == trimmedQuery, query == remoteQuery else { return }
            remotePages += 1
            remote += page
            hasMore = page.count >= Endpoint<[ChatSummary]>.searchPageSize
            results = Self.merge(local: local, remote: remote)
        } catch {
            // Keep what's shown; scrolling to the end again retries.
        }
    }

    public func clear() {
        query = ""
        results = []
        isLocalOnly = false
        local = []
        resetRemote()
    }

    private func resetRemote() {
        remote = []
        remotePages = 0
        remoteQuery = ""
        hasMore = false
    }

    /// Union by id. The Server's row wins (it has the snippet), newest first.
    static func merge(local: [ChatSummary], remote: [ChatSummary]) -> [ChatSummary] {
        var byID: [String: ChatSummary] = [:]
        for chat in local { byID[chat.id] = chat }
        for chat in remote {
            var chat = chat
            if let known = byID[chat.id] {
                chat.isStarred = chat.isStarred || known.isStarred
            }
            byID[chat.id] = chat
        }
        return byID.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}

/// Bolds the parts of a title that match a search query.
public enum SearchHighlighter {
    /// The whitespace-separated terms of `query`.
    public static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `text` with every case- and accent-insensitive occurrence of a `query` term strongly
    /// emphasised (SwiftUI renders it bold).
    public static func highlight(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        for term in terms(in: query) {
            var searchRange = text.startIndex..<text.endIndex
            while let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let lower = AttributedString.Index(match.lowerBound, within: attributed),
                   let upper = AttributedString.Index(match.upperBound, within: attributed) {
                    attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                guard match.upperBound < text.endIndex else { break }
                searchRange = match.upperBound..<text.endIndex
            }
        }
        return attributed
    }
}
