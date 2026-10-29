import DesignSystem
import SwiftUI
import Testing

@Suite("Haptic cues (PLAT-02)")
struct HapticCueTests {
    @Test func sendAndStopAreLightImpacts() {
        #expect(HapticCue.send.feedback == .impact(weight: .light))
        #expect(HapticCue.stop.feedback == .impact(weight: .light))
    }

    @Test func pickersAndSwitchesTick() {
        #expect(HapticCue.selection.feedback == .selection)
    }

    @Test func outcomesUseTheSystemNotificationFeedback() {
        #expect(HapticCue.error.feedback == .error)
        #expect(HapticCue.warning.feedback == .warning)
    }

    @Test func responsesAndVoiceTurnsAreSoft() {
        #expect(HapticCue.responseDone.feedback == .impact(flexibility: .soft, intensity: 0.6))
        #expect(HapticCue.voiceTurn.feedback == .impact(flexibility: .soft))
    }

    @Test func everyCueHasDistinctPurpose() {
        // Send and stop share a feel on purpose; everything else is distinguishable.
        let cues = HapticCue.allCases.filter { $0 != .stop }
        for (index, cue) in cues.enumerated() {
            for other in cues[(index + 1)...] {
                #expect(cue.feedback != other.feedback, "\(cue) feels like \(other)")
            }
        }
    }
}
