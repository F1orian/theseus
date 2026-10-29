public import ChatDomain
import Foundation
public import Observation
public import OpenWebUIKit
public import Persistence

/// The signed-in Account's Chats as the library shows them: the drawer's Starred and Recents, the
/// Chats list, and the star / rename / delete actions (CHATS-01…09).
///
/// Reads come from the Account's mirror cache first (instant launch, offline reading; ADR 0004),
/// then `refresh()` reconciles with the Server. Mutations are optimistic: the UI and the mirror
/// change at once and roll back with an `errorMessage` when the Server refuses.
@MainActor
@Observable
public final class ChatLibrary {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Every non-archived Chat known locally, newest first.
    public private(set) var chats: [ChatSummary] = []
    public private(set) var state: LoadState = .idle
    /// `true` while older pages may exist on the Server.
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    /// The last failed action, for a dismissible notice. Cleared by `dismissError()`.
    public private(set) var errorMessage: String?
    /// The Account-level Capabilities (no Model). Gates delete (`deleteChat`) and Projects.
    public var capabilities = Capabilities(enabled: [])

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let database: AccountDatabase?
    /// The Server list pages walked since the last `refresh()` (#146).
    @ObservationIgnored private var cursor = PageCursor()
    /// Bumped by every `refresh()`, so a `loadMore()` that was in flight doesn't move the new cursor.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?

    public init(client: OpenWebUIClient, database: AccountDatabase?) {
        self.client = client
        self.database = database
    }

    // MARK: Derived lists

    /// Starred chats (server term: pinned) for the drawer's Starred section and the Starred filter.
    public var starred: [ChatSummary] { chats.filter(\.isStarred) }

    /// The drawer's Recents: every Chat that isn't starred.
    public var recents: [ChatSummary] { chats.filter { !$0.isStarred } }

    public func chat(id: String) -> ChatSummary? {
        chats.first { $0.id == id }
    }

    public var canDelete: Bool { capabilities.contains(.deleteChat) }

    // MARK: Loading

    /// Shows the mirror's Chats without touching the network.
    public func loadCached() async {
        guard let database, let cached = try? await database.chatSummaries() else { return }
        chats = cached
    }

    /// Fetches the Starred chats and the newest page (Starred and Project Chats included) and
    /// reconciles the mirror with them.
    public func refresh() async {
        let previous = state
        state = .loading
        do {
            async let starredRequest = client.send(.starredChats)
            async let pageRequest = client.send(.chats(page: 1, includeStarred: true, includeProjects: true))
            let (starred, page) = try await (starredRequest, pageRequest)
            let isComplete = page.count < Endpoint<[ChatSummary]>.chatsPageSize
            if let database {
                try? await database.reconcileChatSummaries(newest: page, isComplete: isComplete)
                try? await database.replaceStarredChats(starred)
            }
            generation += 1
            cursor = PageCursor()
            cursor.record(page)
            hasMore = !isComplete
            await reloadFromMirror(fallback: { merge(page: page, starred: starred) })
            state = .loaded
        } catch {
            // A cancelled refresh (its task ended) failed nothing.
            state = (error as? OpenWebUIError)?.isCancellation == true ? previous : .failed(Self.message(for: error))
        }
    }

    /// Loads older Chats for the infinite scroll of the Chats list and the drawer (#146).
    ///
    /// Walks the Server's list pages after the last one loaded until a page extends the bottom of
    /// `chats` or the Server has no more. Pages the mirror already holds (a relaunch shows every
    /// cached Chat, but `refresh()` only re-reads page 1) are reconciled and skipped, so the list
    /// never stalls at the end of the cache. Each page also drops cached Chats that the Server no
    /// longer lists in that page's time range, which keeps the mirror complete and exact.
    /// The work runs in its own task, so a caller that goes away (a list row's `.task` restarting)
    /// doesn't cancel it, and concurrent callers wait for the same pages.
    public func loadMore() async {
        if let loadMoreTask {
            await loadMoreTask.value
            return
        }
        guard hasMore, state != .loading else { return }
        isLoadingMore = true
        let task = Task { [weak self] in
            await self?.loadNextPages()
            self?.isLoadingMore = false
            self?.loadMoreTask = nil
        }
        loadMoreTask = task
        await task.value
    }

