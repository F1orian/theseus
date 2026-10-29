import DesignSystem
public import OpenWebUIKit
public import SettingsFeature
public import SwiftUI

/// Voice settings (VOICE-06): a swipeable carousel of voices with page dots, Language (Beta),
/// Speed and Mode. Opened from Settings → Voice or the gear in Voice mode.
struct VoiceSettingsContent: View {
    let voice: Voice
    @State private var voices: [VoiceOption] = []
    @State private var languages: [SpeechLanguage] = []
    @State private var centered: String?
    @State private var previewer: (any SpeechSynthesizer)?
    @State private var loadedVoices = false

    private var settings: VoiceSettingsStore { voice.settings }
    private var preferences: VoicePreferences { settings.preferences }

    /// The carousel's cards: "Automatic" first, then the stack's voices.
    private var cards: [VoiceOption] {
        [VoiceOption(id: Self.automaticID, name: "Automatic", detail: "Matches your language")] + voices
    }

    static let automaticID = "theseus.automatic"
    static let cardWidth: CGFloat = 132

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                carousel
                VStack(spacing: Spacing.m) {
                    languageRow
                    speedRow
                }
                .padding(.horizontal, Spacing.l)
                modeSection
                    .padding(.horizontal, Spacing.l)
                if let error = settings.errorMessage {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.destructive.color)
                        .padding(.horizontal, Spacing.l)
                }
            }
            .padding(.vertical, Spacing.l)
        }
        .themedBackground()
        .task {
            await settings.load()
            languages = voice.speech.speechLanguages()
        }
        .task(id: preferences.language) {
            await loadVoices()
        }
        .onDisappear {
            previewer?.stop()
            previewer = nil
        }
        .accessibilityIdentifier("voiceSettings")
    }

    // MARK: Voices

    private var carousel: some View {
        VStack(spacing: Spacing.m) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Spacing.m) {
                        ForEach(cards) { option in
                            VoiceCard(option: option, isSelected: option.id == selectedID)
                                .frame(width: Self.cardWidth)
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.8)
                                        .opacity(phase.isIdentity ? 1 : 0.6)
                                }
                                .onTapGesture {
                                    withAnimation(.snappy) { centered = option.id }
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (geometry.size.width - Self.cardWidth) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $centered, anchor: .center)
            }
            .frame(height: 140)
            .onChange(of: centered) { _, id in
                guard loadedVoices, let id, id != selectedID else { return }
                choose(id)
            }
            .accessibilityIdentifier("voiceSettings.voices")
            PageDots(count: cards.count, index: cards.firstIndex { $0.id == (centered ?? selectedID) } ?? 0)
            if let detail = cards.first(where: { $0.id == selectedID })?.detail {
                Text(ui: detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var selectedID: String {
        guard let chosen = preferences.voice, voices.contains(where: { $0.id == chosen }) else { return Self.automaticID }
        return chosen
    }

    private func loadVoices() async {
        loadedVoices = false
        voices = await voice.speech.voices(for: preferences.language)
        centered = selectedID
        // Let the carousel settle on the chosen voice before swipes count as choices.
        try? await Task.sleep(for: .milliseconds(300))
        loadedVoices = true
    }

    private func choose(_ id: String) {
        let chosen = id == Self.automaticID ? nil : id
        settings.update { $0.voice = chosen }
        preview(voice: chosen, name: cards.first { $0.id == id }?.name)
    }

    /// Says a short sample in the chosen voice.
    private func preview(voice chosen: String?, name: String?) {
        previewer?.stop()
        var preferences = settings.preferences
        preferences.voice = chosen
        let speech = voice.speech
        Task {
            let synthesizer = await speech.makeSynthesizer(preferences: preferences)
            previewer = synthesizer
            let sample = name.map { "Hi, I'm \($0). This is how I'll sound." } ?? "This is how I'll sound."
            try? await synthesizer.speak(sample)
        }
    }

    // MARK: Rows

    private var languageRow: some View {
        SettingsCardRow {
            HStack(spacing: Spacing.s) {
                Text("Language")
                    .foregroundStyle(Palette.textPrimary.color)
                Text("Beta")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.recessedSurface.color, in: .capsule)
                Spacer(minLength: Spacing.s)
                Menu {
                    Picker("Language", selection: Binding(
                        get: { preferences.language ?? "" },
                        set: { value in settings.update { $0.language = value.isEmpty ? nil : value } }
                    )) {
                        Text("Automatic").tag("")
                        ForEach(languages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(languageName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundStyle(Palette.textSecondary.color)
                }
                .accessibilityIdentifier("voiceSettings.language")
            }
        }
    }

    private var languageName: String {
        preferences.language.map { SpeechLanguage.displayName(for: $0) } ?? "Automatic"
    }

    private var speedRow: some View {
        SettingsCardRow {
            HStack {
                Text("Speed")
                    .foregroundStyle(Palette.textPrimary.color)
                Spacer(minLength: Spacing.s)
                Menu {
                    Picker("Speed", selection: Binding(
                        get: { preferences.speed },
                        set: { value in settings.update { $0.speed = value } }
                    )) {
                        ForEach(VoicePreferences.Speed.allCases) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(preferences.speed.title)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundStyle(Palette.textSecondary.color)
                }
                .accessibilityIdentifier("voiceSettings.speed")
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Mode")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .padding(.horizontal, Spacing.xs)
            VStack(spacing: 0) {
                ForEach(VoicePreferences.Mode.allCases) { mode in
                    Button {
                        settings.update { $0.mode = mode }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .foregroundStyle(Palette.textPrimary.color)
                                Text(mode.caption)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary.color)
                            }
                            Spacer()
                            if preferences.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.accent.color)
                            }
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preferences.mode == mode ? .isSelected : [])
                    .accessibilityIdentifier("voiceSettings.mode.\(mode.rawValue)")
                    if mode != VoicePreferences.Mode.allCases.last {
                        Divider().padding(.leading, Spacing.l)
                    }
                }
            }
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        }
        .hapticFeedback(.selection, trigger: preferences.mode)
    }
}

/// One voice in the carousel.
private struct VoiceCard: View {
    let option: VoiceOption
    let isSelected: Bool

    var body: some View {
        Text(option.name)
            .font(Typography.callout.weight(isSelected ? .medium : .regular))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Palette.textPrimary.color)
            .multilineTextAlignment(.center)
            .padding(Spacing.s)
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(Palette.surface.color, in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(isSelected ? Palette.accent.color : Palette.separator.color))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("voiceSettings.voice.\(option.name)")
    }
}

