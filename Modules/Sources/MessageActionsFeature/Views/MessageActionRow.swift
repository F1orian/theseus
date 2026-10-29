import ChatDomain
public import ChatFeature
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The row of small icon buttons under an assistant Response (MSG-01): Copy, Share, Read aloud,
/// thumbs up / down and Retry, each shown only when its Capability allows (ADR 0006), plus the
/// Branch pager on the right when the Response has siblings (MSG-04).
struct MessageActionRow: View {
    let message: Message
    let conversation: ConversationModel
    let actions: MessageActions
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = conversation.response(for: message)
        let position = conversation.branchPosition(of: message.id)
        if conversation.streamingMessageID != message.id, state.isFinished {
            let showsActions = state.phase != .failed && !state.text.isEmpty
            if showsActions || position != nil {
                // #147: the pager never wraps or squeezes. When the icons and the pager don't fit on
                // one line (six actions on a narrow phone, accessibility text sizes), the pager
                // moves to its own line under the icons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        if showsActions {
                            buttons(text: state.text, overflow: position == nil)
                        }
                        Spacer(minLength: Spacing.xs)
                        pager(position)
                    }
                    VStack(alignment: .trailing, spacing: 0) {
                        if showsActions {
                            HStack(spacing: 0) {
                                buttons(text: state.text, overflow: position == nil)
                                Spacer(minLength: 0)
                            }
                        }
                        pager(position)
                    }
                }
                // Align the first icon's glyph and the pager's last arrow with the Response text.
                .padding(.leading, -ActionIcon.inset)
                .padding(.trailing, position == nil ? 0 : -BranchPager.arrowInset)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("message.actions")
                // MSG-01: the row arrives with the finished Response (not on a loaded Chat).
                .appearsWithFade()
                .motionSafeTransition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func pager(_ position: MessageTree.BranchPosition?) -> some View {
        if let position {
            BranchPager(position: position, isEnabled: conversation.canChangeThread) { offset in
                Task { await conversation.showBranch(of: message.id, offset: offset) }
            }
        }
    }

    /// - Parameter overflow: Show the `•••` overflow (Select text). Off when the Branch pager
    ///   shares the row: seven icons and the pager don't fit an iPhone's width (#147); Select text
    ///   is then in Copy's long-press menu, which it always is.
    @ViewBuilder
    private func buttons(text: String, overflow: Bool) -> some View {
        let capabilities = conversation.capabilities
        let copied = actions.copiedMessageID == message.id
        ActionIcon(symbol: copied ? "checkmark" : "square.on.square", label: copied ? "Copied" : "Copy", id: "message.copy") {
            actions.copy(text, messageID: message.id)
        }
        // #175: long-press Copy for Select text.
        .contextMenu {
            Button("Copy", systemImage: "square.on.square") { actions.copy(text, messageID: message.id) }
            Button("Select text", systemImage: "selection.pin.in.out") { actions.selectText(message, text: text) }
        }
        .contentTransition(.symbolEffect(.replace))
        .motionSafeAnimation(Motion.bouncy, value: copied)
        .hapticFeedback(.success, trigger: copied)

        if let chatID = conversation.chatID, capabilities.contains(.publicChatLink) {
            ActionIcon(symbol: "square.and.arrow.up", label: "Share", id: "message.share") {
                actions.share(chatID: chatID, title: conversation.title)
            }
        }

        if capabilities.contains(.readAloud) {
            let speaking = actions.readAloud.isSpeaking(message.id)
            ActionIcon(symbol: speaking ? "pause" : "play", label: speaking ? "Stop reading" : "Read aloud", id: "message.readAloud") {
                actions.toggleReadAloud(message, text: text)
            }
            .contentTransition(.symbolEffect(.replace))
            .motionSafeAnimation(Motion.snappy, value: speaking)
        }

        if capabilities.contains(.rateResponse), conversation.chatID != nil {
            let rating = message.annotation?.rating
            ActionIcon(symbol: rating == .good ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Good response", id: "message.thumbsUp") {
                actions.rate(message, .good, in: conversation)
            }
            // The thumb fills with a little bounce (Visual language: Motion & haptics cues).
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: rating == .good)
            .accessibilityAddTraits(rating == .good ? .isSelected : [])
            ActionIcon(symbol: rating == .bad ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Bad response", id: "message.thumbsDown") {
                actions.rate(message, .bad, in: conversation)
            }
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: rating == .bad)
            .accessibilityAddTraits(rating == .bad ? .isSelected : [])
            // Its sheet also reports the Response (ADR 0172).
            .accessibilityHint("Rate it, or report it as harmful or offensive")
        } else {
            // No thumbs here (Incognito, rating turned off): Report still reaches a person (ADR 0172).
            ActionIcon(symbol: "flag", label: "Report response", id: "message.report") {
                Task {
                    if let url = await actions.report(message, text: text, in: conversation) { openURL(url) }
                }
            }
        }

        if capabilities.contains(.regenerateResponse) {
            ActionIcon(symbol: "arrow.clockwise", label: "Retry", id: "message.retry") {
                Task { await conversation.regenerate(message.id) }
            }
            .disabled(!conversation.canChangeThread)
        }

        // #175: the overflow, with Select text (the whole Response as one selectable text).
        if overflow {
            Menu {
                Button("Select text", systemImage: "selection.pin.in.out") {
                    actions.selectText(message, text: text)
                }
                .accessibilityIdentifier("message.selectText")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(width: 18 + ActionIcon.inset * 2, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerHighlight()
            .accessibilityLabel("More")
            .accessibilityIdentifier("message.more")
        }
    }
}

