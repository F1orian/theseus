import ArtCollection
import DesignSystem
public import SwiftUI

/// The one-time welcome sheet (AUTH-08, brand.md §4): the welcome painting full-bleed at the top
/// (Cole in light, Heade in dark appearance) with the `stand`ing mouse on the scrim's edge, a
/// New York headline, one row per thing that works with this Server, and "Start chatting" in
/// verdigris. No upsell.
public struct WelcomeSheet: View {
    let summary: WelcomeSummary
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Flips once the sheet is up: the mouse rises and the rows arrive one after another.
    @State private var appeared = false

    public init(summary: WelcomeSummary, onDone: @escaping () -> Void) {
        self.summary = summary
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    hero
                    Text("Welcome to Theseus")
                        .font(Typography.display)
                        .foregroundStyle(Palette.textPrimary.color)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Spacing.xl)
                    Text("Here’s what works with \(summary.host).")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, -Spacing.m)
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                                Image(systemName: item.symbol)
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.textPrimary.color)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                Text(item.text)
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.textPrimary.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("welcome.item.\(item.id)")
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared || reduceMotion ? 0 : 12)
                            .animation(reduceMotion ? .easeOut(duration: Motion.Duration.short) : Motion.message.delay(0.15 + 0.06 * Double(index)), value: appeared)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                }
                .padding(.bottom, Spacing.xl)
            }
            Button {
                finish()
            } label: {
                Text("Start chatting")
            }
            .buttonStyle(.accentPill)
            .accessibilityIdentifier("welcome.start")
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .background(Palette.background.color)
        .mouseBackdrop()
        .overlay(alignment: .topLeading) {
            Button(action: finish) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .background(Palette.surface.color, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("welcome.close")
            .padding(Spacing.l)
        }
        .presentationDetents([.large])
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.sheet")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The close button sits top leading, so the over-art caption goes to the other corner.
            ArtworkHero(colorScheme == .dark ? .welcomeDark : .welcome, height: 230, captionAlignment: .trailing)
            PixelMouse(pose: .stand, scale: 3)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, -36)
                // AUTH-08: the mouse rises into place as the sheet comes up (ADR 0130); it never
                // turns or scales (brand.md §3).
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 12)
                .animation(reduceMotion ? .easeOut(duration: Motion.Duration.short) : Motion.message.delay(0.1), value: appeared)
        }
        .padding(.bottom, -Spacing.s)
    }

    private func finish() {
        onDone()
        dismiss()
    }
}

#Preview("Welcome") {
    Color.clear.sheet(isPresented: .constant(true)) {
        WelcomeSheet(
            summary: WelcomeSummary(
                host: "chat.example.com",
                capabilities: .init(enabled: [.voiceMode, .projects, .webSearch, .connectors, .memory]),
                savesChats: true,
                speechOnDevice: true,
                connectorNames: ["Weather", "GitHub"]
            ),
            onDone: {}
        )
    }
}