/// A rounded row on the settings canvas.
struct SettingsCardRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 48)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
    }
}

/// Page dots under the voice carousel.
struct PageDots: View {
    let count: Int
    let index: Int

    /// At most this many dots; longer lists show a window around the current page.
    static let maximum = 9

    var body: some View {
        let window = Self.window(count: count, index: index)
        HStack(spacing: 6) {
            ForEach(window, id: \.self) { dot in
                let isEdge = window.count < count && (dot == window.first && dot > 0 || dot == window.last && dot < count - 1)
                Circle()
                    .fill(dot == index ? Palette.textPrimary.color : Palette.textTertiary.color.opacity(0.4))
                    .frame(width: isEdge ? 4 : 6, height: isEdge ? 4 : 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: index)
        .accessibilityHidden(true)
    }

    static func window(count: Int, index: Int) -> [Int] {
        guard count > maximum else { return Array(0..<count) }
        let start = min(max(0, index - maximum / 2), count - maximum)
        return Array(start..<(start + maximum))
    }
}

/// Voice settings as a sheet, from the gear in Voice mode.
struct VoiceSettingsSheet: View {
    let voice: Voice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VoiceSettingsContent(voice: voice)
                .navigationTitle("Voice settings")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .tint(Palette.textPrimary.color)
                            .accessibilityIdentifier("voiceSettings.close")
                    }
                }
        }
        .presentationDetents([.large])
    }
}

/// Settings → Voice (VOICE-06).
public struct VoiceSettingsPage: View {
    let voice: Voice

    public init(voice: Voice) {
        self.voice = voice
    }

    public var body: some View {
        VoiceSettingsContent(voice: voice)
            .navigationTitle("Voice")
            .toolbarTitleDisplayMode(.inline)
    }
}

extension VoiceSettingsPage {
    /// Registers Settings → Voice when the Account may dictate, use Voice mode or hear Responses
    /// read aloud (ADR 0006).
    @MainActor
    public static func register(in extensions: inout SettingsExtensions, voice: Voice, capabilities: Capabilities) {
        guard capabilities.contains(.voiceMode) || capabilities.contains(.dictation) || capabilities.contains(.readAloud) else { return }
        extensions.register(.voice) { VoiceSettingsPage(voice: voice) }
    }
}
