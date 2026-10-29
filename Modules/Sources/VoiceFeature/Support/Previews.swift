import DesignSystem
import SwiftUI

// Previews live apart from the views: Xcode's preview instrumentation of `public import SwiftUI`
// files trips over overloaded `__designTimeSelection` calls.

// MARK: VoiceModeView.swift

#Preview("Voice mode – start") {
    let voice = Voice.preview()
    VoiceModeView(voice: voice, model: .preview(voice: voice, phase: .listening))
}

#Preview("Voice mode – speaking, muted") {
    let voice = Voice.preview()
    VoiceModeView(voice: voice, model: .preview(voice: voice, phase: .speaking, muted: true))
}

#Preview("Voice mode – push to talk") {
    let voice = Voice.preview(mode: .pushToTalk)
    VoiceModeView(voice: voice, model: .preview(voice: voice, phase: .listening))
}

// MARK: DictationBar.swift

#Preview("Dictation bar") {
    DictationBarPreview()
        .padding()
        .themedBackground()
}

private struct DictationBarPreview: View {
    @State private var model = PreviewSupport.dictation(transcript: "Tell me how a mouse solves a maze")

    var body: some View {
        VStack {
            Spacer()
            DictationBar(model: model)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.m)
                .background(Palette.surface.color, in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.separator.color.opacity(0.6)))
        }
    }
}

// MARK: VoiceSettingsView.swift

#Preview("Voice settings") {
    VoiceSettingsSheet(voice: .preview())
}

// MARK: DictationIntroSheet.swift

#Preview("Dictation intro") {
    DictationIntroSheet(voice: .preview()) {}
}

#Preview("Speech language") {
    NavigationStack {
        SpeechLanguageList(voice: .preview())
    }
}

// MARK: VoiceShell.swift

#Preview("Voice chat ended") {
    VStack {
        VoiceEndedBanner(summary: VoiceSessionSummary(duration: 152, chatID: nil, lastResponseID: "r"), onRate: { _ in }, onDismiss: {})
        Spacer()
    }
    .themedBackground()
}
