import DesignSystem
import SwiftUI

/// "Waiting for approval": a centred card with the admin's message and a way to check again.
struct PendingApprovalView: View {
    let model: PendingApprovalModel

    var body: some View {
        WelcomeScaffold(headline: model.title, showsIllustration: false) {
            OnboardingCard {
                Image(systemName: "hourglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.accent.color)
                    .frame(width: 56, height: 56)
                    .background(Palette.recessedSurface.color, in: .circle)
                Text(model.message)
                    .font(Typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary.color)
                    .accessibilityIdentifier("pending.message")
                if let email = model.email, !email.isEmpty {
                    Text(email)
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(Typography.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("pending.status")
            }

            Button {
                Task { await model.checkAgain() }
            } label: {
                if model.isChecking { ProgressView() } else { Text(model.canCheckAgain ? "Check again" : "Sign in again") }
            }
            .buttonStyle(.pill)
            .accessibilityIdentifier("pending.checkAgain")

            Button("Use a different account") { model.signInWithAnotherAccount() }
                .font(Typography.callout)
                .accessibilityIdentifier("pending.signOut")
        } footer: {
            Text(model.server.url.host() ?? model.server.name)
        }
        .task { await model.load() }
    }
}

/// The centred, softly outlined card used by the verification and approval steps.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Spacing.l) {
            content
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.surface.color.opacity(0.6), in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
    }
}
