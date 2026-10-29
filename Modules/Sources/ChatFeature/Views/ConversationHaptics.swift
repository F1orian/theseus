import ChatDomain
import DesignSystem
import SwiftUI

/// Which haptic a Conversation's state change deserves (PLAT-02): a light tap when a Message is
/// sent, a soft one when its Response finishes, the stop tap when the user stopped it, and the
/// error pattern when it failed or the Chat couldn't load. Respects the Settings switch (SET-03).
enum ConversationHaptics {
    /// The parts of a Conversation that haptics react to.
    struct State: Equatable {
        var streamingMessageID: String?
        /// The phase of the latest Response in the thread.
        var lastPhase: ResponseState.Phase?
        var loadFailed = false
        var notice: String?
    }

    static func cue(from old: State, to new: State) -> HapticCue? {
        if old.streamingMessageID == nil, new.streamingMessageID != nil {
            return .send
        }
        if old.streamingMessageID != nil, new.streamingMessageID == nil {
            switch new.lastPhase {
            case .completed?: return .responseDone
            case .stopped?: return .stop
            case .failed?: return .error
            default: break
            }
        }
        if !old.loadFailed, new.loadFailed {
            return .error
        }
        if new.notice != nil, new.notice != old.notice {
            return .warning
        }
        return nil
    }
}

extension ConversationModel {
    var hapticState: ConversationHaptics.State {
        let lastResponse = thread.last { $0.role == .assistant }
        let loadFailed = if case .failed = loadState { true } else { false }
        return ConversationHaptics.State(
            streamingMessageID: streamingMessageID,
            lastPhase: lastResponse.map { response(for: $0).phase },
            loadFailed: loadFailed,
            notice: notice
        )
    }
}

extension View {
    /// Plays the Conversation's haptic cues (PLAT-02).
    func conversationHaptics(_ model: ConversationModel) -> some View {
        hapticCue(trigger: model.hapticState, ConversationHaptics.cue(from:to:))
    }
}
