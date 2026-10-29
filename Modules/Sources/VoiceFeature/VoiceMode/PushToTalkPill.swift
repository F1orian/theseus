import DesignSystem
import SwiftUI

/// VOICE-04: "Push to talk". Holding it grows a blue pill with the live waveform; releasing sends.
/// A tooltip explains it the first time.
struct PushToTalkPill: View {
    let model: VoiceModeModel
    let showsHint: Bool
    let onFirstHold: () -> Void
    @GestureState private var pressing = false

    var body: some View {
        let holding = model.isHoldingToTalk
        ZStack {
            if holding {
                LevelWaveform(levels: Array(model.levels.suffix(14)), color: Palette.onAccent.color)
                    .frame(width: 84, height: 22)
                    .transition(.opacity)
            } else {
                Text("Push to talk")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary.color)
                    .transition(.opacity)
            }
        }
        .frame(width: holding ? 160 : 140, height: holding ? 64 : 56)
        .background(holding ? Palette.accent.color : Palette.surface.color, in: .capsule)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
        )
        .onChange(of: pressing) { _, isPressing in
            if isPressing {
                onFirstHold()
                Task { await model.beginTalking() }
            } else {
                Task { await model.endTalking() }
            }
        }
        .overlay(alignment: .top) {
            if showsHint, !holding {
                Text("Hold to speak, release\nto send")
                    .font(Typography.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary.color)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(Palette.surface.color, in: .rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .fixedSize()
                    .offset(y: -70)
                    .transition(.opacity)
                    .accessibilityIdentifier("voice.pushToTalkHint")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: holding)
        .hapticFeedback(.impact(weight: .medium), trigger: holding)
        .accessibilityElement()
        .accessibilityLabel("Push to talk")
        .accessibilityHint("Hold while you talk, let go to send")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: holding ? "Send" : "Start talking") {
            Task {
                if model.isHoldingToTalk { await model.endTalking() } else { await model.beginTalking() }
            }
        }
        .accessibilityIdentifier("voice.pushToTalk")
    }
}
