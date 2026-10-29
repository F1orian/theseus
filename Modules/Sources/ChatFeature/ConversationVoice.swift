public import ComposerFeature
import Foundation
public import SwiftUI

/// Turns a Conversation into the composer's mic and voice-mode actions (Voice epic, ADR 0081).
/// The host app fills it from `VoiceFeature`; without it the composer shows its placeholders.
public struct ConversationVoice {
    public var composerActions: (@MainActor (ConversationModel) -> ComposerVoiceActions)?

    public init(composerActions: (@MainActor (ConversationModel) -> ComposerVoiceActions)? = nil) {
        self.composerActions = composerActions
    }
}

extension EnvironmentValues {
    @Entry public var conversationVoice = ConversationVoice()
}

/// Spoken turns (Voice mode, VOICE-03): the same send pipeline as the composer, so the exchange
/// is stored as ordinary Messages of this Chat.
extension ConversationModel {
    /// Whether a spoken turn can be sent now: loaded, nothing streaming, no question pending,
    /// the Server reachable and a model chosen.
    public var canSendVoiceMessage: Bool {
        loadState == .loaded && !isStreaming && pendingQuestion == nil
            && services.connection.allowsSending && composer.selectedModelID != nil
    }

    /// Sends `text` as the next user Message with the composer's model, Effort and toggles plus
    /// `features.voice` (the Server adds its voice-mode prompt). The draft and its Attachments
    /// are left alone. Returns the id of the assistant Message that streams the Response, or
    /// `nil` when nothing was sent.
    @discardableResult
    public func sendVoiceMessage(_ text: String) -> String? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, canSendVoiceMessage, let modelID = composer.selectedModelID else { return nil }
        notice = nil
        services.composer.recordUse(of: modelID)
        var options = options(for: modelID)
        options.features["voice"] = true
        let assistantID = idGenerator()
        let parentID = tree.currentID
        // Runs synchronously up to the request: both Messages are in the thread and the
        // Response is streaming by the time this returns.
        Task.immediate { await submit(prompt: prompt, modelID: modelID, parentID: parentID, existingUserID: nil, options: options, assistantID: assistantID) }
        return assistantID
    }
}
