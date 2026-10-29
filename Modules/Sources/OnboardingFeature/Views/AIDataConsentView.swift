import DesignSystem
public import SwiftUI

/// "Before you chat" (App Review 5.1.2(i), ADR 0171): once per Account on this device, after sign-in
/// and before anything is sent, says where messages go (this Server, then the AI providers its admin
/// connected) and asks for explicit agreement. Declining signs out; nothing has been sent.
public struct AIDataConsentView: View {
    let host: String
    let onAgree: () async -> Void
    let onSignOut: () async -> Void
    @State private var isBusy = false

    public init(host: String, onAgree: @escaping () async -> Void, onSignOut: @escaping () async -> Void) {
        self.host = host
        self.onAgree = onAgree
        self.onSignOut = onSignOut
    }

    public var body: some View {
        WelcomeScaffold(headline: "Before you chat", showsIllustration: false) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                row(
                    "server.rack",
                    title: "Your messages go to \(host)",
                    text: "What you send in Theseus goes to this Open WebUI server: messages, files, photos, "
                        + "voice transcripts, memories and, if you allow it, your approximate location."
                )
                row(
                    "cpu",
                    title: "And on to its AI providers",
                    text: "The server passes them to the AI models and tools its admin connected, such as "
                        + "OpenAI, Anthropic, Google or web search. Their terms and privacy policies apply."
                )
                row(
                    "hand.raised",
                    title: "Theseus keeps nothing",
                    text: "The developer of Theseus runs no servers and receives none of your data."
                )
            }
            .accessibilityIdentifier("consent.disclosure")

            Link("Privacy policy", destination: PublicLinks.privacyPolicy)
                .font(Typography.callout)
                .accessibilityIdentifier("consent.policy")

            Button {
                run(onAgree)
            } label: {
                if isBusy { ProgressView().tint(Palette.onAccent.color) } else { Text("Agree and continue") }
            }
            .buttonStyle(.accentPill)
            .accessibilityIdentifier("consent.agree")

            Button("Sign out") { run(onSignOut) }
                .font(Typography.callout)
                .accessibilityIdentifier("consent.signOut")
        } footer: {
            Text("You can see who runs this server in Settings › Data & privacy.")
        }
        .disabled(isBusy)
        .accessibilityIdentifier("consent.screen")
    }

    private func row(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Image(systemName: symbol)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Text(text)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func run(_ action: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

#Preview("AI data consent") {
    AIDataConsentView(host: "chat.example.com", onAgree: {}, onSignOut: {})
}
