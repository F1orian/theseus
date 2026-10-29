import DesignSystem
import SwiftUI
import Testing

@Suite("Accessibility helpers (PLAT-06)")
struct AccessibilityTests {
    @Test func hitTargetsFollowTheHIG() {
        #expect(AccessibilityMetrics.minimumHitTarget == 44)
    }

    @Test func reduceMotionDropsAnimations() {
        #expect(Animation.motionSafe(.snappy, reduceMotion: true) == nil)
        #expect(Animation.motionSafe(.snappy, reduceMotion: false) == .snappy)
    }
}