    private func loadNextPages() async {
        let generation = generation
        let tail = chats.last?.id
        do {
            while hasMore, generation == self.generation {
                let number = cursor.pages + 1
                let page = try await client.send(.chats(page: number, includeStarred: true, includeProjects: true))
                guard generation == self.generation else { return }
                let isLast = page.count < Endpoint<[ChatSummary]>.chatsPageSize
                let range = cursor.range(of: page, isLast: isLast)
                cursor.record(page)
                hasMore = !isLast
                let starredIDs = Set(starred.map(\.id))
                let marked = page.map { chat in
                    var chat = chat
                    chat.isStarred = starredIDs.contains(chat.id)
                    return chat
                }
                if let database {
                    try? await database.reconcileChatSummaries(
                        page: marked,
                        newerThan: range.lower,
                        upTo: range.upper,
                        listed: cursor.seenIDs
                    )
                    guard generation == self.generation else { return }
                }
                chats = Self.merge(page: marked, into: chats, newerThan: range.lower, upTo: range.upper, listed: cursor.seenIDs)
                if chats.last?.id != tail { return }
            }
        } catch {
            if !error.isCancellation { errorMessage = error.message }
        }
    }

    /// Adds or updates one Chat (e.g. a new Chat after its first send, or a `chat:title` event).
    public func upsert(_ summary: ChatSummary) {
        insertSorted(summary)
        let database = database
        Task { try? await database?.saveChatSummaries([summary]) }
    }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: Actions

    /// Stars or unstars a Chat (server term: pin toggle).
    public func toggleStar(_ id: String) async {
        guard let original = chat(id: id) else { return }
        var optimistic = original
        optimistic.isStarred.toggle()
        await apply(optimistic)
        do {
            let server = try await client.send(.toggleStar(chatID: id))
            var confirmed = optimistic
            confirmed.isStarred = server.isStarred
            if confirmed != optimistic { await apply(confirmed) }
        } catch {
            await apply(original)
            errorMessage = error.message
        }
    }

