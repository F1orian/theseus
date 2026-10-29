import DesignSystem
public import SwiftUI

/// The header button that opens the navigation drawer. Works inside any `DrawerContainer` content.
public struct DrawerButton: View {
    @Environment(\.drawer) private var drawer

    public init() {}

    public var body: some View {
        Button {
            drawer.open()
        } label: {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityLabel("Open sidebar")
        }
        .accessibilityIdentifier("drawer.open")
    }
}

/// The header new-chat button (CHATS-10), e.g. in a Chat's header.
public struct NewChatButton: View {
    @Environment(\.libraryNavigate) private var navigate
    private let projectID: String?

    public init(projectID: String? = nil) {
        self.projectID = projectID
    }

    public var body: some View {
        Button {
            navigate(.newChat(projectID: projectID))
        } label: {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityLabel("New chat")
        }
        .accessibilityIdentifier("chat.newChat")
    }
}

/// The floating primary pill ("+ New chat"): verdigris, the screen's one accent (brand.md §1).
public struct NewChatPill: View {
    @Environment(\.libraryNavigate) private var navigate
    private let projectID: String?
    private let identifier: String

    public init(projectID: String? = nil, identifier: String = "newChat.pill") {
        self.projectID = projectID
        self.identifier = identifier
    }

    public var body: some View {
        Button {
            navigate(.newChat(projectID: projectID))
        } label: {
            Label("New chat", systemImage: "plus")
                .font(Typography.headline)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 48)
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityIdentifier(identifier)
    }
}

/// The verdigris capsule used for floating primary actions (`accent` / `onAccent`).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.onAccent.color)
            .background(Palette.accent.color, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Library copy that depends on state, kept out of the views so it can be tested.
enum LibraryCopy {
    /// The hint under "Nothing on these shelves." for a search without results.
    static func noResults(for query: String, localOnly: Bool) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = "No chats match \u{201C}\(query)\u{201D}."
        return localOnly ? "\(match) Only chat titles on this device were searched." : match
    }
}

/// A placeholder destination for Feature areas that haven't landed yet (Projects, Artifacts…).
public struct ComingSoonDestination: View {
    private let title: String
    private let symbol: String
    private let message: String

    public init(title: String, symbol: String, message: String) {
        self.title = title
        self.symbol = symbol
        self.message = message
    }

    public var body: some View {
        NavigationStack {
            MouseEmptyState(pose: .sit, title: Text(title), message: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .themedBackground()
                .navigationTitle(title)
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .navigation) { DrawerButton() }
                }
        }
    }
}

extension View {
    /// A small centred navigation title (iOS); a no-op elsewhere.
    public func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// The bottom of an infinitely scrolling Chat list (#146): a spinner that asks for the next page
/// whenever it is on screen. It asks again after each page (`trigger` changes), so a page that
/// doesn't push it off screen, or a request dropped during a refresh, can't stall the list.
struct PaginationSentinel<Trigger: Hashable>: View {
    let trigger: Trigger
    let identifier: String
    let loadMore: @MainActor () async -> Void

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 44)
            .task(id: trigger) { await loadMore() }
            .accessibilityLabel("Loading more chats")
            .accessibilityIdentifier(identifier)
    }
}
