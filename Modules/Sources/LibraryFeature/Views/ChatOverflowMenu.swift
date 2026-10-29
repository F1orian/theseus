import ChatDomain
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The Chat header's `...` menu (CHATS-08): an anchored popover headed by the Chat title with
/// Share, Add to project, Star, Rename and a red Delete. Delete morphs the popover into a
/// confirmation; after deleting, the app returns to the new-chat home (CHATS-07).
///
/// Share and Add to project appear only when another Feature area supplies them through
/// `\.chatMenuExtras` and the Account has the matching Capability.
public struct ChatOverflowMenu: View {
    private let chatID: String
    private let library: ChatLibrary

    @Environment(\.libraryNavigate) private var navigate
    @Environment(\.chatMenuExtras) private var extras
    @State private var isPresented = false
    @State private var isConfirmingDelete = false
    @State private var pendingRename: ChatSummary?
    @State private var prompts = ChatActionPrompts()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// #149: the icon column grows with the text, so large glyphs keep their gap to the label.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    public init(chatID: String, library: ChatLibrary) {
        self.chatID = chatID
        self.library = library
    }

    public var body: some View {
        Button {
            isConfirmingDelete = false
            isPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Palette.textPrimary.color)
                .minimumHitTarget()  // PLAT-06
        }
        .accessibilityLabel("Chat options")
        .accessibilityIdentifier("chat.menu")
        .disabled(library.chat(id: chatID) == nil)
        .popover(isPresented: $isPresented) {
            Group {
                if let chat = library.chat(id: chatID) {
                    if isConfirmingDelete {
                        deleteConfirmation(chat)
                    } else {
                        menu(chat)
                    }
                }
            }
            // PLAT-06: wider at the accessibility sizes so rows wrap less.
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 340 : 260)
            .presentationCompactAdaptation(.popover)
            .animation(.snappy(duration: 0.25), value: isConfirmingDelete)
        }
        .onChange(of: isPresented) {
            // The Rename alert can only appear once the popover has finished dismissing.
            if !isPresented, let chat = pendingRename {
                pendingRename = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    prompts.rename(chat)
                }
            }
        }
        .modifier(ChatActionAlerts(library: library, prompts: prompts))
    }

    private func menu(_ chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chat.title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary.color)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xs)
            if let share = extras.share, library.capabilities.contains(.shareChat) {
                item("Share", symbol: "square.and.arrow.up", id: "chat.menu.share") {
                    isPresented = false
                    share(chat)
                }
            }
            if let files = extras.files, library.capabilities.contains(.sandbox) {
                item("Files", symbol: "doc.text.magnifyingglass", id: "chat.menu.files") {
                    isPresented = false
                    files(chat)
                }
            }
            if let addToProject = extras.addToProject, library.capabilities.contains(.projects) {
                item("Add to project", symbol: "folder.badge.plus", id: "chat.menu.addToProject") {
                    isPresented = false
                    addToProject(chat)
                }
            }
            item(chat.isStarred ? "Unstar" : "Star", symbol: chat.isStarred ? "star.slash" : "star", id: "chat.menu.star") {
                isPresented = false
                Task { await library.toggleStar(chat.id) }
            }
            item("Rename", symbol: "pencil", id: "chat.menu.rename") {
                pendingRename = chat
                isPresented = false
            }
            if library.canDelete {
                item("Delete", symbol: "trash", id: "chat.menu.delete", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        }
        .padding(.bottom, Spacing.s)
    }

    private func deleteConfirmation(_ chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Are you sure you want to delete “\(chat.title)”?")
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                isPresented = false
                Task {
                    if await library.delete(chat.id) { navigate(.newChat()) }
                }
            } label: {
                Text("Delete")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.destructive.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Palette.recessedSurface.color, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.menu.deleteConfirm")
        }
        .padding(Spacing.l)
    }

    private func item(
        _ title: String,
        symbol: String,
        id: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    // At least the column's width, wider for a wide glyph (folder.badge.plus).
                    .frame(minWidth: iconWidth)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Typography.body)
            .foregroundStyle(role == .destructive ? Palette.destructive.color : Palette.textPrimary.color)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
