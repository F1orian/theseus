import DesignSystem
import Testing

/// The motion tokens' arithmetic (ADR 0130): the text reveal keeps pace with the stream and the
/// drawer's settle spring starts at the finger's speed.
@Suite("Motion tokens")
struct MotionTests {
    @Test func revealDurationStaysBetweenAQuarterAndSixTenthsOfASecond() {
        #expect(Motion.revealDuration(characters: 1) == 0.25)
        #expect(Motion.revealDuration(characters: 64) == 0.4)
        #expect(Motion.revealDuration(characters: 5_000) == 0.6)
    }

    @Test func durationsGrowWithTheSizeOfWhatMoves() {
        #expect(Motion.Duration.instant < Motion.Duration.short)
        #expect(Motion.Duration.short < Motion.Duration.medium)
        #expect(Motion.Duration.medium < Motion.Duration.long)
    }

    @Test func drawerSettleIsASpringForAnyRelease() {
        // A flick, a slow release, a release at the target and one away from it all make a spring.
        _ = Motion.drawerSettle(velocity: 2_000, distance: 120)
        _ = Motion.drawerSettle(velocity: 50, distance: 200)
        _ = Motion.drawerSettle(velocity: 800, distance: 0)
        _ = Motion.drawerSettle(velocity: -500, distance: 100)
    }
}
