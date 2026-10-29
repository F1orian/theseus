public import SwiftUI

extension EnvironmentValues {
    /// Whether a live Response's tail mouse is up (#195): the one live indicator. Step rows and
    /// cards below it drop their spinners, so the status isn't shown twice (the card's text still
    /// says what runs). Set by the Response; read by `StepStatusIcon`.
    @Entry public var liveStatusAtTail = false
}

/// The leading mark of a step row or card (CHAT-08, OT-02): a spinner while the step runs, its
/// icon once it's done. While the tail mouse is up (`liveStatusAtTail`, #195) a running step
/// shows its icon instead of a second spinner, or, under Reduce Motion, a still hourglass, so
/// the status still reads without motion.
///
/// ```swift
/// StepStatusIcon(isRunning: run.isRunning, systemImage: "apple.terminal")
/// ```
public struct StepStatusIcon: View {
    let isRunning: Bool
    let systemImage: String
    let controlSize: ControlSize
    @Environment(\.liveStatusAtTail) private var tailShowsStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isRunning: Bool, systemImage: String, controlSize: ControlSize = .small) {
        self.isRunning = isRunning
        self.systemImage = systemImage
        self.controlSize = controlSize
    }

    /// What it draws, for a state (tests).
    public enum Mark: Equatable {
        case spinner
        case icon(String)
    }

    public static func mark(isRunning: Bool, systemImage: String, tailShowsStatus: Bool, reduceMotion: Bool) -> Mark {
        guard isRunning else { return .icon(systemImage) }
        guard tailShowsStatus else { return .spinner }
        return .icon(reduceMotion ? "hourglass" : systemImage)
    }

    public var body: some View {
        switch Self.mark(isRunning: isRunning, systemImage: systemImage, tailShowsStatus: tailShowsStatus, reduceMotion: reduceMotion) {
        case .spinner:
            ProgressView().controlSize(controlSize)
                .transition(.opacity)
        case .icon(let name):
            Image(systemName: name)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }
}
