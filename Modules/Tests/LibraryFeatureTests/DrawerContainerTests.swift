@testable import LibraryFeature
import SwiftUI
import Testing

/// The drawer's geometry while it's dragged (CHATS-01, ADR 0130).
@MainActor
@Suite("Drawer container")
struct DrawerContainerTests {
    typealias Drawer = DrawerContainer<EmptyView, EmptyView>

    @Test func theDrawerIsAtMost340PointsWide() {
        #expect(Drawer.drawerWidth(for: 390) == 312)
        #expect(Drawer.drawerWidth(for: 1_024) == 340)
    }

    @Test func dragTracksTheFingerBetweenClosedAndOpen() {
        #expect(Drawer.offset(open: false, translation: 120, width: 300) == 120)
        #expect(Drawer.offset(open: true, translation: -100, width: 300) == 200)
        // It never overshoots either side.
        #expect(Drawer.offset(open: false, translation: -40, width: 300) == 0)
        #expect(Drawer.offset(open: true, translation: 80, width: 300) == 300)
    }
}
