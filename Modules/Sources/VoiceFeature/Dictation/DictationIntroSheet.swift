import DesignSystem
import SwiftUI

/// The first-use Dictation intro (VOICE-02): an illustration, three benefits, the Speech
/// language row (pushes the full language list) and Continue.
struct DictationIntroSheet: View {
    let voice: Voice
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.l)
                MicrophoneIllustration()
                    .frame(width: 120, height: 130)
                Text("Speak instead of typing.")
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    benefit("globe", "In the language you speak")
                    benefit("timer", "Up to ten minutes at a time")
                    benefit("lock", "Transcribed on this device")
                }
                Spacer(minLength: Spacing.l)
                VStack(spacing: Spacing.m) {
                    NavigationLink {
                        SpeechLanguageList(voice: voice)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speech language")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary.color)
                                Text(languageName)
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.textPrimary.color)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary.color)
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
                        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dictationIntro.language")
                    Button("Continue", action: onContinue)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("dictationIntro.continue")
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("dictationIntro.close")
                }
            }
        }
        .task { await voice.settings.load() }
        .accessibilityIdentifier("dictationIntro")
    }

    private var languageName: String {
        let identifier = voice.settings.preferences.language ?? Locale.current.identifier
        return SpeechLanguage.displayName(for: identifier)
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(Palette.textPrimary.color)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.textSecondary.color)
        }
        .font(Typography.callout)
    }
}

/// The full-screen checked list of Speech languages (VOICE-02).
struct SpeechLanguageList: View {
    let voice: Voice
    @State private var languages: [SpeechLanguage] = []
    @State private var query = ""

    var body: some View {
        List {
            row(id: nil, name: "Automatic (\(SpeechLanguage.displayName(for: Locale.current.identifier)))")
            ForEach(filtered) { language in
                row(id: language.id, name: language.name)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle("Speech language")
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        #endif
        .task { languages = voice.speech.speechLanguages() }
        .accessibilityIdentifier("speechLanguage.list")
    }

    private var filtered: [SpeechLanguage] {
        guard !query.isEmpty else { return languages }
        return languages.filter { $0.name.localizedStandardContains(query) }
    }

    private func row(id: String?, name: String) -> some View {
        Button {
            voice.settings.update { $0.language = id }
        } label: {
            HStack {
                Text(name).foregroundStyle(Palette.textPrimary.color)
                Spacer()
                if voice.settings.preferences.language == id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary.color)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(voice.settings.preferences.language == id ? .isSelected : [])
        .accessibilityIdentifier("speechLanguage.\(id ?? "automatic")")
    }
}

/// A microphone on a warm disc, drawn with SF Symbols (Theseus's own illustration).
struct MicrophoneIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.accent.color.opacity(0.75))
                .frame(width: 76, height: 76)
                .offset(y: -18)
            Image(systemName: "microphone")
                .font(.system(size: 92, weight: .ultraLight))
                .foregroundStyle(Palette.textPrimary.color)
        }
        .accessibilityHidden(true)
    }
}
