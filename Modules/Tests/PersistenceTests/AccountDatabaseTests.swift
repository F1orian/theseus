import ChatDomain
import Foundation
import Persistence
import Testing

private func summary(_ id: String, updated: TimeInterval, archived: Bool = false) -> ChatSummary {
    ChatSummary(
        id: id,
        title: "Chat \(id)",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: updated),
        lastReadAt: Date(timeIntervalSince1970: updated - 1),
        snippet: nil,
        isArchived: archived
    )
}

@Suite("AccountDatabase")
struct AccountDatabaseTests {
    @Test func migratesToLatestSchema() async throws {
        let database = try AccountDatabase.inMemory()
        #expect(try await database.appliedMigrations() == ["v1_chatSummary", "v2_chatLibrary"])
    }

    @Test func chatListRoundTripsNewestFirst() async throws {
        let database = try AccountDatabase.inMemory()
        let chats = [summary("a", updated: 10), summary("b", updated: 30), summary("c", updated: 20)]
        try await database.saveChatSummaries(chats)

        let stored = try await database.chatSummaries()
        #expect(stored.map(\.id) == ["b", "c", "a"])
        #expect(stored.first == chats[1])
    }

    @Test func saveUpsertsWithoutDeletingOtherRows() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([summary("a", updated: 10), summary("b", updated: 20)])
        var renamed = summary("a", updated: 40)
        renamed.title = "Renamed"
        try await database.saveChatSummaries([renamed])

        let stored = try await database.chatSummaries()
        #expect(stored.map(\.id) == ["a", "b"])
        #expect(stored.first?.title == "Renamed")
    }

    @Test func replaceDropsChatsTheServerNoLongerHas() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([summary("a", updated: 10), summary("b", updated: 20)])
        try await database.replaceChatSummaries([summary("c", updated: 5)])
        #expect(try await database.chatSummaries().map(\.id) == ["c"])
    }

    @Test func archivedChatsAreHiddenByDefault() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([summary("a", updated: 10), summary("z", updated: 20, archived: true)])
        #expect(try await database.chatSummaries().map(\.id) == ["a"])
        #expect(try await database.chatSummaries(includeArchived: true).map(\.id) == ["z", "a"])
    }

    @Test func eachAccountGetsItsOwnFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "theseus-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AccountDatabase.fileURL(forAccountKey: "https://a.example|user-1", in: directory)
        let second = AccountDatabase.fileURL(forAccountKey: "https://a.example|user-2", in: directory)
        #expect(first != second)
        #expect(first == AccountDatabase.fileURL(forAccountKey: "https://a.example|user-1", in: directory), "stable")
        #expect(!first.path().contains("a.example"), "file names don't leak the account key")

        do {
            let database = try AccountDatabase(fileURL: first)
            try await database.saveChatSummaries([summary("only-in-first", updated: 1)])
        }
        let reopened = try AccountDatabase(fileURL: first)
        #expect(try await reopened.chatSummaries().map(\.id) == ["only-in-first"])
        #expect(try await AccountDatabase(fileURL: second).chatSummaries().isEmpty)
    }
}
