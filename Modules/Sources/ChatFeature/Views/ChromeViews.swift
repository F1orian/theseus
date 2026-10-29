import ArtCollection
import DesignSystem
public import SwiftUI

/// Navigation hooks the host app provides to Chat screens. The Chats library (drawer, router)
/// sets these; without them the header shows a back button and new-chat is hidden.
public struct ChatNavigation {
    /// Opens the navigation drawer (CHATS-01). `nil`: show a back button instead.
    public var openDrawer: (@MainActor () -> Void)?
    /// Starts a new Chat (CHATS-10).
    public var startNewChat: (@MainActor () -> Void)?
    /// The Chat `...` menu for a saved Chat (CHATS-08). `nil`: a minimal built-in menu.
    public var overflowMenu: (@MainActor (_ chatID: String) -> AnyView)?
    /// A new Chat got its Server id (after the first send), e.g. to update the app's route.
    public var chatCreated: (@MainActor (_ chatID: String) -> Void)?
    /// The app's current title for a Chat (e.g. after a rename elsewhere); `nil` keeps the
    /// Conversation's own.
    public var chatTitle: (@MainActor (_ chatID: String) -> String?)?
    /// Starts an Incognito chat from the home's ghost button (INCOG-01). `nil`: a placeholder.
    public var startIncognitoChat: (@MainActor () -> Void)?
    /// Leaves an Incognito chat (its X) for a new saved Chat. `nil`: the X is hidden, e.g. when the
    /// Server makes every Chat Incognito (INCOG-02).
    public var leaveIncognitoChat: (@MainActor () -> Void)?
    /// The VoiceOver label of the drawer button: "Hide sidebar" / "Show sidebar" where the
    /// drawer is a persistent sidebar (PLAT-05).
    public var openDrawerLabel = "Open sidebar"

    public init(
        openDrawer: (@MainActor () -> Void)? = nil,
        startNewChat: (@MainActor () -> Void)? = nil,
        overflowMenu: (@MainActor (_ chatID: String) -> AnyView)? = nil,
        chatCreated: (@MainActor (_ chatID: String) -> Void)? = nil,
        chatTitle: (@MainActor (_ chatID: String) -> String?)? = nil,
        startIncognitoChat: (@MainActor () -> Void)? = nil,
        leaveIncognitoChat: (@MainActor () -> Void)? = nil
    ) {
        self.openDrawer = openDrawer
        self.startNewChat = startNewChat
        self.overflowMenu = overflowMenu
        self.chatCreated = chatCreated
        self.chatTitle = chatTitle
        self.startIncognitoChat = startIncognitoChat
        self.leaveIncognitoChat = leaveIncognitoChat
    }
}

extension EnvironmentValues {
    @Entry public var chatNavigation = ChatNavigation()
}

/// A floating round header button (CHAT-10).
struct FloatingIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.textPrimary.color)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .pointerHighlight()
    }
}

