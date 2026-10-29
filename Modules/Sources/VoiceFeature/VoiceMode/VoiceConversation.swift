public import ChatDomain
public import ChatFeature
import Foundation

/// A Response as Voice mode follows it.
public struct VoiceResponseSnapshot: Sendable, Equatable {
    public var text: String
    public var isFinished: Bool
    /// Why the Response failed, if it did.
    public var error: String?

    public init(text: String, isFinished: Bool, error: String? = nil) {
        self.text = text
        self.isFinished = isFinished
        self.error = error
    }
}

/// The Chat a Voice mode session talks in (ADR 0081). `ConversationModel` is the live one;
/// tests use a fake.
@MainActor
public protocol VoiceConversation: AnyObject, Sendable {
    var chatID: String? { get }
    var canSendVoiceMessage: Bool { get }
    /// Whether Responses can be rated (a saved Chat and the `rateResponse` Capability).
    var canRateVoiceResponses: Bool { get }
    /// Sends a spoken turn; returns the id of the assistant Message that streams the Response.
    func sendVoiceMessage(_ text: String) -> String?
    /// The Response streaming (or stored) under `id`.
    func voiceResponse(id: String) -> VoiceResponseSnapshot?
    /// The user's rating of a Response, if any.
    func voiceRating(id: String) -> MessageAnnotation.Rating?
    /// Stops the streaming Response, keeping its partial text (CHAT-02).
    func stopVoiceResponse() async
}

extension ConversationModel: VoiceConversation {
    public var canRateVoiceResponses: Bool {
        chatID != nil && !isIncognito && capabilities.contains(.rateResponse)
    }

    public func voiceResponse(id: String) -> VoiceResponseSnapshot? {
        guard let message = message(id: id) else { return nil }
        let state = response(for: message)
        return VoiceResponseSnapshot(text: state.text, isFinished: state.isFinished, error: state.error)
    }

    public func voiceRating(id: String) -> MessageAnnotation.Rating? {
        message(id: id)?.annotation?.rating
    }

    public func stopVoiceResponse() async {
        await stop()
    }
}
