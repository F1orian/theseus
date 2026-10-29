import ArtCollection
import ChatDomain
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// Which Chats the Chats list shows (CHATS-04).
public enum ChatsFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case starred

    var title: String {
        switch self {
        case .all: "All chats"
        case .starred: "Starred"
        }
    }

    var symbol: String {
        switch self {
        case .all: "bubble.left.and.bubble.right"
        case .starred: "star"
        }
    }
}

/// The full-screen Chats list (CHATS-02): rows with title, relative time and a chevron, the
/// All / Starred filter (CHATS-04), bottom search (CHATS-03), a floating "New chat" pill
/// (CHATS-10) and a long-press menu per row (CHATS-09).
public struct ChatsListView: View {
    private let library: ChatLibrary

    @State private var filter: ChatsFilter = .all
    @State private var search: ChatSearch
    @State private var isSearching = false
    @State private var prompts = ChatActionPrompts()
    @Environment(\.libraryNavigate) private var navigate
    private let startsSearching: Bool

    /// - Parameter startsSearching: Activate the search field (⌘K, PLAT-05).
    public init(library: ChatLibrary, startsSearching: Bool = false) {
        self.library = library
        self.startsSearching = startsSearching
        _search = State(initialValue: ChatSearch(library: library))
    }

    public var body: some View {
        NavigationStack {
            content
                .themedBackground()
                .navigationTitle("Chats")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .navigation) { DrawerButton() }
                    ToolbarItem(placement: .primaryAction) { filterMenu }
                }
                .searchable(text: $search.query, isPresented: $isSearching, prompt: "Search")
                .onChange(of: startsSearching, initial: true) { _, starts in
                    if starts { isSearching = true }
                }
                .task(id: search.query) { await search.run() }
                .overlay(alignment: .bottomTrailing) {
                    if !isSearching {
                        NewChatPill(identifier: "chats.newChat")
                            .padding(.trailing, Spacing.l)
                            .padding(.bottom, Spacing.l)
                            .motionSafeTransition(.pop)
                    }
                }
                .motionSafeAnimation(Motion.snappy, value: isSearching)
                .refreshable { await library.refresh() }
                .modifier(ChatActionAlerts(library: library, prompts: prompts))
        }
        // A container element, so the identifier doesn't replace its children's (it would in the
        // iPad sidebar's detail column, PLAT-05).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chats.screen")
    }

    // MARK: Content

    private var rows: [ChatSummary] {
        let source = search.isActive ? search.results : library.chats
        return filter == .starred ? source.filter(\.isStarred) : source
    }

    /// Changes after every loaded page, refresh and search, so the sentinel asks again.
    private var paginationTrigger: [String] {
        let source = search.isActive ? search.results : library.chats
        return [search.query, String(source.count), source.last?.id ?? "", String(describing: library.state)]
    }

    @ViewBuilder
    private var content: some View {
        let rows = rows
        Group { list(rows) }
            // Loading → rows, rows → "No matching chats": cross-fade.
            .motionSafeAnimation(Motion.fade, value: rows.isEmpty)
    }

    @ViewBuilder
    private func list(_ rows: [ChatSummary]) -> some View {
        if rows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(rows) { chat in
                    ChatRow(chat: chat, query: search.isActive ? search.query : nil)
                        .contentShape(.rect)
                        .pointerHighlight()
                        .onTapGesture { navigate(.chat(id: chat.id)) }
                        .accessibilityAddTraits(.isButton)
                        .contextMenu { ChatContextMenu(chat: chat, library: library, prompts: prompts) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                // #146: page through every Chat (and every Server search match) on scroll.
                if search.isActive ? search.hasMore : (library.hasMore && filter == .all) {
                    PaginationSentinel(trigger: paginationTrigger, identifier: "chats.loadingMore") {
                        if search.isActive { await search.loadMore() } else { await library.loadMore() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Leave room above the floating pill for the last row.
            .contentMargins(.bottom, isSearching ? 0 : 72, for: .scrollContent)
            .accessibilityIdentifier("chats.list")
            // CHATS-02…05: inserts, deletes, renames, star moves and filter or search results
            // animate row by row instead of reloading the list.
            .motionSafeAnimation(Motion.smooth, value: rows.map(\.id))
            .motionSafeAnimation(Motion.smooth, value: filter)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.isActive {
            if search.isSearchingServer {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // brand.md §4: Yi Taek-gyun's shelves and the sleeping mouse.
                ArtworkEmptyState(
                    .libraryEmpty,
                    title: Text("Nothing on these shelves."),
                    message: Text(ui: LibraryCopy.noResults(for: search.query, localOnly: search.isLocalOnly))
                )
                .accessibilityIdentifier("chats.empty.search")
            }
        } else if library.chats.isEmpty, library.state == .loading || library.state == .idle {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filter == .starred {
            MouseEmptyState(
                pose: .sleep,
                title: Text("No starred chats"),
                message: Text("Star a chat to keep it at the top of the sidebar.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ArtworkEmptyState(
                .libraryEmpty,
                title: Text("The library is quiet."),
                message: Text("Your conversations will be shelved here.")
            )
            .accessibilityIdentifier("chats.empty")
        }
    }

    // MARK: Filter (CHATS-04)

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(ChatsFilter.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if filter == .starred {
                Image(systemName: "star.fill")
                    .foregroundStyle(Palette.onAccent.color)
                    .padding(Spacing.s)
                    .background(Palette.accent.color, in: .circle)
                    .accessibilityLabel("Filter: Starred")
            } else {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(Palette.textPrimary.color)
                    .accessibilityLabel("Filter: All chats")
            }
        }
        .accessibilityIdentifier("chats.filter")
    }
}

/// One Chats list row: the title (matches bold while searching), a relative time or a search
/// snippet, and a chevron.
struct ChatRow: View {
    let chat: ChatSummary
    let query: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                title
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                    // PLAT-06: long titles wrap at the accessibility sizes instead of truncating.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if let query, let snippet = chat.snippet, !snippet.isEmpty {
                    Text(SearchHighlighter.highlight(snippet, query: query))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 2)
                } else {
                    Text(chat.updatedAt, format: .relative(presentation: .named, unitsStyle: .wide))
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
            Spacer(minLength: Spacing.s)
            if chat.isStarred {
                Image(systemName: "star.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
                    .accessibilityLabel("Starred")
                    // CHATS-05: the star lands with a bounce.
                    .transition(.symbolEffect(.appear))
            }
            Image(systemName: "chevron.right")
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary.color)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Spacing.xs)
        .motionSafeAnimation(Motion.bouncy, value: chat.isStarred)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.row.\(chat.id)")
    }

    private var title: Text {
        if let query {
            Text(SearchHighlighter.highlight(chat.title, query: query))
        } else {
            Text(chat.title)
        }
    }
}
