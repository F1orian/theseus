import DesignSystem
import LibraryFeature
import SwiftUI

/// PLAT-05: the regular-width shell (iPad, Mac "Designed for iPad"). The drawer's content is a
/// persistent sidebar next to the screen, in portrait and landscape; the header's drawer button
/// (and `\.drawer`) hides and shows it instead of sliding a drawer in.
///
/// Motion (ADR 0130): whoever changes `isSidebarHidden` (the header button, a keyboard
/// shortcut, a swipe), the column slides with `Motion.drawer`; Reduce Motion switches it at once.
struct SidebarShell<Sidebar: View, Detail: View>: View {
    @Binding var isSidebarHidden: Bool
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail
    /// What the split view shows: follows `isSidebarHidden`, animated.
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: visibility) {
            sidebar
                .background(Palette.recessedSurface.color.ignoresSafeArea())
                .toolbar(removing: .sidebarToggle)
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            detail
                .environment(\.drawer, DrawerAction { open in
                    isSidebarHidden = open.map { !$0 } ?? !isSidebarHidden
                })
        }
        // Side by side in portrait too, rather than an overlay sidebar.
        .navigationSplitViewStyle(.balanced)
        .onChange(of: isSidebarHidden, initial: true) { _, hidden in
            let target: NavigationSplitViewVisibility = hidden ? .detailOnly : .all
            guard columns != target else { return }
            withAnimation(reduceMotion ? nil : Motion.drawer) { columns = target }
        }
    }

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            columns
        } set: { newValue in
            // The split view's own changes (a swipe) are already animated.
            columns = newValue
            isSidebarHidden = newValue == .detailOnly
        }
    }
}

#Preview("iPad sidebar") {
    @Previewable @State var hidden = false
    SidebarShell(isSidebarHidden: $hidden) {
        List(["Chats", "Projects", "Artifacts"], id: \.self) { Text($0) }
    } detail: {
        Text("Conversation").frame(maxWidth: .infinity, maxHeight: .infinity).themedBackground()
    }
}
