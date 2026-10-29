import ChatDomain
import DesignSystem
public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// VOICE-07: back in the Chat after Voice mode, a banner with a waveform icon, the duration,
/// thumbs to rate the session and dismiss. The spoken exchange is in the Chat as normal Messages.
struct VoiceEndedBanner: View {
    let summary: VoiceSessionSummary
    let onRate: (MessageAnnotation.Rating) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.textPrimary.color)
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice chat ended")
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary.color)
                Text(summary.durationText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("voiceEnded.duration")
            }
            Spacer(minLength: Spacing.s)
            Group {
                if summary.canRate {
                    Button { onRate(.good) } label: { Image(systemName: "hand.thumbsup") }
                        .accessibilityLabel("Good voice chat")
                        .accessibilityIdentifier("voiceEnded.thumbsUp")
                    Button { onRate(.bad) } label: { Image(systemName: "hand.thumbsdown") }
                        .accessibilityLabel("Bad voice chat")
                        .accessibilityIdentifier("voiceEnded.thumbsDown")
                }
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("voiceEnded.dismiss")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.textPrimary.color)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .shadow(color: .black.opacity(0.1), radius: 14, y: 4)
        .padding(.horizontal, Spacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceEnded.banner")
    }
}

/// Presents Voice mode over the shell, the ended-session banner on top and the Dictation intro
/// (ADR 0081). Apply it to the signed-in shell's root.
struct VoiceShellModifier: ViewModifier {
    let voice: Voice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let voice {
            content
                // #131: the shell under Voice mode can't hold the keyboard or VoiceOver focus. A
                // disabled composer field can't become first responder again (e.g. when a sheet
                // over Voice mode restores the previous responder on dismissal).
                .disabled(voice.session != nil)
                .accessibilityHidden(voice.session != nil)
                .onChange(of: voice.session?.id) { _, id in
                    if id != nil { KeyboardDismissal.dismiss() }
                }
                .overlay(alignment: .top) {
                    if let summary = voice.endedSession, voice.session == nil {
                        VoiceEndedBanner(summary: summary, onRate: voice.rateEndedSession, onDismiss: voice.dismissBanner)
                            .padding(.top, Spacing.xs)
                            .transition(.motionSafe(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
                    }
                }
                .overlay {
                    if let session = voice.session {
                        VoiceModeView(voice: voice, model: session)
                            .transition(.motionSafe(.opacity.combined(with: .scale(scale: 1.02)), reduceMotion: reduceMotion))
                    }
                }
                .animation(.smooth(duration: 0.3), value: voice.session?.id)
                .animation(.snappy, value: voice.endedSession)
                .sheet(item: Binding(get: { voice.intro }, set: { voice.intro = $0 })) { request in
                    DictationIntroSheet(voice: voice) { voice.finishIntro(request) }
                        .presentationDetents([.large])
                }
        } else {
            content
        }
    }
}

/// Resigns whichever text input holds the keyboard (#131).
@MainActor
enum KeyboardDismissal {
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension View {
    /// Voice mode, its ended banner and the Dictation intro for the Account's `Voice`.
    public func voice(_ voice: Voice?) -> some View {
        modifier(VoiceShellModifier(voice: voice))
    }
}
