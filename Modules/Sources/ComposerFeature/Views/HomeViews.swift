import ArtCollection
import DesignSystem
import Foundation
import OpenWebUIKit
public import SwiftUI

/// The new-chat home's centre (HOME-01, brand.md §4): the `sit`ting mouse above a New York
/// greeting that follows the time of day and welcomes the user back, then "Today in the
/// collection": a small framed work that changes daily, its plaque and "Ask about it ›", which
/// puts a question about the work in the composer (`onAskAboutArtwork`). Settings › "Show
/// today's artwork" (`\.showsTodayArtwork`) hides the card. Centred when it fits, it scrolls
/// when it doesn't (the keyboard up), so nothing clips; at accessibility text sizes the card
/// keeps its words and drops the painting, so the greeting and the plaque fit above the composer.
public struct HomeGreetingView: View {
    let services: ComposerServices
    let onAskAboutArtwork: ((String) -> Void)?
    @State private var previousVisit: Date?
    @State private var now = Date()
    @State private var recorded = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.showsTodayArtwork) private var showsTodayArtwork
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameter onAskAboutArtwork: Receives the question about today's work ("Tell me about
    ///   …"); `nil` shows the card without the action.
    public init(services: ComposerServices, onAskAboutArtwork: ((String) -> Void)? = nil) {
        self.services = services
        self.onAskAboutArtwork = onAskAboutArtwork
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.horizontal, Spacing.xl + 2)
                    .padding(.vertical, Spacing.l)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        // HOME-01: the mouse and greeting settle in when the home appears (ADR 0130).
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(Motion.message.delay(0.05)) { appeared = true }
            guard !recorded else { return }
            recorded = true
            now = Date()
            previousVisit = services.recordVisit(at: now)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            greeting
            if showsTodayArtwork {
                TodayCard(
                    artwork: TodayInTheCollection.artwork(for: now),
                    showsFrame: !dynamicTypeSize.isAccessibilitySize,
                    onAsk: onAskAboutArtwork
                )
                    .offset(y: appeared || reduceMotion ? 0 : 14)
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // The mouse never scales or tweens (brand.md §3): it fades in with the greeting.
            // It's the one part of the greeting that takes taps: petting it (#174).
            PettableMouse(.pose(.sit), scale: 3)
            Text(Greeting.text(name: services.greetingName, now: now, lastVisit: previousVisit))
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary.color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motionSafeAnimation(Motion.fade, value: services.greetingName)
                .offset(y: appeared || reduceMotion ? 0 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.greeting")
    }
}

/// "Today in the collection": the eyebrow, the framed work (unless `showsFrame` is off), its
/// plaque and "Ask about it ›". Only the link asks (it puts a question about the work in the
/// composer); the painting opens it full screen (`ArtworkViewer`, #178).
struct TodayCard: View {
    let artwork: Artwork
    var showsFrame = true
    let onAsk: ((String) -> Void)?
    @State private var viewing: Artwork?

    static let frameHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ui: "Today in the collection").plaqueStyle()
                .accessibilityAddTraits(.isHeader)
            if showsFrame {
                Button {
                    viewing = artwork
                } label: {
                    FramedArtwork(artwork, height: Self.frameHeight, mat: 5)
                        .contentShape(.rect)
                }
                .buttonStyle(TodayCardButtonStyle())
                .padding(.bottom, Spacing.xs)
                .accessibilityLabel(Text(ui: artwork.credit))
                .accessibilityHint(Text(ui: "Opens the work full screen"))
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("home.today.artwork")
            }
            Plaque(artwork, style: .short)
            if let onAsk {
                Button {
                    onAsk(TodayInTheCollection.prompt(for: artwork))
                } label: {
                    Text(ui: "Ask about it ›").plaqueStyle(color: Palette.accent)
                        .frame(minHeight: AccessibilityMetrics.minimumHitTarget, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(TodayCardButtonStyle())
                .accessibilityLabel(Text(ui: "Today in the collection: ask about \(artwork.credit)"))
                .accessibilityHint(Text(ui: "Asks Theseus about this work"))
                .accessibilityIdentifier("home.today")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(onAsk == nil ? "home.today" : "home.today.card")
        #if os(iOS)
        .fullScreenCover(item: $viewing) { ArtworkViewer($0) }
        #else
        .sheet(item: $viewing) { ArtworkViewer($0) }
        #endif
    }
}

private struct TodayCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Settings → Models (MODEL-04): which model new Chats start with. "Last used" follows the
/// latest send on this device; a fixed choice roams with the Account (`theseus.models`).
public struct DefaultModelSettingsView: View {
    let services: ComposerServices
    @State private var saving: String??
    @State private var error: String?

    public init(services: ComposerServices) {
        self.services = services
    }

    public var body: some View {
        List {
            Section {
                row(title: "Last used model", subtitle: lastUsedSubtitle, id: nil)
                ForEach(services.models) { option in
                    row(title: option.name, subtitle: option.pickerSubtitle, id: option.id)
                }
            } header: {
                Text("Start new chats with")
            } footer: {
                Text("Your choice applies on every device signed in to this Account. You can still switch models in any chat.")
            }
            .listRowBackground(Palette.surface.color)
            if let error {
                Section {
                    Text(error)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.destructive.color)
                }
                .listRowBackground(Palette.surface.color)
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("Models")
        .inlineTitle()
        .task { await services.refresh() }
        .accessibilityIdentifier("settings.models")
    }

    private var lastUsedSubtitle: String {
        if let name = services.model(id: services.store.lastUsedModelID)?.name { return "Currently \(name)" }
        return "The model you used most recently"
    }

    private func row(title: String, subtitle: String?, id: String?) -> some View {
        let selected = services.defaultModelSetting.flatMap { services.model(id: $0)?.id } == id
        return Button {
            Task { await choose(id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.body).foregroundStyle(Palette.textPrimary.color)
                    if let subtitle {
                        Text(subtitle).font(Typography.caption).foregroundStyle(Palette.textSecondary.color)
                    }
                }
                Spacer()
                if saving == .some(id) {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accent.color)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.models.\(id ?? "lastUsed")")
    }

    private func choose(_ id: String?) async {
        saving = .some(id)
        error = nil
        do {
            try await services.setDefaultModel(id)
        } catch {
            self.error = "Couldn't save your choice. \(error.message)"
        }
        saving = nil
    }
}
