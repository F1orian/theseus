import ChatDomain
import Foundation
@testable import Persistence
import Testing

@Suite("Shared container: snapshot and Share inbox (PLAT-01, PLAT-03, PLAT-04)")
struct SharedContainerTests {
    let container = SharedContainer.temporary()

    func chat(_ id: String, minutesAgo: Double, archived: Bool = false) -> ChatSummary {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
        return ChatSummary(id: id, title: "Chat \(id)", createdAt: date, updatedAt: date, isArchived: archived)
    }

    @Test func snapshotListsSavedChatsNewestFirstWithoutArchived() throws {
        let snapshot = SharedSnapshot(
            accountID: "https://chat.example.com|u1",
            accountName: "Ada",
            serverHost: "chat.example.com",
            actions: .init(voiceMode: true),
            chats: [chat("old", minutesAgo: 60), chat("new", minutesAgo: 1), chat("gone", minutesAgo: 5, archived: true)]
        )
        #expect(snapshot.recentChats.map(\.id) == ["new", "old"])

        let store = SharedSnapshotStore(container: container)
        #expect(store.read() == nil)
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func enforcedIncognitoLeavesNoHistory() {
        let snapshot = SharedSnapshot(
            accountID: "a", accountName: "Ada", serverHost: "h", actions: .init(),
            chats: [chat("c", minutesAgo: 1)], savesChats: false
        )
        #expect(snapshot.recentChats.isEmpty)
    }

    /// ADR 0173: the Pro flag round-trips, and snapshots from before it decode as unlocked.
    @Test func snapshotsCarryTheProFlag() throws {
        let store = SharedSnapshotStore(container: .temporary())
        let locked = SharedSnapshot(accountID: "a", accountName: "A", serverHost: "h", actions: .init(), recentChats: [], isProUnlocked: false)
        try store.write(locked)
        #expect(store.read()?.isProUnlocked == false)
        let old = Data(#"{"accountID":"a","accountName":"A","serverHost":"h","actions":{"voiceMode":true,"dictation":false,"photos":false,"incognitoChat":false},"recentChats":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(SharedSnapshot.self, from: old)
        #expect(decoded.isProUnlocked)
        #expect(decoded.actions.voiceMode)
    }

    @Test func snapshotKeepsAtMostTheLimit() {
        let chats = (0..<80).map { chat("\($0)", minutesAgo: Double($0)) }
        let snapshot = SharedSnapshot(accountID: "a", accountName: "Ada", serverHost: "h", actions: .init(), chats: chats)
        #expect(snapshot.recentChats.count == SharedSnapshot.recentChatLimit)
        #expect(snapshot.recentChats.first?.id == "0")
    }

    @Test func aShareRoundTripsThroughTheInbox() throws {
        let inbox = ShareInbox(container: container)
        let photo = Data([0xFF, 0xD8, 0xFF])
        let entry = try inbox.add(
            [
                .text("Look at this"),
                .url(try #require(URL(string: "https://example.com/article"))),
                .file(photo, filename: "IMG/1.jpg", contentType: "image/jpeg"),
                .file(Data("%PDF".utf8), filename: "Report.pdf", contentType: "application/pdf"),
            ],
            note: "Summarise it",
            accountID: "a"
        )
        let loaded = try #require(inbox.entry(id: entry.id))
        #expect(loaded == entry)
        #expect(loaded.prompt == "Summarise it\n\nLook at this\n\nhttps://example.com/article")
        #expect(loaded.files.map(\.kind) == [.image, .file])
        #expect(loaded.files.map(\.filename) == ["IMG/1.jpg", "Report.pdf"])
        #expect(inbox.data(for: loaded.files[0], in: loaded) == photo)
        #expect(inbox.pending().map(\.id) == [entry.id])

        inbox.remove(id: entry.id)
        #expect(inbox.entry(id: entry.id) == nil)
        #expect(inbox.pending().isEmpty)
    }

    @Test func staleSharesExpire() throws {
        let inbox = ShareInbox(container: container)
        let now = Date()
        let old = try inbox.add([.text("old")], now: now.addingTimeInterval(-ShareInbox.lifetime - 60))
        let fresh = try inbox.add([.text("fresh")], now: now)
        inbox.removeExpired(now: now)
        #expect(inbox.pending().map(\.id) == [fresh.id])
        #expect(inbox.entry(id: old.id) == nil)
    }
}
