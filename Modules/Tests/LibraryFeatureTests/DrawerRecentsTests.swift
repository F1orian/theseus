import ChatDomain
import Foundation
@testable import LibraryFeature
import Testing

/// The drawer's capped Recents with "See all" (#172).
@MainActor
@Suite("Drawer Recents")
struct DrawerRecentsTests {
    @Test func recentsShowTheNewestTenThenSeeAll() {
        let chats = (0..<25).map { summary("c\($0)", updated: TimeInterval(100 - $0)) }
        let recents = DrawerRecents(chats)
        #expect(DrawerRecents.limit == 20)
        #expect(recents.shown.map(\.id) == (0..<DrawerRecents.limit).map { "c\($0)" })
        #expect(recents.showsSeeAll)
    }

    @Test func aShortHistoryShowsEveryChatWithoutSeeAll() {
        let recents = DrawerRecents((0..<4).map { summary("c\($0)", updated: TimeInterval(100 - $0)) })
        #expect(recents.shown.count == 4)
        #expect(!recents.showsSeeAll)
    }

    @Test func seeAllShowsWhenTheServerHasOlderChats() {
        // The mirror holds only a few, but more pages exist on the Server.
        let recents = DrawerRecents((0..<4).map { summary("c\($0)", updated: TimeInterval(100 - $0)) }, hasMore: true)
        #expect(recents.showsSeeAll)
    }
}
