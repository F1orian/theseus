public import ChatDomain
public import Foundation
import GRDB

// The Chats library side of the mirror (CHATS-01…07): Starred, reconciliation with the server's
// newest page, deletion and offline title search (FTS5).
extension AccountDatabase {
    /// Starred chats (server term: pinned), newest first. Archived Chats are excluded.
    public func starredChatSummaries() async throws -> [ChatSummary] {
        try await writer.read { db in
            try ChatSummaryRecord
                .filter(ChatSummaryRecord.Columns.isStarred == true && ChatSummaryRecord.Columns.isArchived == false)
                .order(ChatSummaryRecord.Columns.updatedAt.desc)
                .fetchAll(db)
                .map(\.domain)
        }
    }

    /// Makes `starred` (the server's complete `/chats/pinned` list) the only starred Chats: they're
    /// upserted as starred and every other Chat is unstarred.
    public func replaceStarredChats(_ starred: [ChatSummary]) async throws {
        try await writer.write { db in
            try ChatSummaryRecord
                .filter(ChatSummaryRecord.Columns.isStarred == true)
                .updateAll(db, ChatSummaryRecord.Columns.isStarred.set(to: false))
            for summary in starred {
                var record = try Self.merged(summary, into: db)
                record.isStarred = true
                try record.upsert(db)
            }
        }
    }

    /// Mirrors `newest`, the server's newest Chats (its first list page, starred and Project
    /// Chats included), and deletes cached Chats the server no longer has: every non-archived Chat
    /// more recent than the oldest one in `newest` that isn't in it, or, when `isComplete`
    /// (the server returned fewer than a full page), every non-archived Chat not in it.
    /// List rows don't know Starred or Projects, so cached values for those are kept.
    public func reconcileChatSummaries(newest: [ChatSummary], isComplete: Bool) async throws {
        if !isComplete, newest.isEmpty { return }
        try await reconcileChatSummaries(
            page: newest,
            newerThan: isComplete ? nil : newest.map(\.updatedAt).min(),
            upTo: nil,
            listed: Set(newest.map(\.id))
        )
    }

    /// Mirrors one page of the server's Chat list (#146) and deletes the cached non-archived Chats
    /// in the page's time range `(lower, upper]` (a `nil` bound is open) that the server didn't
    /// list in this pass (`listed`, which includes earlier pages). The lower bound is exclusive
    /// because Chats with the page's oldest time may continue on the next page.
    public func reconcileChatSummaries(
        page: [ChatSummary],
        newerThan lower: Date?,
        upTo upper: Date?,
        listed: Set<String>
    ) async throws {
        try await writer.write { db in
            let ids = Array(listed.union(page.map(\.id)))
            var stale = ChatSummaryRecord
                .filter(ChatSummaryRecord.Columns.isArchived == false)
                .filter(!ids.contains(ChatSummaryRecord.Columns.id))
            if let lower { stale = stale.filter(ChatSummaryRecord.Columns.updatedAt > lower) }
            if let upper { stale = stale.filter(ChatSummaryRecord.Columns.updatedAt <= upper) }
            _ = try stale.deleteAll(db)
            for summary in page {
                try Self.merged(summary, into: db).upsert(db)
            }
        }
    }

    /// Removes one Chat from the mirror (after it was deleted on the server).
    public func deleteChatSummary(id: String) async throws {
        try await writer.write { db in
            _ = try ChatSummaryRecord.deleteOne(db, key: id)
        }
    }

    /// Offline search: non-archived Chats whose title contains a word starting with every term of
    /// `query` (case- and accent-insensitive), newest first. Search syntax in `query` is ignored.
    public func searchChatSummaries(matching query: String, limit: Int = 5_000) async throws -> [ChatSummary] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await writer.read { db in
            try ChatSummaryRecord.fetchAll(
                db,
                sql: """
                    SELECT chatSummary.* FROM chatSummary
                    JOIN chatSummaryFTS ON chatSummaryFTS.rowid = chatSummary.rowid
                    WHERE chatSummaryFTS MATCH ? AND chatSummary.isArchived = 0
                    ORDER BY chatSummary.updatedAt DESC
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            ).map(\.domain)
        }
    }

    /// `summary` as a record, keeping the cached Starred flag, Project and read time when the
    /// incoming value can't know them.
    private static func merged(_ summary: ChatSummary, into db: Database) throws -> ChatSummaryRecord {
        var record = ChatSummaryRecord(summary)
        if let existing = try ChatSummaryRecord.fetchOne(db, key: summary.id) {
            record.isStarred = existing.isStarred || summary.isStarred
            record.projectID = summary.projectID ?? existing.projectID
            record.lastReadAt = summary.lastReadAt ?? existing.lastReadAt
        }
        return record
    }
}
