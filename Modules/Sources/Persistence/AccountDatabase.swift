public import ChatDomain
import CryptoKit
public import Foundation
import GRDB

/// The read-through mirror cache of one Account (ADR 0004). Every (Server, Account) pair gets
/// its own SQLite file, so switching Accounts can never leak data between them.
public final class AccountDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `fileURL` and migrates it to the latest schema.
    public convenience init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "Theseus.AccountDatabase"
        try self.init(writer: DatabasePool(path: fileURL.path, configuration: configuration))
    }

    /// An ephemeral database for tests, previews and Incognito-style throwaway sessions.
    public static func inMemory() throws -> AccountDatabase {
        try AccountDatabase(writer: DatabaseQueue())
    }

    /// The database file for `accountKey` (e.g. `"https://chat.example.com|<user id>"`) inside
    /// `directory`. The key is hashed so it is filesystem-safe and does not leak the email/URL.
    public static func fileURL(forAccountKey accountKey: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(accountKey.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: "account.sqlite", directoryHint: .notDirectory)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    // MARK: Chat list mirror

    /// Mirrored Chats, newest first.
    public func chatSummaries(includeArchived: Bool = false) async throws -> [ChatSummary] {
        try await writer.read { db in
            var request = ChatSummaryRecord.order(ChatSummaryRecord.Columns.updatedAt.desc)
            if !includeArchived {
                request = request.filter(ChatSummaryRecord.Columns.isArchived == false)
            }
            return try request.fetchAll(db).map(\.domain)
        }
    }

    /// Inserts or updates `summaries` (e.g. one fetched page), leaving other rows untouched.
    public func saveChatSummaries(_ summaries: [ChatSummary]) async throws {
        try await writer.write { db in
            for summary in summaries {
                try ChatSummaryRecord(summary).upsert(db)
            }
        }
    }

    /// Makes the mirror exactly `summaries` (after a full list sync), deleting Chats the server
    /// no longer returns.
    public func replaceChatSummaries(_ summaries: [ChatSummary]) async throws {
        try await writer.write { db in
            _ = try ChatSummaryRecord.deleteAll(db)
            for summary in summaries {
                try ChatSummaryRecord(summary).insert(db)
            }
        }
    }

    /// The schema version names applied to this database, oldest first.
    public func appliedMigrations() async throws -> [String] {
        try await writer.read { db in try Schema.migrator.appliedMigrations(db) }
    }
}

// MARK: Cache controls (SET-07)

extension AccountDatabase {
    /// Erases everything mirrored for this Account and recreates the empty schema. The next
    /// refresh reloads from the Server.
    public func eraseAll() async throws {
        try await writer.erase()
        try Schema.migrator.migrate(writer)
    }

    /// Bytes on disk (database plus WAL and shared-memory files), or `nil` for in-memory databases.
    public func diskUsage() -> Int64? {
        let path = writer.path
        guard !path.isEmpty, path != ":memory:", FileManager.default.fileExists(atPath: path) else { return nil }
        return ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }
}
