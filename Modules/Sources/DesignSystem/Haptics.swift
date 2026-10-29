public import SwiftUI

extension EnvironmentValues {
    /// Whether app haptics are on (the Settings "Haptic feedback" switch, SET-03). The app shell
    /// sets it from the Account's preferences; views play haptics through `hapticFeedback(_:trigger:)`.
    @Entry public var hapticFeedbackEnabled = true
}

/// The app's haptic vocabulary (PLAT-02). Screens name the moment, not the feel, so every send,
/// stop, finished Response and error feels the same everywhere:
/// light impact on send/stop, selection ticks on pickers and switches, a soft tap when a Response
/// finishes or a Voice mode turn changes, and the system error/warning patterns for problems.
public enum HapticCue: Sendable, Hashable, CaseIterable {
    /// A Message was sent (or retried).
    case send
    /// The user stopped a Response.
    case stop
    /// A Response finished streaming.
    case responseDone
    /// A choice in a picker, segmented control or switch changed.
    case selection
    /// Something failed (a Response, sign-in, a request the user started).
    case error
    /// Something needs attention but nothing broke (a rejected Attachment, a notice).
    case warning
    /// Voice mode handed the turn to the user or the model (VOICE-03).
    case voiceTurn

    public var feedback: SensoryFeedback {
        switch self {
        case .send, .stop: .impact(weight: .light)
        case .responseDone: .impact(flexibility: .soft, intensity: 0.6)
        case .selection: .selection
        case .error: .error
        case .warning: .warning
        case .voiceTurn: .impact(flexibility: .soft)
        }
    }
}

extension View {
    /// Plays `feedback` when `trigger` changes, unless the user turned haptics off in Settings.
    /// Use this instead of `sensoryFeedback` so every haptic respects the switch (PLAT-02).
    public func hapticFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(HapticFeedbackModifier(feedback: feedback, trigger: trigger))
    }

    /// Plays `cue` whenever `trigger` changes, respecting the Settings switch (SET-03).
    public func hapticCue<T: Equatable>(_ cue: HapticCue, trigger: T) -> some View {
        hapticFeedback(cue.feedback, trigger: trigger)
    }

    /// Plays the cue `cue(old, new)` returns when `trigger` changes (none for `nil`), respecting the
    /// Settings switch. Use it when only some transitions deserve a haptic:
    ///
    /// ```swift
    /// .hapticCue(trigger: errorMessage) { _, new in new == nil ? nil : .error }
    /// ```
    public func hapticCue<T: Equatable>(
        trigger: T,
        _ cue: @escaping (_ old: T, _ new: T) -> HapticCue?
    ) -> some View {
        modifier(HapticCueModifier(trigger: trigger, cue: cue))
    }
}

private struct HapticFeedbackModifier<T: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: T
    @Environment(\.hapticFeedbackEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in isEnabled }
    }
}

private struct HapticCueModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let cue: (T, T) -> HapticCue?
    @Environment(\.hapticFeedbackEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { old, new in
            isEnabled ? cue(old, new)?.feedback : nil
        }
    }
}