/// Floating header: drawer/back on the left, the Project chip, new chat and the overflow menu on
/// the right, over a soft top fade (CHAT-10).
struct ConversationHeader: View {
    let chatID: String?
    let title: String
    let projectName: String?
    let canDelete: Bool
    /// The new-chat home (HOME-01): only the drawer and the incognito ghost.
    var isHome = false
    /// An Incognito chat (INCOG-01): "Incognito chat" in the middle and an X to leave.
    var isIncognito = false
    var canGoIncognito = false
    /// The soft top fade behind the buttons; off over the Incognito hero, so the art reaches the top.
    var showsBackdrop = true
    let onBack: () -> Void
    let onDelete: () -> Void
    var onIncognitoPlaceholder: () -> Void = {}
    @Environment(\.chatNavigation) private var navigation

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let openDrawer = navigation.openDrawer {
                FloatingIconButton(systemImage: "line.3.horizontal", label: navigation.openDrawerLabel) { openDrawer() }
                    .accessibilityIdentifier("drawer.open")
            } else {
                FloatingIconButton(systemImage: "chevron.left", label: "Back", action: onBack)
                    .accessibilityIdentifier("chat.back")
            }
            if isIncognito {
                incognitoControls
            } else if isHome {
                Spacer()
                if let projectName {
                    ProjectChip(name: projectName)
                    Spacer()
                }
                if canGoIncognito {
                    FloatingIconButton(systemImage: "theatermasks", label: "Incognito chat") {
                        if let start = navigation.startIncognitoChat { start() } else { onIncognitoPlaceholder() }
                    }
                    .accessibilityIdentifier("chat.incognito")
                }
            } else {
                chatControls
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.l)
        // PLAT-06: the floating header is fixed-size chrome, like a navigation bar.
        .chromeDynamicType()
        .background {
            if showsBackdrop { backdrop }
        }
    }

    private var backdrop: some View {
            LinearGradient(
                stops: [
                    .init(color: Palette.background.color, location: 0),
                    .init(color: Palette.background.color.opacity(0.85), location: 0.55),
                    .init(color: Palette.background.color.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var incognitoControls: some View {
        // #150: the same glass capsule as a saved Chat's title, so scrolled Messages pass behind it.
        Text("Incognito chat")
            .font(Typography.callout.weight(.medium))
            .foregroundStyle(Palette.textPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 36)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chat.incognito.title")
        if let leave = navigation.leaveIncognitoChat {
            FloatingIconButton(systemImage: "xmark", label: "Leave incognito chat") { leave() }
                .accessibilityIdentifier("chat.incognito.leave")
        } else if !isHome, let startNewChat = navigation.startNewChat {
            // Every Chat is Incognito (INCOG-02): a new one replaces this one.
            FloatingIconButton(systemImage: "plus.bubble", label: "New chat") { startNewChat() }
                .accessibilityIdentifier("chat.new")
        } else {
            // Keeps the title centred.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var chatControls: some View {
            if let projectName {
                ProjectChip(name: projectName)
            }
            // The Chat's (generated) title, small and centred (CHAT-11).
            let title = chatID.flatMap { navigation.chatTitle?($0) } ?? self.title
            Text(title)
                .font(Typography.callout.weight(.medium))
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
                .frame(maxWidth: .infinity)
                .opacity(title.isEmpty ? 0 : 1)
                // CHAT-11: the generated title fades in and morphs when it changes.
                .contentTransition(.opacity)
                .motionSafeAnimation(Motion.fade, value: title)
                .accessibilityIdentifier("chat.title")
            HStack(spacing: 0) {
                if let startNewChat = navigation.startNewChat {
                    Button { startNewChat() } label: {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .pointerHighlight()
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("chat.new")
                }
                if let chatID, let overflowMenu = navigation.overflowMenu {
                    overflowMenu(chatID)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .pointerHighlight()
                } else {
                    Menu {
                        if !title.isEmpty {
                            Section(title) {}
                        }
                        if canDelete {
                            Button("Delete chat", systemImage: "trash", role: .destructive, action: onDelete)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("chat.overflow")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary.color)
            .padding(.horizontal, Spacing.xs)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// The empty Incognito chat (INCOG-01, brand.md §4): Heade's *Point Judith* full-bleed at the
/// top, the mouse with its lantern on the scrim's edge, and what Incognito means. The Incognito
/// screen is always night (`ConversationScreen` sets the dark scheme), so the art and the dark
/// composer read as one scene. The work is credited by the plaque under the text (the floating
/// header covers where an over-art caption would go).
struct IncognitoNotice: View {
    static let heroHeight: CGFloat = 270
    /// How far the mouse rises into the hero's scrim.
    static let mouseOverlap: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkHero(.incognito, height: Self.heroHeight, showsCaption: false)
            VStack(alignment: .leading, spacing: Spacing.s) {
                PixelMouse(pose: .lantern, scale: 3)
                    .padding(.bottom, Spacing.xs)
                Text(ui: "You're in incognito.")
                    .font(Typography.display)
                    .foregroundStyle(Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ui: "This chat won't be saved to your history or used for memory.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Plaque(.incognito, style: .short)
                    .padding(.top, Spacing.m)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, -Self.mouseOverlap)
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("incognito.notice")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The Chat's Project (server: folder) in the header.
struct ProjectChip: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder")
            .font(Typography.callout)
            .lineLimit(1)
            .foregroundStyle(Palette.textPrimary.color)
            .padding(.horizontal, Spacing.m)
            .frame(height: 36)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("chat.project")
    }
}

/// The non-blocking connectivity banner (CHAT-13).
struct ConnectionBanner: View {
    let status: ConnectionStatus
    let host: String

    var body: some View {
        if let message {
            HStack(spacing: Spacing.s) {
                Image(systemName: icon)
                Text(message)
                    .font(Typography.caption)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if status == .reconnecting { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(Palette.textSecondary.color)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.connectionBanner")
            .motionSafeTransition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var message: String? {
        switch status {
        case .online: nil
        case .reconnecting: "Reconnecting to \(host)…"
        case .offline: "You're offline. Sending is paused until you're back online."
        case .serverUnreachable: "Can't reach \(host). Sending is paused while Theseus retries."
        case .unauthorized: "Your session can't stream responses. Sign out and in again."
        }
    }

    private var icon: String {
        switch status {
        case .offline: "wifi.slash"
        case .serverUnreachable: "exclamationmark.icloud"
        case .unauthorized: "lock"
        case .online, .reconnecting: "arrow.triangle.2.circlepath"
        }
    }
}

#Preview("Incognito chat") {
    ZStack(alignment: .top) {
        IncognitoNotice()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        ConversationHeader(
            chatID: nil, title: "", projectName: nil, canDelete: false,
            isHome: true, isIncognito: true, showsBackdrop: false, onBack: {}, onDelete: {}
        )
        .environment(\.chatNavigation, ChatNavigation(openDrawer: {}, leaveIncognitoChat: {}))
    }
    .themedBackground()
    .preferredColorScheme(.dark)
}

#Preview("New chat in a Project") {
    ConversationHeader(
        chatID: nil, title: "", projectName: "Meal plan", canDelete: false,
        isHome: true, canGoIncognito: false, onBack: {}, onDelete: {}
    )
    .environment(\.chatNavigation, ChatNavigation(openDrawer: {}))
    .frame(maxHeight: .infinity, alignment: .top)
    .themedBackground()
}

/// Behind the docked composer (#188), the header's backdrop mirrored: clear `fade` points above
/// the composer, `Palette.background` at 85 % at its top edge, solid at the screen's bottom (the
/// strip below the composer included), so Messages fade out as they scroll under it. With Reduce
/// Transparency it's a solid strip with no fade. It never takes touches.
struct ComposerBackdrop: View {
    /// How far above the composer the fade reaches.
    static let fade: CGFloat = 36
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let background = Palette.background.color
        VStack(spacing: 0) {
            if !reduceTransparency {
                LinearGradient(colors: [background.opacity(0), background.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
            }
            // Solid from halfway down the composer, so nothing shows in the strip below it.
            LinearGradient(
                stops: [
                    .init(color: reduceTransparency ? background : background.opacity(0.85), location: 0),
                    .init(color: background, location: 0.5),
                    .init(color: background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.top, reduceTransparency ? 0 : -Self.fade)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
