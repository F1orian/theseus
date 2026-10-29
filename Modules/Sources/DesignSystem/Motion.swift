public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The app's motion tokens (ADR 0130). Screens name the *moment* ("a Message arrives", "the
/// drawer settles"), not a curve, so the same moment moves the same way everywhere. Every token
/// is a native SwiftUI spring or curve; route them through the Reduce Motion helpers
/// (`motionSafeAnimation`, `motionSafeTransition`, `withMotion`) so they turn off — or turn into
/// a cross-fade — when the user asks for less motion (PLAT-06).
///
/// ```swift
/// .motionSafeAnimation(Motion.snappy, value: isStreaming)
/// withMotion(Motion.drawer) { isOpen = true }
/// ```
public enum Motion {
    // MARK: Durations

    /// Durations (seconds) for the few places that need a number rather than a spring.
    public enum Duration {
        /// A symbol swap, a tick, a live transcript update.
        public static let instant: Double = 0.12
        /// Small controls: chips, toggles, a button morph.
        public static let short: Double = 0.22
        /// Most content: cards, rows, expanders, toasts.
        public static let medium: Double = 0.32
        /// Larger surfaces: the drawer, a Message arriving, the greeting.
        public static let long: Double = 0.45
        /// One breath of the "working" pulse (the brand mark while the model thinks).
        public static let pulse: Double = 0.9
    }

    // MARK: Springs

    /// Controls and chrome: chips, the send ↔ stop morph, toggles, pills. Quick, no overshoot.
    public static let snappy = Animation.snappy(duration: Duration.short)
    /// Content: expanders (Thinking, Sources, tool steps), cards, notices, list changes.
    public static let smooth = Animation.smooth(duration: Duration.medium)
    /// A little life for confirmations: star, copied, thumbs, a chip landing.
    public static let bouncy = Animation.bouncy(duration: Duration.medium, extraBounce: 0.08)
    /// A Message joining the transcript (it rises from the composer) and the Response appearing.
    public static let message = Animation.spring(duration: Duration.long, bounce: 0.12)
    /// Top toasts and banners sliding in and out.
    public static let toast = Animation.spring(duration: Duration.medium, bounce: 0.18)
    /// The drawer opening or closing from a tap (CHATS-01).
    public static let drawer = Animation.spring(duration: 0.4, bounce: 0.0)
    /// Large content swaps (a screen's state changing, the greeting, a branch switch).
    public static let fade = Animation.easeInOut(duration: Duration.medium)
    /// Tiny live updates that should only soften a change (dictation text, levels).
    public static let live = Animation.easeOut(duration: Duration.instant)

    /// The drawer settling after a drag: a critically damped spring that starts at the finger's
    /// speed, so a flick carries through and a slow release eases in.
    ///
    /// - Parameters:
    ///   - velocity: The release speed in points per second, towards the target.
    ///   - distance: The remaining distance to the target in points.
    public static func drawerSettle(velocity: CGFloat, distance: CGFloat) -> Animation {
        // `initialVelocity` is in units of the animated distance per second.
        let relative = distance > 1 ? min(max(velocity / distance, 0), 30) : 0
        return .interpolatingSpring(mass: 1, stiffness: 280, damping: 34, initialVelocity: relative)
    }

    // MARK: Text reveal (CHAT-01)

    /// How long a streamed chunk takes to fade in: about 160 characters a second, never slower
    /// than the stream itself (a chunk lands every ~40 ms) and never sluggish.
    public static func revealDuration(characters: Int) -> Double {
        min(0.6, max(0.25, Double(characters) / 160))
    }

    /// How many glyphs behind the reveal front are still fading (a soft leading edge).
    public static let revealFadeGlyphs: Double = 14
}

// MARK: Transitions

