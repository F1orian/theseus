import ChatDomain
import Foundation
import Persistence
import Testing

private func chat(
    _ id: String,
    _ title: String? = nil,
    updated: TimeInterval,
    starred: Bool = false,
    archived: Bool = false
) -> ChatSummary {
    ChatSummary(
        id: id,
        title: title ?? "Chat \(id)",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: updated),
        isArchived: archived,
        isStarred: starred
    )
}

/// The Chats library side of the mirror cache: Starred, reconciliation, deletion and local search.
@Suite("AccountDatabase · Chats library")
struct ChatLibraryMirrorTests {
    @Test func starredAndProjectRoundTrip() async throws {
        let database = try AccountDatabase.inMemory()
        var inProject = chat("p", updated: 5)
        inProject.projectID = "folder-1"
        try await database.saveChatSummaries([chat("s", updated: 10, starred: true), inProject])

        let stored = try await database.chatSummaries()
        #expect(stored.map(\.id) == ["s", "p"])
        #expect(stored[0].isStarred)
        #expect(stored[1].projectID == "folder-1")
    }

    @Test func starredChatsAreTheStarredSubsetNewestFirst() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([
            chat("a", updated: 10, starred: true),
            chat("b", updated: 30),
            chat("c", updated: 20, starred: true),
        ])
        #expect(try await database.starredChatSummaries().map(\.id) == ["c", "a"])
    }

    @Test func replacingTheStarredSetUnstarsTheRest() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([chat("a", updated: 10, starred: true), chat("b", updated: 20)])

        try await database.replaceStarredChats([chat("b", updated: 25, starred: true), chat("new", updated: 1)])

        let stored = try await database.chatSummaries()
        #expect(stored.filter(\.isStarred).map(\.id).sorted() == ["b", "new"])
        #expect(stored.first { $0.id == "a" }?.isStarred == false, "no longer starred on the server")
        #expect(stored.first { $0.id == "b" }?.updatedAt == Date(timeIntervalSince1970: 25))
    }

    @Test func reconcilingTheNewestPageDropsChatsDeletedElsewhere() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([
            chat("kept", updated: 50),
            chat("deleted-elsewhere", updated: 40),
            chat("older-not-yet-loaded", updated: 5),
            chat("archived", updated: 45, archived: true),
        ])

        // The server's first page reaches back to t=30; anything newer that it didn't return is gone.
        try await database.reconcileChatSummaries(newest: [chat("kept", updated: 50), chat("fresh", updated: 30)], isComplete: false)

        #expect(try await database.chatSummaries(includeArchived: true).map(\.id) == ["kept", "archived", "fresh", "older-not-yet-loaded"])
    }

    @Test func reconcilingAnOlderPageJudgesOnlyItsTimeRange() async throws {
        // #146: page 2 covers (20, 40]; page 1 listed "newest" and "tie" (t=40) already.
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([
            chat("newest", updated: 60),
            chat("tie", updated: 40),
            chat("gone", updated: 30),
            chat("lower-tie", updated: 20),
            chat("older", updated: 5),
        ])
        try await database.reconcileChatSummaries(
            page: [chat("page-2", updated: 35), chat("page-2-last", updated: 20)],
            newerThan: Date(timeIntervalSince1970: 20),
            upTo: Date(timeIntervalSince1970: 40),
            listed: ["newest", "tie", "page-2", "page-2-last"]
        )
        #expect(try await database.chatSummaries().map(\.id).sorted() == ["lower-tie", "newest", "older", "page-2", "page-2-last", "tie"])
    }

    @Test func reconcilingACompleteListDropsEverythingElse() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([chat("a", updated: 50), chat("old", updated: 1)])
        try await database.reconcileChatSummaries(newest: [chat("a", updated: 50)], isComplete: true)
        #expect(try await database.chatSummaries().map(\.id) == ["a"])
    }

    @Test func reconcilingKeepsTheStarredFlagOfKnownChats() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([chat("a", updated: 50, starred: true)])
        // List pages can't tell whether a Chat is starred.
        try await database.reconcileChatSummaries(newest: [chat("a", "Renamed", updated: 60)], isComplete: true)
        let stored = try #require(try await database.chatSummaries().first)
        #expect(stored.title == "Renamed")
        #expect(stored.isStarred)
    }

    @Test func deleteRemovesOneChat() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([chat("a", updated: 1), chat("b", updated: 2)])
        try await database.deleteChatSummary(id: "b")
        #expect(try await database.chatSummaries().map(\.id) == ["a"])
    }

    @Test func searchMatchesTitleWordPrefixesCaseAndAccentInsensitively() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([
            chat("1", "Weekly dinner planning", updated: 10),
            chat("2", "Café recommendations", updated: 20),
            chat("3", "Planning a trip to Kyoto", updated: 30),
            chat("4", "Archived plan", updated: 40, archived: true),
        ])

        #expect(try await database.searchChatSummaries(matching: "plan").map(\.id) == ["3", "1"])
        #expect(try await database.searchChatSummaries(matching: "PLANNING dinner").map(\.id) == ["1"])
        #expect(try await database.searchChatSummaries(matching: "cafe").map(\.id) == ["2"])
        #expect(try await database.searchChatSummaries(matching: "  ").isEmpty)
        #expect(try await database.searchChatSummaries(matching: "\"(*").isEmpty, "FTS syntax is not interpreted")
    }

    @Test func searchFollowsRenamesAndDeletes() async throws {
        let database = try AccountDatabase.inMemory()
        try await database.saveChatSummaries([chat("1", "Old title", updated: 10), chat("2", "Other", updated: 5)])
        try await database.saveChatSummaries([chat("1", "Fresh title", updated: 11)])
        try await database.deleteChatSummary(id: "2")

        #expect(try await database.searchChatSummaries(matching: "old").isEmpty)
        #expect(try await database.searchChatSummaries(matching: "fresh").map(\.id) == ["1"])
        #expect(try await database.searchChatSummaries(matching: "other").isEmpty)
    }
}
