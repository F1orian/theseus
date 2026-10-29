import ChatDomain
import Foundation
import Persistence
import Testing

/// Local cache controls on the Data & privacy page (SET-07).
@Suite("Account cache controls")
struct CacheControlTests {
    func summary(_ id: String) -> ChatSummary {
        ChatSummary(id: id, title: "Chat \(id)", createdAt: .now, updatedAt: .now)
    }

    @Test func erasingEmptiesTheMirrorButKeepsItUsable() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([summary("a"), summary("b")])
        try await database.eraseAll()
        #expect(try await database.chatSummaries().isEmpty)
        #expect(try await database.searchChatSummaries(matching: "Chat").isEmpty)

        try await database.saveChatSummaries([summary("c")])
        #expect(try await database.chatSummaries().map(\.id) == ["c"])
    }

    @Test func diskUsageCountsTheDatabaseFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AccountDatabase(fileURL: directory.appending(path: "account.sqlite"))
        try await database.saveChatSummaries((0..<50).map { summary("\($0)") })
        let size = try #require(database.diskUsage())
        #expect(size > 0)
        #expect(try AccountDatabase.inMemory().diskUsage() == nil)
    }
}
