@testable import ChatFeature
import CoreGraphics
import Testing

/// #183: a finger on the transcript stops following a streaming Response; only a deliberate
/// return to the very bottom, the jump-to-bottom button or a sent Message resume it.
@Suite("Following the stream")
struct TranscriptFollowTests {
    @Test func aTouchWithoutMovementStopsFollowing() {
        var follow = TranscriptFollow()
        #expect(follow.isFollowing)
        #expect(follow.phaseChanged(to: .tracking) == .stopped)
        #expect(!follow.isFollowing)
        #expect(follow.isUserScrolling)
        #expect(follow.phaseChanged(to: .interacting) == nil, "already stopped")
    }

    @Test func streamGrowthAloneNeverResumes() {
        var follow = TranscriptFollow()
        _ = follow.phaseChanged(to: .tracking)
        // The finger rests near the end while text arrives (the old 48 pt rule resumed here).
        for distance in stride(from: 40, through: 0, by: -10) {
            follow.geometryChanged(distanceFromBottom: CGFloat(distance))
            #expect(!follow.isFollowing)
        }
        follow.geometryChanged(distanceFromBottom: 300)
        _ = follow.phaseChanged(to: .idle)
        #expect(!follow.isFollowing, "released away from the end")
        // Text keeps arriving; the view later sits at the end only because of a programmatic
        // change, not the user's scroll: still not following.
        follow.geometryChanged(distanceFromBottom: 0)
        #expect(!follow.isFollowing)
        #expect(follow.phaseChanged(to: .animating) == nil)
        #expect(follow.phaseChanged(to: .idle) == nil)
        #expect(!follow.isFollowing)
    }

    @Test func comingToRestAtTheVeryBottomResumes() {
        var follow = TranscriptFollow()
        _ = follow.phaseChanged(to: .interacting)
        follow.geometryChanged(distanceFromBottom: 200)
        _ = follow.phaseChanged(to: .decelerating)
        #expect(follow.isUserScrolling)
        follow.geometryChanged(distanceFromBottom: 20)
        #expect(!follow.isFollowing, "close isn't the bottom")
        follow.geometryChanged(distanceFromBottom: TranscriptFollow.resumeDistance)
        #expect(!follow.isFollowing, "not until the scroll ends")
        #expect(follow.phaseChanged(to: .idle) == .resumed)
        #expect(follow.isFollowing)
        #expect(!follow.isUserScrolling)
    }

    @Test func restingJustAboveTheBottomDoesNotResume() {
        var follow = TranscriptFollow()
        _ = follow.phaseChanged(to: .interacting)
        follow.geometryChanged(distanceFromBottom: 30)
        #expect(follow.phaseChanged(to: .idle) == nil)
        #expect(!follow.isFollowing)
        #expect(follow.showsJumpToBottom)
    }

    @Test func theButtonOrASendFollowsAgain() {
        var follow = TranscriptFollow()
        _ = follow.phaseChanged(to: .tracking)
        follow.geometryChanged(distanceFromBottom: 500)
        _ = follow.phaseChanged(to: .idle)
        #expect(follow.showsJumpToBottom)
        follow.follow()
        #expect(follow.isFollowing)
        #expect(!follow.showsJumpToBottom)
    }

    @Test func theButtonHidesAtTheEnd() {
        var follow = TranscriptFollow()
        _ = follow.phaseChanged(to: .tracking)
        follow.geometryChanged(distanceFromBottom: 4)
        #expect(!follow.showsJumpToBottom)
    }
}

@Suite("Following the stream: touches")
struct TranscriptFollowTouchTests {
    @Test func aHoldStopsAndAReleaseAwayFromTheEndKeepsItStopped() {
        var follow = TranscriptFollow()
        #expect(follow.touchBegan() == .stopped)
        // The follow animation in flight reports `animating`, then `idle`, under the finger.
        #expect(follow.phaseChanged(to: .animating) == nil)
        #expect(follow.phaseChanged(to: .idle) == nil)
        #expect(follow.isUserScrolling, "held")
        follow.geometryChanged(distanceFromBottom: 400)
        #expect(follow.touchEnded() == nil)
        #expect(!follow.isFollowing)
        #expect(follow.showsJumpToBottom)
    }

    @Test func aTapAtTheVeryEndKeepsFollowing() {
        var follow = TranscriptFollow()
        follow.geometryChanged(distanceFromBottom: 2)
        #expect(follow.touchBegan() == .stopped)
        #expect(follow.touchEnded() == .resumed)
        #expect(follow.isFollowing)
    }

    @Test func aFlingEndsWhenItsDecelerationDoes() {
        var follow = TranscriptFollow()
        _ = follow.touchBegan()
        _ = follow.phaseChanged(to: .interacting)
        _ = follow.phaseChanged(to: .decelerating)
        follow.geometryChanged(distanceFromBottom: 0)
        #expect(follow.touchEnded() == nil, "still decelerating")
        #expect(follow.phaseChanged(to: .idle) == .resumed)
    }
}