extension AnyTransition {
    /// A user Message rising from the composer into the transcript (CHAT-01).
    public static var messageInsert: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.92, anchor: .bottomTrailing))
                .combined(with: .opacity),
            removal: .opacity
        )
    }

    /// A card or row that appears under what's already there (notices, chips, follow-ups).
    public static var rise: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// A row arriving in a stack whose rows below move down to make room for it (a Response's
    /// parts, #191): it rises in once they've moved, so nothing slides across it while it shows.
    /// Leaving, it goes at once, so nothing slides across it either.
    public static var arrive: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity)
                .animation(.easeOut(duration: Motion.Duration.short).delay(Motion.Duration.medium)),
            removal: leaveAtOnce
        )
    }

    /// A row that goes at once when it leaves, rather than fading while the rows below slide up
    /// across it (#191).
    public static var leaveAtOnce: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(nil))
    }

    /// The content of an expander (Thinking, tool steps, a run's code) dropping open under its
    /// header.
    public static var expand: AnyTransition {
        .asymmetric(
            insertion: .offset(y: -8).combined(with: .opacity),
            removal: .offset(y: -4).combined(with: .opacity)
        )
    }

    /// A top toast or banner (MSG-02).
    public static var toast: AnyTransition {
        .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top))
    }

    /// Something small popping in and out (a button morph, a badge).
    public static var pop: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }
}

// MARK: Reduce Motion

/// Whether the user asked for reduced motion, for code without a SwiftUI environment (models,
/// gesture callbacks). Views read `\.accessibilityReduceMotion` instead.
@MainActor
public var isReduceMotionEnabled: Bool {
    #if canImport(UIKit)
    UIAccessibility.isReduceMotionEnabled
    #else
    false
    #endif
}

/// `withAnimation(animation, body)`, or no animation when Reduce Motion is on. For state changes
/// outside a view's environment (models, closures the shell passes down).
@MainActor
@discardableResult
public func withMotion<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(isReduceMotionEnabled ? nil : animation, body)
}

extension EnvironmentValues {
    /// Whether content that appears now is *new* (a finished Response's action row, a run card
    /// landing) rather than part of a screen that just loaded. Screens turn it on once their
    /// first content has settled; `appearsWithFade()` reads it.
    @Entry public var animatesContentAppearance = false
}

extension View {
    /// Fades the view in when it appears, if the screen says content is arriving now
    /// (`\.animatesContentAppearance`); appears at once while the screen loads.
    public func appearsWithFade(duration: Double = Motion.Duration.medium) -> some View {
        modifier(AppearsWithFade(duration: duration))
    }

    /// Runs a looping "working" pulse (opacity and scale) while `isActive`, or a gentle fade
    /// under Reduce Motion. Uses `PhaseAnimator`, so the loop never leaks into other changes.
    public func workingPulse(isActive: Bool = true) -> some View {
        modifier(WorkingPulse(isActive: isActive))
    }

    /// Fades the view in when it first appears, if `isEnabled` (e.g. a block arriving in a
    /// streaming Response). State-driven, so it doesn't animate anything around it.
    public func fadeInOnAppear(_ isEnabled: Bool, duration: Double = Motion.Duration.medium) -> some View {
        modifier(FadeInOnAppear(isEnabled: isEnabled, duration: duration))
    }
}

private struct WorkingPulse: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive {
            content.phaseAnimator([false, true]) { view, phase in
                view
                    .opacity(phase ? 0.55 : 1)
                    .scaleEffect(reduceMotion ? 1 : (phase ? 1.06 : 1))
            } animation: { _ in
                .easeInOut(duration: reduceMotion ? 1.2 : Motion.Duration.pulse)
            }
        } else {
            content
        }
    }
}

private struct AppearsWithFade: ViewModifier {
    let duration: Double
    @Environment(\.animatesContentAppearance) private var animates
    /// Captured when the view first appears, so a later flip of the flag doesn't hide it.
    @State private var fades: Bool?

    func body(content: Content) -> some View {
        content
            .modifier(FadeInOnAppear(isEnabled: fades ?? animates, duration: duration))
            .onAppear { if fades == nil { fades = animates } }
    }
}

private struct FadeInOnAppear: ViewModifier {
    let isEnabled: Bool
    let duration: Double
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled && !isShown && !reduceMotion ? 0 : 1)
            .onAppear {
                guard isEnabled, !isShown, !reduceMotion else { return }
                withAnimation(.easeOut(duration: duration)) { isShown = true }
            }
    }
}
