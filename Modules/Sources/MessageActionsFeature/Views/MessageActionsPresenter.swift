import DesignSystem
public import SwiftUI

extension View {
    /// Presents the Message actions' sheets (Feedback, Share, Edit) and top toasts over this view.
    /// Apply it once around the Chat screens.
    public func messageActions(_ actions: MessageActions) -> some View {
        modifier(MessageActionsPresenter(actions: actions))
    }
}

private struct MessageActionsPresenter: ViewModifier {
    @Bindable var actions: MessageActions

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = actions.toast {
                    ActionToast(toast: toast) { actions.dismissToast() }
                        .padding(.horizontal, Spacing.l)
                        .padding(.top, Spacing.xs)
                        .motionSafeTransition(.toast)
                        .id(toast.id)
                }
            }
            // MSG-02: toasts drop in from the top and lift away.
            .motionSafeAnimation(Motion.toast, value: actions.toast)
            .sheet(item: $actions.sheet) { sheet in
                switch sheet {
                case .feedback(let draft):
                    FeedbackSheet(draft: draft, actions: actions)
                        .presentationDetents([.large])
                case .share(let sharing):
                    ShareChatSheet(sharing: sharing)
                        .presentationDetents([.height(430), .large])
                case .edit(let draft):
                    EditMessageSheet(draft: draft, actions: actions)
                        .presentationDetents([.large])
                case .selectText(let draft):
                    SelectTextSheet(draft: draft, actions: actions)
                        .presentationDetents([.large])
                }
            }
            .onChange(of: actions.readAloud.lastError) { _, error in
                if let error {
                    actions.showToast(error, systemImage: "speaker.slash")
                    actions.readAloud.clearError()
                }
            }
            .onDisappear { actions.readAloud.stop() }
    }
}

/// A top toast card: icon, text and an X (Visual language, MSG-02).
struct ActionToast: View {
    let toast: MessageActions.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Palette.textPrimary.color)
            Text(toast.text)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(2)
            Spacer(minLength: Spacing.s)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.toast")
    }
}
