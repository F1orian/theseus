public import SwiftUI

/// Accessibility helpers shared by every Feature area (PLAT-06).
public enum AccessibilityMetrics {
    /// The smallest comfortable hit target (Apple HIG): 44 × 44 pt.
    public static let minimumHitTarget: CGFloat = 44
}

extension View {
    /// Grows the tappable area to at least 44 × 44 pt around a smaller visual (e.g. a 36 pt
    /// circle) and makes the whole area hit-testable, also for `.plain` buttons (PLAT-06).
    public func minimumHitTarget(_ size: CGFloat = AccessibilityMetrics.minimumHitTarget) -> some View {
        frame(minWidth: size, minHeight: size).contentShape(.rect)
    }

    /// For fixed-size chrome (header buttons, the composer row): caps Dynamic Type at
    /// `.accessibility1` so the layout keeps working, and offers the Large Content Viewer
    /// (long-press) for the larger sizes, as system bars do.
    public func chromeDynamicType() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityShowsLargeContentViewer()
    }

    /// `animation`, or none when Reduce Motion is on.
    public func motionSafeAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}

private struct MotionSafeAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension AnyTransition {
    /// `transition`, or a plain cross-fade when Reduce Motion is on (pass the environment's
    /// `accessibilityReduceMotion`).
    public static func motionSafe(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}

extension Animation {
    /// `animation`, or `nil` (no motion) when Reduce Motion is on.
    public static func motionSafe(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: Pointer (PLAT-05)

extension View {
    /// The system pointer highlight on iPad (trackpad, mouse) and Mac ("Designed for iPad").
    @ViewBuilder
    public func pointerHighlight() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// The pointer lifts the view (cards, rows) on iPad and Mac.
    @ViewBuilder
    public func pointerLift() -> some View {
        #if os(iOS)
        hoverEffect(.lift)
        #else
        self
        #endif
    }
}

extension View {
    /// `.transition(transition)`, or a cross-fade when Reduce Motion is on (PLAT-06).
    public func motionSafeTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionSafeTransition(transition: transition))
    }
}

private struct MotionSafeTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}