    /// Renames a Chat. Blank or unchanged titles are ignored.
    public func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = chat(id: id), !title.isEmpty, title != original.title else { return }
        var renamed = original
        renamed.title = title
        await apply(renamed)
        do {
            let server = try await client.send(.renameChat(id: id, title: title))
            if server.title != title {
                renamed.title = server.title
                await apply(renamed)
            }
        } catch {
            await apply(original)
            errorMessage = error.message
        }
    }

    /// Deletes a Chat on the Server and locally. Returns `false` (and keeps the Chat) when the
    /// Account may not delete Chats or the Server refuses.
    @discardableResult
    public func delete(_ id: String) async -> Bool {
        guard canDelete, let original = chat(id: id) else { return false }
        chats.removeAll { $0.id == id }
        try? await database?.deleteChatSummary(id: id)
        do {
            _ = try await client.send(.deleteChat(id: id))
            return true
        } catch {
            insertSorted(original)
            try? await database?.saveChatSummaries([original])
            errorMessage = error.message
            return false
        }
    }

    // MARK: Search (CHATS-03)

    /// Title matches from the mirror (works offline), newest first.
    func searchLocally(_ query: String) async -> [ChatSummary] {
        guard let database else {
            let terms = SearchHighlighter.terms(in: query)
            return chats.filter { chat in terms.allSatisfy { chat.title.localizedStandardContains($0) } }
        }
        return (try? await database.searchChatSummaries(matching: query)) ?? []
    }

    /// Title and Message matches from the Server.
    func searchServer(_ query: String, page: Int = 1) async throws(OpenWebUIError) -> [ChatSummary] {
        let starredIDs = Set(starred.map(\.id))
        return try await client.send(.searchChats(text: query, page: page)).map { hit in
            var hit = hit
            hit.isStarred = starredIDs.contains(hit.id)
            return hit
        }
    }

    // MARK: Private

    private static func message(for error: any Error) -> String {
        (error as? OpenWebUIError)?.message ?? OpenWebUIError.transport(.unknown).message
    }

    private func apply(_ summary: ChatSummary) async {
        insertSorted(summary)
        try? await database?.saveChatSummaries([summary])
    }

    private func insertSorted(_ summary: ChatSummary) {
        chats.removeAll { $0.id == summary.id }
        let index = chats.firstIndex { $0.updatedAt < summary.updatedAt } ?? chats.endIndex
        chats.insert(summary, at: index)
    }

    private func reloadFromMirror(fallback: () -> [ChatSummary]) async {
        if let database, let mirrored = try? await database.chatSummaries() {
            chats = mirrored
        } else {
            chats = fallback()
        }
    }

    /// `chats` with one list page merged in (#146): the page's rows are inserted or updated, and
    /// every non-archived Chat in the page's time range `(lower, upper]` that the Server didn't list
    /// in this pass is dropped (deleted on another device). Newest first.
    static func merge(
        page: [ChatSummary],
        into chats: [ChatSummary],
        newerThan lower: Date?,
        upTo upper: Date?,
        listed: Set<String>
    ) -> [ChatSummary] {
        var byID: [String: ChatSummary] = [:]
        for chat in chats {
            let inRange = (lower.map { chat.updatedAt > $0 } ?? true) && (upper.map { chat.updatedAt <= $0 } ?? true)
            if inRange, !chat.isArchived, !listed.contains(chat.id) { continue }
            byID[chat.id] = chat
        }
        for chat in page {
            var chat = chat
            if let known = byID[chat.id] {
                chat.isStarred = chat.isStarred || known.isStarred
                chat.projectID = chat.projectID ?? known.projectID
                chat.lastReadAt = chat.lastReadAt ?? known.lastReadAt
            }
            byID[chat.id] = chat
        }
        return byID.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    private func merge(page: [ChatSummary], starred: [ChatSummary]) -> [ChatSummary] {
        let starredIDs = Set(starred.map(\.id))
        var byID: [String: ChatSummary] = [:]
        for chat in page {
            var chat = chat
            chat.isStarred = starredIDs.contains(chat.id)
            byID[chat.id] = chat
        }
        for chat in starred {
            byID[chat.id] = chat
        }
        return byID.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}

/// Where `ChatLibrary` is in the Server's Chat list (`GET /api/v1/chats/?page=`, newest first,
/// 60 per page; #146): how many pages it walked since the last refresh, the Chats they listed and
/// the oldest time seen, which bounds the next page's range.
struct PageCursor: Equatable {
    private(set) var pages = 0
    private(set) var seenIDs: Set<String> = []
    /// The oldest `updatedAt` on the pages walked so far.
    private(set) var oldest: Date?

    mutating func record(_ page: [ChatSummary]) {
        pages += 1
        seenIDs.formUnion(page.map(\.id))
        if let pageOldest = page.map(\.updatedAt).min() {
            oldest = min(oldest ?? pageOldest, pageOldest)
        }
    }

    /// The time range `(lower, upper]` the next `page` covers: from its oldest row (exclusive, as
    /// rows with that time may continue on the following page) up to the oldest row seen before.
    /// The last page reaches back to the beginning (`lower == nil`).
    func range(of page: [ChatSummary], isLast: Bool) -> (lower: Date?, upper: Date?) {
        let lower = isLast ? nil : page.map(\.updatedAt).min()
        return (lower, oldest)
    }
}
