import CoreGraphics

/// Whether the transcript follows a streaming Response to its end (#183, like
/// Messages): a finger on the transcript stops it at once, and only a deliberate return to the
/// very bottom, the jump-to-bottom button or a new Message resume it. Stream growth alone never
/// does.
///
/// The view feeds it scroll phases and the distance from the bottom, and acts on the changes it
/// reports (cancel the follow animation, follow again).
struct TranscriptFollow: Equatable {
    /// How close to the end a scroll must come to rest to follow again: the very bottom.
    static let resumeDistance: CGFloat = 8

    /// The scroll phases that matter here (`ScrollPhase` without SwiftUI).
    enum Phase: Equatable {
        case idle, tracking, interacting, decelerating, animating
    }

    enum Change: Equatable {
        /// The user took over: stop following and cancel any follow animation in flight.
        case stopped
        /// The user came to rest at the very bottom: follow again.
        case resumed
    }

    private(set) var isFollowing = true
    /// Points between the visible bottom and the end of the content (negative while bouncing).
    private(set) var distanceFromBottom: CGFloat = 0
    /// A finger is on the transcript, or its fling is still running.
    private(set) var isUserScrolling = false
    /// The current scroll began with the user (not a follow animation).
    private var userScrolled = false

    /// The jump-to-bottom button shows while the transcript isn't following and the end is out of
    /// reach.
    var showsJumpToBottom: Bool { !isFollowing && distanceFromBottom > Self.resumeDistance }

    /// The scroll phase SwiftUI reported last.
    private var phase: Phase = .idle
    /// A finger is down on the transcript (scrolling or not).
    private(set) var isTouching = false

    /// A finger landed on the transcript. SwiftUI reports no scroll phase for a touch that doesn't
    /// move (and none while a follow animation runs), so the view observes touches itself.
    mutating func touchBegan() -> Change? {
        isTouching = true
        return phaseChanged(to: .tracking)
    }

    /// The finger lifted. Without a scroll of its own (a hold or a tap), that's where the user
    /// came to rest; a fling ends when its deceleration does.
    mutating func touchEnded() -> Change? {
        isTouching = false
        guard phase == .idle || phase == .tracking || phase == .animating else { return nil }
        return phaseChanged(to: .idle)
    }

    mutating func phaseChanged(to phase: Phase) -> Change? {
        self.phase = phase
        switch phase {
        case .tracking, .interacting:
            // A touch, even without movement, stops following.
            isUserScrolling = true
            userScrolled = true
            guard isFollowing else { return nil }
            isFollowing = false
            return .stopped
        case .decelerating:
            isUserScrolling = userScrolled
            return nil
        case .animating:
            isUserScrolling = isTouching
            return nil
        case .idle:
            // Still held: the user hasn't come to rest yet.
            guard !isTouching else { return nil }
            isUserScrolling = false
            guard userScrolled else { return nil }
            userScrolled = false
            guard !isFollowing, distanceFromBottom <= Self.resumeDistance else { return nil }
            isFollowing = true
            return .resumed
        }
    }

    /// The content or the visible rect changed. Never resumes following on its own: a stream that
    /// grows under a resting finger, or a small drag near the end, mustn't pull the view along.
    mutating func geometryChanged(distanceFromBottom distance: CGFloat) {
        distanceFromBottom = distance
    }

    /// Follow again: the jump-to-bottom button, or the user sent a Message.
    mutating func follow() {
        isFollowing = true
    }
}