/// One small monochrome icon button in the action row.
struct ActionIcon: View {
    /// Padding around the 18 pt glyph that makes a 44 pt hit target (PLAT-06).
    static let inset: CGFloat = 13

    let symbol: String
    let label: String
    let id: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.textSecondary.color.opacity(isEnabled ? 1 : 0.4))
                .frame(width: 18 + Self.inset * 2, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// "‹ 2 / 3 ›": switches between sibling Branches of a Message (MSG-04).
struct BranchPager: View {
    /// An arrow's hit target is 36 × 44 pt, so six 44 pt action icons and the pager share one row
    /// on a 6.1" iPhone (#147); this is the padding beside its 13 pt glyph.
    static let arrowWidth: CGFloat = 36
    static let arrowInset: CGFloat = 12

    let position: MessageTree.BranchPosition
    let isEnabled: Bool
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", label: "Previous branch", id: "branch.previous", offset: -1, enabled: position.hasPrevious)
            Text("\(position.index + 1) / \(position.count)")
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary.color)
                // #147: "1 / 2" stays on one line at every size; the row makes room instead.
                .lineLimit(1)
                .fixedSize()
                // MSG-04: the number rolls to the new Branch.
                .contentTransition(.numericText(value: Double(position.index)))
                .motionSafeAnimation(Motion.snappy, value: position.index)
                .accessibilityIdentifier("branch.position")
            arrow("chevron.right", label: "Next branch", id: "branch.next", offset: 1, enabled: position.hasNext)
        }
        .fixedSize()
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch \(position.index + 1) of \(position.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if position.hasNext, isEnabled { select(1) }
            case .decrement: if position.hasPrevious, isEnabled { select(-1) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("branch.pager")
    }

    private func arrow(_ symbol: String, label: String, id: String, offset: Int, enabled: Bool) -> some View {
        Button { select(offset) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary.color.opacity(enabled && isEnabled ? 1 : 0.3))
                .frame(width: Self.arrowWidth, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !isEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Under a user Message: its Branch pager, when it has been edited (MSG-04/05).
struct UserMessageAccessory: View {
    let message: Message
    let conversation: ConversationModel

    var body: some View {
        if let position = conversation.branchPosition(of: message.id) {
            BranchPager(position: position, isEnabled: conversation.canChangeThread) { offset in
                Task { await conversation.showBranch(of: message.id, offset: offset) }
            }
            // The last arrow's glyph lines up with the bubble's edge.
            .padding(.trailing, -BranchPager.arrowInset)
        }
    }
}

/// "Edit" (MSG-05) and "Select text" (#175) in a user Message's long-press menu.
struct EditMenuItem: View {
    let message: Message
    let conversation: ConversationModel
    let actions: MessageActions

    var body: some View {
        Button("Select text", systemImage: "selection.pin.in.out") {
            actions.selectText(message, text: message.content)
        }
        .accessibilityIdentifier("message.selectText")
        if conversation.capabilities.contains(.editMessage), conversation.canChangeThread {
            Button("Edit", systemImage: "pencil") {
                actions.edit(message, in: conversation)
            }
        }
    }
}

extension MessageActions {
    /// The transcript hooks for `\.messageAccessories` (ChatFeature).
    public var accessories: MessageAccessories {
        MessageAccessories(
            response: { [self] conversation, message in
                AnyView(MessageActionRow(message: message, conversation: conversation, actions: self))
            },
            userMessage: { conversation, message in
                AnyView(UserMessageAccessory(message: message, conversation: conversation))
            },
            userMessageMenu: { [self] conversation, message in
                AnyView(EditMenuItem(message: message, conversation: conversation, actions: self))
            }
        )
    }
}
