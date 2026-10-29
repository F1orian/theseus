public import ChatDomain
import DesignSystem
import Observation
import OpenWebUIKit
public import SwiftUI

/// Presentation state for the Chat actions that need a second step: the Rename alert (CHATS-06)
/// and the Delete confirmation (CHATS-07).
@MainActor
@Observable
final class ChatActionPrompts {
    var renaming: ChatSummary?
    var renameDraft = ""
    var deleting: ChatSummary?

    func rename(_ chat: ChatSummary) {
        renameDraft = chat.title
        renaming = chat
    }

    func delete(_ chat: ChatSummary) {
        deleting = chat
    }
}

/// Attaches the Rename alert and the Delete confirmation for `prompts`.
struct ChatActionAlerts: ViewModifier {
    let library: ChatLibrary
    @Bindable var prompts: ChatActionPrompts
    /// Called after the Server confirmed a deletion.
    var onDeleted: @MainActor (String) -> Void = { _ in }

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Chat",
                isPresented: Binding(get: { prompts.renaming != nil }, set: { if !$0 { prompts.renaming = nil } }),
                presenting: prompts.renaming
            ) { chat in
                TextField("Chat title", text: $prompts.renameDraft)
                    .accessibilityIdentifier("rename.field")
                Button("Cancel", role: .cancel) {}
                Button("OK") {
                    let title = prompts.renameDraft
                    Task { await library.rename(chat.id, to: title) }
                }
                .accessibilityIdentifier("rename.ok")
            } message: { _ in
                Text("Enter a new name")
            }
            .alert(
                "Delete chat?",
                isPresented: Binding(get: { prompts.deleting != nil }, set: { if !$0 { prompts.deleting = nil } }),
                presenting: prompts.deleting
            ) { chat in
                Button("Delete", role: .destructive) {
                    Task {
                        if await library.delete(chat.id) { onDeleted(chat.id) }
                    }
                }
                .accessibilityIdentifier("delete.confirm")
                Button("Cancel", role: .cancel) {}
            } message: { chat in
                Text("Are you sure you want to delete “\(chat.title)”?")
            }
    }
}

/// An entry of a Chat row's long-press menu (CHATS-09), in the Chats list and the drawer (#171).
enum ChatRowAction: Hashable, Sendable {
    case star
    case unstar
    case rename
    case addToProject
    case delete

    /// The menu for `chat`, top to bottom: Star or Unstar, Rename, Add to project when another
    /// Feature area offers it (PROJ-06), and a red Delete when the Account may delete Chats.
    static func actions(for chat: ChatSummary, canDelete: Bool, canAddToProject: Bool) -> [ChatRowAction] {
        var actions: [ChatRowAction] = [chat.isStarred ? .unstar : .star, .rename]
        if canAddToProject { actions.append(.addToProject) }
        if canDelete { actions.append(.delete) }
        return actions
    }

    var title: String {
        switch self {
        case .star: "Star"
        case .unstar: "Unstar"
        case .rename: "Rename"
        case .addToProject: "Add to project"
        case .delete: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .star: "star"
        case .unstar: "star.slash"
        case .rename: "pencil"
        case .addToProject: "folder.badge.plus"
        case .delete: "trash"
        }
    }

    var isDestructive: Bool { self == .delete }
}

/// The long-press menu of a Chat row (CHATS-09): Star / Unstar, Rename, Add to project and a red
/// Delete. Rename and Delete go through `prompts` (the alert and the confirmation).
struct ChatContextMenu: View {
    let chat: ChatSummary
    let library: ChatLibrary
    let prompts: ChatActionPrompts
    @Environment(\.chatMenuExtras) private var extras

    var body: some View {
        // The library's current copy: the system can keep a row's menu from before it was starred.
        let chat = library.chat(id: chat.id) ?? chat
        let addToProject = library.capabilities.contains(.projects) ? extras.addToProject : nil
        ForEach(ChatRowAction.actions(for: chat, canDelete: library.canDelete, canAddToProject: addToProject != nil), id: \.self) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                perform(action, on: chat, addToProject: addToProject)
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
        }
    }

    private func perform(_ action: ChatRowAction, on chat: ChatSummary, addToProject: (@MainActor @Sendable (ChatSummary) -> Void)?) {
        switch action {
        case .star, .unstar: Task { await library.toggleStar(chat.id) }
        case .rename: prompts.rename(chat)
        case .addToProject: addToProject?(chat)
        case .delete: prompts.delete(chat)
        }
    }
}

/// A dismissible notice for a failed library action ("You appear to be offline.").
public struct LibraryNotice: View {
    private let library: ChatLibrary

    public init(library: ChatLibrary) {
        self.library = library
    }

    public var body: some View {
        if let message = library.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Palette.destructive.color)
                Text(message)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    library.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary.color)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, Spacing.l)
            .motionSafeTransition(.toast)
            .accessibilityIdentifier("library.notice")
            .task(id: message) {
                try? await Task.sleep(for: .seconds(5))
                if library.errorMessage == message { library.dismissError() }
            }
        }
    }
}
