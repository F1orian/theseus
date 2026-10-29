import ChatDomain
import DesignSystem
import SwiftUI

/// Suggested next prompts under the latest Response (#141): up to three tappable chips. Shown
/// only when the user turned follow-up suggestions on (`ui.autoFollowUps`).
struct FollowUpChips: View {
    let suggestions: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                Button {
                    onPick(suggestion)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.textTertiary.color)
                        Text(suggestion)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textPrimary.color)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
                    .contentShape(.rect(cornerRadius: Radius.medium))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sends this as your next message")
                .accessibilityIdentifier("followUp.\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested follow-ups")
        .accessibilityIdentifier("followUps")
    }
}

extension ConversationModel {
    /// Whether the latest Response shows follow-up chips (#141): the user asked for them, the
    /// Chat is saved (Incognito chats run no background tasks), and nothing is streaming.
    func followUps(for message: Message) -> [String] {
        guard services.composer.followUpsEnabled, !isIncognito, !isStreaming, pendingQuestion == nil,
              message.id == thread.last?.id, message.role == .assistant
        else { return [] }
        let state = response(for: message)
        guard state.phase == .completed else { return [] }
        return state.followUps.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Sends a suggestion as the next user Message.
    public func sendFollowUp(_ text: String) async {
        composer.text = text
        await send()
    }
}

#Preview("Follow-ups") {
    FollowUpChips(suggestions: [
        "What's the difference between a maze and a labyrinth?",
        "Tell me how Theseus used a thread to escape.",
        "Give me the same format for a cul-de-sac.",
    ]) { _ in }
    .padding()
    .themedBackground()
}
