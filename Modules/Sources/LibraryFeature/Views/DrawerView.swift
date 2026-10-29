import ChatDomain
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The navigation drawer's content (CHATS-01): the Theseus lockup (mouse + wordmark), the Chats / Projects /
/// Artifacts rows, the Starred and Recents sections, and the Account avatar (Settings) plus the
/// "New chat" pill at the bottom. Starred and Recents rows have the Chats list's long-press menu
/// (CHATS-09, #171). Recents stop after about a screen with "See all", which opens the Chats list
/// (#172), and the header's search button turns the drawer into a full-screen search (#172).
public struct DrawerView: View {
    /// The drawer's top-level sections. The active one is highlighted.
    public enum Section: Hashable, Sendable {
        case chats
        case projects
        case artifacts
    }

    private let library: ChatLibrary
    private let accountName: String
    private let showsArtifacts: Bool
    private let showsHistory: Bool
    private let activeSection: Section?
    private let activeChatID: String?

    @State private var prompts = ChatActionPrompts()
    @State private var search: ChatSearch
    /// #172: the drawer is a full-screen search (the header's magnifying glass).
    @State private var isSearching = false
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.libraryNavigate) private var navigate
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The navigation rows' icon column grows with the text, so large glyphs don't run into
    /// their labels at the accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    /// The lockup grows with the text, up to a point (the mouse keeps whole-point pixels).
    @ScaledMetric(relativeTo: .largeTitle) private var lockupSize: CGFloat = 26

    /// - Parameters:
    ///   - showsArtifacts: Whether the Artifacts row is available (client-side; ART-04).
    ///   - showsHistory: Whether saved Chats show (the Chats row, Starred and Recents). Off when
    ///     the Server makes every Chat Incognito (INCOG-02).
    ///   - activeSection: The highlighted top-level row, if the current screen is one.
    ///   - activeChatID: The open Chat, highlighted in Starred / Recents.
    public init(
        library: ChatLibrary,
        accountName: String,
        showsArtifacts: Bool = true,
        showsHistory: Bool = true,
        activeSection: Section? = nil,
        activeChatID: String? = nil
    ) {
        self.library = library
        self.accountName = accountName
        self.showsArtifacts = showsArtifacts
        self.showsHistory = showsHistory
        self.activeSection = activeSection
        self.activeChatID = activeChatID
        _search = State(initialValue: ChatSearch(library: library))
    }

    public var body: some View {
        ZStack {
            if isSearching {
                searchScreen.transition(.opacity)
            } else {
                browseScreen.transition(.opacity)
            }
        }
        // The container gives the search the whole screen (the card slides away).
        .preference(key: DrawerExpandedPreferenceKey.self, value: isSearching)
        // CHATS-06 / CHATS-07 from a row's menu. Deleting the open Chat returns to the new-chat
        // home, as from its own menu.
        .modifier(ChatActionAlerts(library: library, prompts: prompts) { [activeChatID, navigate] id in
            if id == activeChatID { navigate(.newChat()) }
        })
    }

    private var browseScreen: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showsHistory {
                    navigationRow("Chats", symbol: "bubble.left.and.bubble.right", section: .chats, destination: .chatsList)
                }
                // Projects need the Server's folders feature and the Account's permission (ADR 0006).
                if library.capabilities.contains(.projects) {
                    navigationRow("Projects", symbol: "square.stack", section: .projects, destination: .projects)
                }
                if showsArtifacts {
                    navigationRow("Artifacts", symbol: "square.on.circle", section: .artifacts, destination: .artifacts)
                }

                if showsHistory, !library.starred.isEmpty {
                    sectionHeader("Starred")
                    ForEach(library.starred) { chat in chatRow(chat) }
                }
                // #172: about a screen of Recents, then "See all" (the Chats list pages through
                // every Chat, #146). The drawer doesn't page.
                let recents = DrawerRecents(library.recents, hasMore: library.hasMore)
                if showsHistory, !recents.shown.isEmpty {
                    sectionHeader("Recents")
                    ForEach(recents.shown) { chat in chatRow(chat) }
                }
                if showsHistory, recents.showsSeeAll {
                    seeAllRow
                }
            }
            .padding(.horizontal, Spacing.s)
            // Room for the floating footer.
            .padding(.bottom, 96)
            // A starred, renamed, new or deleted Chat moves into place (CHATS-01, ADR 0130).
            .motionSafeAnimation(Motion.smooth, value: library.starred.map(\.id))
            .motionSafeAnimation(Motion.smooth, value: library.recents.prefix(DrawerRecents.limit).map(\.id))
            .motionSafeAnimation(Motion.snappy, value: activeChatID)
        }
        .scrollIndicators(.hidden)
        // On the list only: an identifier on the overlaid stack would also land on the footer's
        // buttons, and VoiceOver and UI tests would see the avatar as one drawer-sized element.
        .accessibilityIdentifier("drawer")
        // The lockup and search stay at the top while the list scrolls under them.
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                .padding(.horizontal, Spacing.s)
                .background { DrawerHeaderBackdrop() }
        }
        .overlay(alignment: .bottom) { footer }
        .accessibilityElement(children: .contain)
    }

    /// The lockup, with the search button across from it when there's a history to search.
    private var header: some View {
        HStack(alignment: .center) {
            // The brand lockup (brand.md §3): the sitting mouse beside the New York wordmark.
            // The backdrop lifts the umber outline off the dark drawer.
            BrandLockup(size: min(lockupSize, 44))
                .mouseBackdrop()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.s)
            if showsHistory {
                Button(action: startSearching) {
                    Image(systemName: "magnifyingglass")
                        .font(Typography.headline)
                        .foregroundStyle(Palette.textPrimary.color)
                        .frame(width: 40, height: 40)
                        .background(Palette.surface.color, in: .circle)
                        .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search chats")
                .accessibilityIdentifier("drawer.search")
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
    }

    /// "See all ›" under the capped Recents: the full-screen Chats list (CHATS-02).
    private var seeAllRow: some View {
        Button {
            navigate(.chatsList)
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("See all")
                Image(systemName: "chevron.right")
                    .font(Typography.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(Typography.callout)
            .foregroundStyle(Palette.textSecondary.color)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .accessibilityLabel("See all chats")
        .accessibilityIdentifier("drawer.seeAll")
    }

    // MARK: Search (#172)

    private func startSearching() {
        withMotion(Motion.smooth) { isSearching = true }
    }

    private func stopSearching() {
        isSearchFieldFocused = false
        search.clear()
        withMotion(Motion.smooth) { isSearching = false }
    }

    /// The drawer search: a field at the top with a close button, the keyboard up, the
    /// recent Chats until something's typed, then the matches (titles in the mirror at once, the
    /// Server's title and message matches after a pause; CHATS-03). A match opens its Chat.
    private var searchScreen: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    searchResults
                }
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.xl)
                .motionSafeAnimation(Motion.smooth, value: search.results.map(\.id))
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("drawer.searchResults")
        }
        .task(id: search.query) { await search.run() }
        .accessibilityElement(children: .contain)
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityHidden(true)
                TextField("Search chats", text: $search.query)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("drawer.search.field")
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 44)
            .background(Palette.surface.color, in: .capsule)
            Button(action: stopSearching) {
                Image(systemName: "xmark")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .background(Palette.surface.color, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("drawer.search.close")
        }
        // The keyboard comes up with the search, from the drawer.
        .onAppear { Task { @MainActor in isSearchFieldFocused = true } }
    }

    @ViewBuilder
    private var searchResults: some View {
        if search.isActive {
            sectionHeader("Chats")
            if search.results.isEmpty {
                Text(search.isSearchingServer ? "Searching…" : "No matching chats")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .accessibilityIdentifier("drawer.search.empty")
            } else {
                ForEach(search.results) { chat in searchRow(chat) }
            }
        } else {
            sectionHeader("Recent chats")
            ForEach(library.chats.prefix(DrawerRecents.limit)) { chat in searchRow(chat) }
        }
    }

    private func searchRow(_ chat: ChatSummary) -> some View {
        Button {
            isSearchFieldFocused = false
            navigate(.chat(id: chat.id))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Image(systemName: "bubble.left")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(SearchHighlighter.highlight(chat.title, query: search.query))
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if search.isActive, let snippet = chat.snippet, !snippet.isEmpty {
                        Text(SearchHighlighter.highlight(snippet, query: search.query))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary.color)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 2)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
            .highlightedRow(activeChatID == chat.id)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .accessibilityIdentifier("drawer.search.result.\(chat.id)")
    }

    // MARK: Rows

    private func navigationRow(_ title: String, symbol: String, section: Section, destination: LibraryDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            Label {
                Text(title).font(Typography.body)
            } icon: {
                Image(systemName: symbol).frame(width: iconWidth)
            }
            .foregroundStyle(Palette.textPrimary.color)
            .highlightedRow(activeSection == section)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .accessibilityIdentifier("drawer.\(title.lowercased())")
        .accessibilityAddTraits(activeSection == section ? .isSelected : [])
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.callout)
            .foregroundStyle(Palette.textTertiary.color)
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func chatRow(_ chat: ChatSummary) -> some View {
        Button {
            navigate(.chat(id: chat.id))
        } label: {
            Text(chat.title)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                // PLAT-06: long titles wrap at the accessibility sizes instead of truncating.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Spacing.xs : 0)
                .contentTransition(.interpolate)
                .highlightedRow(activeChatID == chat.id)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        // #171: the Chats list's long-press menu; the row lifts with its rounded highlight.
        .roundedContextMenuPreview()
        .contextMenu { ChatContextMenu(chat: chat, library: library, prompts: prompts) }
        .motionSafeTransition(.opacity.combined(with: .offset(x: -12)))
        .accessibilityIdentifier("drawer.chat.\(chat.id)")
        .accessibilityAddTraits(activeChatID == chat.id ? .isSelected : [])
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                navigate(.settings)
            } label: {
                Text(Self.initials(of: accountName))
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 48, height: 48)
                    .background(Palette.surface.color, in: .circle)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings, \(accountName)")
            .accessibilityIdentifier("drawer.account")
            Spacer()
            NewChatPill(identifier: "drawer.newChat")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.s)
        .background {
            LinearGradient(
                colors: [Palette.recessedSurface.color.opacity(0), Palette.recessedSurface.color],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    /// Up to two initials from the Account name ("Ada Lovelace" → "AL"); "?" when empty.
    static func initials(of name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

private extension View {
    /// The long-press lift takes the row's rounded highlight shape (iOS; macOS has no preview).
    @ViewBuilder
    func roundedContextMenuPreview() -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, .rect(cornerRadius: Radius.medium, style: .continuous))
        #else
        self
        #endif
    }

    func highlightedRow(_ isActive: Bool) -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            // At rest the drawer's own colour: invisible, but a lifted row (#171) is a plate.
            .background(
                isActive ? Palette.accentSoft.color : Palette.recessedSurface.color,
                in: .rect(cornerRadius: Radius.medium, style: .continuous)
            )
            .contentShape(.rect)
    }
}

/// Behind the drawer's sticky header: the drawer's own colour, solid at the top (the status bar
/// included), 85 % halfway down, clear at the bottom, so the list fades out as it scrolls under the
/// lockup and the search button, the way Messages pass under the Chat's header. At rest it matches
/// the drawer, so nothing shows until the list moves. With Reduce Transparency it's solid.
private struct DrawerHeaderBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let surface = Palette.recessedSurface.color
        Group {
            if reduceTransparency {
                surface
            } else {
                LinearGradient(
                    stops: [
                        .init(color: surface, location: 0),
                        .init(color: surface.opacity(0.85), location: 0.55),
                        .init(color: surface.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
