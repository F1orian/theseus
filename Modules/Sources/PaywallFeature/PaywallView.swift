import ArtCollection
import DesignSystem
public import Entitlements
public import SwiftUI

/// The Theseus Pro paywall (ADR 0173). The patterns (#182): a
/// contextual headline when a gate opened it, a checklist of what Pro adds ("Everything in Free,
/// plus"), what stays free, a plain promise (no ads, no tracking, no subscription, no account),
/// one accent button with the App Store price, Restore purchase and the terms. No countdowns,
/// scarcity or fake discounts.
///
/// Install it once at the app's root, then gates present it with `.paywall(_:)`:
///
/// ```swift
/// .environment(\.paywallContent, PaywallContent { request in AnyView(PaywallView(store: pro, request: request)) })
/// ```
public struct PaywallView: View {
    @State private var model: PaywallModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Set where the gates live (the signed-in shell); `.unknown` elsewhere.
    @Environment(\.serverSupport) private var serverSupport

    public init(store: ProStore, request: PaywallRequest) {
        _model = State(initialValue: PaywallModel(store: store, request: request))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .offer: offer
                case .unlocked: ThankYou { dismiss() }
                }
            }
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("paywall.close")
                }
            }
        }
        .onChange(of: serverSupport, initial: true) { model.serverSupport = serverSupport }
        .task { await model.appear() }
        .onChange(of: model.store.isPro) { model.entitlementChanged() }
        .motionSafeAnimation(Motion.smooth, value: model.phase)
        .hapticCue(trigger: model.phase) { _, new in new == .unlocked ? .responseDone : nil }
        .accessibilityIdentifier("paywall")
    }

    private var offer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PaywallHero()
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(model.headline)
                        .font(model.request.feature == nil ? Typography.display : Typography.title)
                        .foregroundStyle(Palette.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("paywall.headline")
                    Text(model.subheadline)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Checklist(features: model.checklist, highlighted: model.request.feature, detail: model.detail(for:))
                Text(FreeTier.summary)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.freeTier")
                PromiseCard()
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { purchaseBar }
    }

    private var purchaseBar: some View {
        VStack(spacing: Spacing.s) {
            if let message = model.message {
                Text(message)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.destructive.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.message")
            }
            Button {
                Task { await model.purchase() }
            } label: {
                if model.store.isBusy {
                    ProgressView().tint(Palette.onAccent.color)
                } else {
                    Text(model.buttonTitle)
                }
            }
            .buttonStyle(.accentPill)
            .disabled(!model.canPurchase)
            .accessibilityIdentifier("paywall.purchase")
            Text(model.footnote)
                .plaqueStyle()
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("paywall.footnote")
            HStack(spacing: Spacing.l) {
                Button("Restore purchase") { Task { await model.restore() } }
                    .disabled(model.store.isBusy)
                    .accessibilityIdentifier("paywall.restore")
                if let terms = ProPromise.termsURL {
                    Button("Terms of Use") { openURL(terms) }
                }
            }
            .font(Typography.callout)
            .tint(Palette.textSecondary.color)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Palette.background.color)
        .overlay(alignment: .top) { Divider().overlay(Palette.separator.color) }
    }
}

/// The treat in its frame, with Theseus peeking over the top edge (brand.md §3: the mouse may
/// peek over frames, never inside a painting), and its plaque.
struct PaywallHero: View {
    static let frameHeight: CGFloat = 150
    static let mat: CGFloat = 8
    static let mouseScale = 3

    var body: some View {
        let mouse = PixelMouse.size(of: .peek, scale: Self.mouseScale)
        let overlap = FramedArtwork.ruleWidth + Self.mat
        VStack(alignment: .leading, spacing: Spacing.s) {
            FramedArtwork(.pro, height: Self.frameHeight, mat: Self.mat)
                .padding(.top, mouse.height - overlap)
                .overlay(alignment: .top) {
                    PixelMouse(pose: .peek, scale: Self.mouseScale)
                        .mouseBackdrop()
                }
            Plaque(.pro, style: .short)
        }
        .padding(.top, Spacing.s)
    }
}

/// "Everything in Free, plus": one row per Pro feature; the one that opened the paywall leads,
/// on the soft accent.
struct Checklist: View {
    let features: [ProFeature]
    let highlighted: ProFeature?
    let detail: (ProFeature) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Everything in Free, plus")
                .plaqueStyle()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(features) { feature in
                    FeatureRow(feature: feature, detail: detail(feature), isHighlighted: feature == highlighted)
                    if feature != features.last {
                        Divider().overlay(Palette.separator.color).padding(.leading, 44)
                    }
                }
            }
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
        }
    }
}

private struct FeatureRow: View {
    let feature: ProFeature
    let detail: String
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: feature.systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.accent.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ui: feature.title)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(ui: detail)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.m)
        .background(isHighlighted ? Palette.accentSoft.color : .clear, in: .rect(cornerRadius: Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.feature.\(feature.rawValue)")
    }
}

/// No ads, no tracking, no subscription, no account (and, once the repo is public, the code).
struct PromiseCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Our promise")
                .plaqueStyle()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(ProPromise.items) { item in
                    PromiseRow(item: item)
                }
                if let url = ProPromise.sourceCodeURL {
                    Button { openURL(url) } label: { PromiseRow(item: ProPromise.sourceCodeItem) }
                        .buttonStyle(.plain)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        }
        .accessibilityIdentifier("paywall.promise")
    }
}

struct PromiseRow: View {
    let item: ProPromise.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: item.systemImage)
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ui: item.title)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(ui: item.detail)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// After the purchase: calm, no confetti (brand.md §6: warm and plain, never cute).
private struct ThankYou: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()
            PixelMouse(pose: .stand, scale: 4)
                .mouseBackdrop()
            Text("You're all set")
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("paywall.thanks")
            Text("Thank you for supporting Theseus. Pro is unlocked on all your devices, and for your family.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done", action: done)
                .buttonStyle(.accentPill)
                .accessibilityIdentifier("paywall.done")
        }
        .frame(maxWidth: 460)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Paywall") {
    PaywallView(store: .free(), request: PaywallRequest())
}

#Preview("Paywall: Voice mode") {
    PaywallView(store: .free(), request: PaywallRequest(.voiceMode))
}

#Preview("Paywall: a Server without code execution") {
    PaywallView(store: .free(), request: PaywallRequest())
        .environment(\.serverSupport, ServerSupport(codeExecution: .none, skills: true))
}
