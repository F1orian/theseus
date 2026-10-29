import ChatDomain
import DesignSystem
public import SwiftUI

/// The Voice mode canvas (VOICE-03…05): near-blank, "Start talking" until the first turn, then
/// the user's bubble and the Response with thumbs. A soft glow at the bottom is cool while the
/// user talks and warm while the Response is spoken. Controls: Voice settings, mic (mute), end;
/// in push-to-talk mode the pill replaces the mic.
public struct VoiceModeView: View {
    let voice: Voice
    let model: VoiceModeModel
    @State private var showsSettings = false
    @State private var showsHint = false

    public init(voice: Voice, model: VoiceModeModel) {
        self.voice = voice
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Palette.background.color.ignoresSafeArea()
            VoiceGlow(tone: glowTone)
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                canvas
                liveTranscript
                controls
            }
            // VOICE-03…05: the live transcript, the turn's bubble and Response settle in as the
            // turn changes (ADR 0130).
            .motionSafeAnimation(Motion.smooth, value: model.phase)
            .motionSafeAnimation(Motion.smooth, value: model.transcript.isEmpty)
        }
        .accessibilityElement(children: .contain)
        // PLAT-06: VoiceOver stays on the Voice mode canvas, not the Chat underneath.
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("voice.mode")
        // #131: no keyboard over Voice mode, neither on entry nor after the settings sheet.
        .sheet(isPresented: $showsSettings, onDismiss: KeyboardDismissal.dismiss) {
            VoiceSettingsSheet(voice: voice)
        }
        .onChange(of: voice.settings.preferences) { old, new in
            voice.preferencesChanged(from: old, to: new)
            updateHint()
        }
        .onAppear {
            KeyboardDismissal.dismiss()
            updateHint()
        }
        .hapticCue(.voiceTurn, trigger: model.phase)  // PLAT-02: a soft tap on each turn change
    }

    private var glowTone: VoiceGlow.Tone {
        switch model.phase {
        case .speaking: .speaking
        case .listening where model.isListening: .listening
        case .thinking: .thinking
        default: .idle
        }
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        if let exchange = model.exchange {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        if model.isMuted { microphoneOff }
                        Text(exchange.userText)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary.color)
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, Spacing.m)
                            .background(Palette.accentSoft.color, in: .rect(cornerRadius: 20))
                            .accessibilityIdentifier("voice.userMessage")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    response(for: exchange)
                }
                .padding(.horizontal, Spacing.xl - 4)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.l)
            }
            // Short exchanges sit at the top; a long Response follows its newest text.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.hidden)
        } else {
            VStack(spacing: Spacing.s) {
                Spacer()
                if model.isMuted { microphoneOff }
                Text(placeholder)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice.placeholder")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.xl)
        }
    }

    private var placeholder: String {
        switch model.phase {
        case .starting: "Getting ready…"
        case .failed(let message): message
        default:
            model.mode == .pushToTalk ? "Hold the button to talk" : "Start talking"
        }
    }

    private var microphoneOff: some View {
        Text("Microphone off")
            .font(Typography.caption)
            .foregroundStyle(Palette.destructive.color)
            .accessibilityIdentifier("voice.microphoneOff")
    }

    @ViewBuilder
    private func response(for exchange: VoiceModeModel.Exchange) -> some View {
        let snapshot = model.response
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let snapshot, !snapshot.text.isEmpty {
                Text(Self.inlineMarkdown(snapshot.text))
                    .font(.system(.body, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.textPrimary.color)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("voice.response")
                if snapshot.isFinished, model.conversation.canRateVoiceResponses {
                    thumbs(for: exchange.responseID)
                }
            } else if let error = snapshot?.error {
                Text(error)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.destructive.color)
            } else {
                ThinkingDots()
                    .accessibilityLabel("Thinking")
            }
            if let notice = model.notice {
                Text(notice)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
    }

    private func thumbs(for responseID: String) -> some View {
        let rating = model.conversation.voiceRating(id: responseID)
        return HStack(spacing: Spacing.xs) {
            Button {
                voice.rate(responseID, .good, in: model.conversation)
            } label: {
                Image(systemName: rating == .good ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .minimumHitTarget()
            }
            .accessibilityLabel("Good response")
            .accessibilityIdentifier("voice.thumbsUp")
            Button {
                voice.rate(responseID, .bad, in: model.conversation)
            } label: {
                Image(systemName: rating == .bad ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .minimumHitTarget()
            }
            .accessibilityLabel("Bad response")
            .accessibilityIdentifier("voice.thumbsDown")
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
        .foregroundStyle(Palette.textSecondary.color)
        // The 44 pt targets: keep the first glyph aligned with the Response text.
        .padding(.leading, -14)
    }

    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Live transcript and controls

    @ViewBuilder
    private var liveTranscript: some View {
        if !model.transcript.isEmpty, model.phase == .listening {
            Text(model.transcript)
                .font(Typography.body.italic())
                .foregroundStyle(Palette.textSecondary.color)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xl - 4)
                .padding(.bottom, Spacing.l)
                .transition(.opacity)
                .accessibilityIdentifier("voice.transcript")
        }
    }

    private var controls: some View {
        HStack(spacing: Spacing.m) {
            CircleButton(systemImage: "gearshape", label: "Voice settings", identifier: "voice.settings") {
                showsSettings = true
            }
            Spacer(minLength: 0)
            if model.mode == .pushToTalk {
                PushToTalkPill(model: model, showsHint: showsHint) {
                    if showsHint {
                        voice.hints.hasSeenPushToTalkHint = true
                        showsHint = false
                    }
                }
                Spacer(minLength: 0)
            } else {
                muteButton
            }
            CircleButton(
                systemImage: "xmark",
                label: "End voice mode",
                identifier: "voice.end",
                foreground: Palette.background.color,
                background: Palette.textPrimary.color
            ) {
                voice.endVoiceMode()
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.l)
        .padding(.top, Spacing.s)
        .animation(.snappy, value: model.mode)
    }

    private var muteButton: some View {
        CircleButton(
            systemImage: model.isMuted ? "mic.slash.fill" : "mic",
            label: model.isMuted ? "Turn microphone on" : "Turn microphone off",
            identifier: "voice.mute",
            foreground: model.isMuted ? .white : Palette.textPrimary.color,
            background: model.isMuted ? Palette.destructive.color : Palette.surface.color
        ) {
            Task { await model.toggleMute() }
        }
        // The mic slashes and turns red (Visual language: Voice mode).
        .contentTransition(.symbolEffect(.replace))
        .motionSafeAnimation(Motion.snappy, value: model.isMuted)
        .hapticFeedback(.selection, trigger: model.isMuted)
    }

    private func updateHint() {
        showsHint = model.mode == .pushToTalk && !voice.hints.hasSeenPushToTalkHint
    }
}

/// A round 44 pt control on the Voice mode canvas.
struct CircleButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    var foreground: Color = Palette.textPrimary.color
    var background: Color = Palette.surface.color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(background, in: .circle)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Three dots pulsing while the first sentence is on its way.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.textTertiary.color)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 1 : 0.3)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}
