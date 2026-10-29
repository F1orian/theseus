public import ChatDomain
public import Foundation

// Message actions (MSG-03…08): Branch selection, feedback, Chat links and speech
// (docs/research/open-webui-api.md §4, §8, §9.9).

// MARK: Chat document

extension Endpoint where Response == ChatDocument {
    /// `POST /api/v1/chats/{id}` with only `history.currentId`: shows another Branch (MSG-04).
    /// The server merges history message by message, so nothing else changes.
    public static func selectBranch(chatID: String, currentID: String) -> Self {
        let body: JSONValue = .object(["chat": .object(["history": .object(["currentId": .string(currentID)])])])
        return Endpoint(method: .post, path: "api/v1/chats/\(chatID)", body: WireCoding.encode(body), authentication: .required) { data in
            ChatDocument(chat: try WireCoding.decoder.decode(ChatWire.self, from: data).domain)
        }
    }
}

extension Endpoint where Response == JSONValue {
    /// `GET /api/v1/chats/{id}` as raw JSON, keeping every field the domain model drops (for
    /// feedback snapshots and read-modify-write of one Message).
    public static func rawChat(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/chats/\(id)", authentication: .required)
    }

    /// `POST /api/v1/chats/{id}` replacing one `history.messages` entry. The server replaces the
    /// entry as a whole, so `message` must be the complete stored Message (see `rawChat(id:)`).
    public static func updateChatMessage(chatID: String, messageID: String, message: JSONValue) -> Self {
        let body: JSONValue = .object(["chat": .object(["history": .object(["messages": .object([messageID: message])])])])
        return Endpoint(method: .post, path: "api/v1/chats/\(chatID)", body: WireCoding.encode(body), authentication: .required)
    }
}

// MARK: Feedback (MSG-06)

/// A thumbs-up or thumbs-down on an assistant Message (`FeedbackForm`, type `rating`).
public struct FeedbackSubmission: Sendable, Equatable {
    public var rating: MessageAnnotation.Rating
    public var modelID: String?
    public var comment: String?
    public var chatID: String
    public var messageID: String
    /// Models of the sibling Branches, which the Server's leaderboard compares against.
    public var siblingModelIDs: [String]
    /// The Chat as it was rated (`snapshot.chat`); `nil` sends none.
    public var snapshot: JSONValue?
    /// Why it was rated (`data.reason`, shown to admins in Evaluations), e.g. a report (ADR 0172).
    public var reason: String?
    /// `data.tags`, e.g. `["reported"]` so admins can find reports.
    public var tags: [String]

    public init(
        rating: MessageAnnotation.Rating,
        modelID: String?,
        comment: String?,
        chatID: String,
        messageID: String,
        siblingModelIDs: [String] = [],
        snapshot: JSONValue? = nil,
        reason: String? = nil,
        tags: [String] = []
    ) {
        self.rating = rating
        self.modelID = modelID
        self.comment = comment
        self.chatID = chatID
        self.messageID = messageID
        self.siblingModelIDs = siblingModelIDs
        self.snapshot = snapshot
        self.reason = reason
        self.tags = tags
    }

    var trimmedComment: String? {
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var json: JSONValue {
        var data: [String: JSONValue] = ["rating": .number(Double(rating.rawValue))]
        if let modelID { data["model_id"] = .string(modelID) }
        if let comment = trimmedComment { data["comment"] = .string(comment) }
        if !siblingModelIDs.isEmpty { data["sibling_model_ids"] = .array(siblingModelIDs.map(JSONValue.string)) }
        if let reason { data["reason"] = .string(reason) }
        if !tags.isEmpty { data["tags"] = .array(tags.map(JSONValue.string)) }
        var meta: [String: JSONValue] = ["chat_id": .string(chatID), "message_id": .string(messageID)]
        if let modelID { meta["model_id"] = .string(modelID) }
        var body: [String: JSONValue] = ["type": .string("rating"), "data": .object(data), "meta": .object(meta)]
        if let snapshot { body["snapshot"] = .object(["chat": snapshot]) }
        return .object(body)
    }
}

/// The Server's stored feedback record (`FeedbackModel`).
public struct FeedbackRecord: Sendable, Equatable, Decodable {
    public let id: String
    public let rating: MessageAnnotation.Rating?

    enum CodingKeys: String, CodingKey { case id, data }

    public init(id: String, rating: MessageAnnotation.Rating?) {
        self.id = id
        self.rating = rating
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
        rating = data?[path: "rating"].flatMap(WireCoding.int).flatMap(MessageAnnotation.Rating.init(rawValue:))
    }
}

extension Endpoint where Response == FeedbackRecord {
    /// `POST /api/v1/evaluations/feedback` (needs `enable_message_rating` and `chat.rate_response`).
    public static func submitFeedback(_ feedback: FeedbackSubmission) -> Self {
        Endpoint(method: .post, path: "api/v1/evaluations/feedback", body: WireCoding.encode(feedback.json), authentication: .required)
    }

    /// `POST /api/v1/evaluations/feedback/{id}`: changes an earlier rating.
    public static func updateFeedback(id: String, _ feedback: FeedbackSubmission) -> Self {
        Endpoint(method: .post, path: "api/v1/evaluations/feedback/\(id)", body: WireCoding.encode(feedback.json), authentication: .required)
    }
}

// MARK: Chat links (MSG-08)

/// A Chat's share link: a snapshot of the Chat at the time it was (re-)shared.
public struct ChatShareLink: Sendable, Equatable, Decodable {
    public let shareID: String

    enum CodingKeys: String, CodingKey { case shareID = "share_id" }

    public init(shareID: String) {
        self.shareID = shareID
    }

    /// The web URL of the snapshot (`{server}/s/{share_id}`).
    public func url(server: URL) -> URL {
        server.appending(path: "s").appending(path: shareID)
    }
}

/// Who may open a Chat link (`access_grants` on the `shared_chat` resource).
public struct ShareAccessGrant: Sendable, Hashable, Codable {
    public let principalType: String
    public let principalID: String
    public let permission: String

    enum CodingKeys: String, CodingKey {
        case principalType = "principal_type"
        case principalID = "principal_id"
        case permission
    }

    public init(principalType: String, principalID: String, permission: String) {
        self.principalType = principalType
        self.principalID = principalID
        self.permission = permission
    }

    /// Every signed-in user of the Server may read the link (needs `sharing.public_chats`).
    public static let everyoneSignedIn = ShareAccessGrant(principalType: "user", principalID: "*", permission: "read")
}

extension Endpoint where Response == ChatShareLink {
    /// `POST /api/v1/chats/{id}/share` (needs `chat.share`). Re-posting re-snapshots the Chat.
    public static func shareChat(id: String) -> Self {
        Endpoint(method: .post, path: "api/v1/chats/\(id)/share", body: Data("{}".utf8), authentication: .required)
    }
}

extension Endpoint where Response == String? {
    /// `GET /api/v1/chats/{id}`, reading only `share_id`: the current link, if the Chat has one.
    public static func chatShareID(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/chats/\(id)", authentication: .required) { data in
            try WireCoding.decoder.decode(JSONValue.self, from: data)[path: "share_id"]?.stringValue
        }
    }
}

extension Endpoint where Response == [ShareAccessGrant] {
    /// `GET /api/v1/chats/shared/{chat_id}/access`.
    public static func sharedChatAccess(chatID: String) -> Self {
        Endpoint(method: .get, path: "api/v1/chats/shared/\(chatID)/access", authentication: .required)
    }
}

extension Endpoint where Response == JSONValue {
    /// `POST /api/v1/chats/shared/{chat_id}/access/update`. The server silently drops grants the
    /// Account may not give (e.g. `everyoneSignedIn` without `sharing.public_chats`).
    public static func updateSharedChatAccess(chatID: String, grants: [ShareAccessGrant]) -> Self {
        let body: JSONValue = .object(["access_grants": .array(grants.map { grant in
            .object([
                "principal_type": .string(grant.principalType),
                "principal_id": .string(grant.principalID),
                "permission": .string(grant.permission),
            ])
        })])
        return Endpoint(method: .post, path: "api/v1/chats/shared/\(chatID)/access/update", body: WireCoding.encode(body), authentication: .required)
    }
}

// MARK: Speech (MSG-07)

/// The Server's text-to-speech setup (`/api/config` → `audio.tts`).
public struct AudioConfig: Sendable, Equatable, Decodable {
    /// `nil` when no engine is configured (the Server answers `/audio/speech` with 404).
    public let ttsEngine: String?
    public let ttsVoice: String?
    /// The speech-to-text engine (`audio.stt.engine`); `nil` when none is configured or it's the
    /// web client's browser recogniser (`web`). Theseus then transcribes on-device (ADR 0080).
    public var sttEngine: String?

    public init(ttsEngine: String?, ttsVoice: String?, sttEngine: String? = nil) {
        self.ttsEngine = ttsEngine
        self.ttsVoice = ttsVoice
        self.sttEngine = sttEngine
    }

    public var hasServerSpeech: Bool { ttsEngine != nil }

    /// Whether `/api/v1/audio/transcriptions` can transcribe (VOICE-01, ADR 0080).
    public var hasServerTranscription: Bool { sttEngine != nil }

    public init(from decoder: any Decoder) throws {
        let json = try decoder.singleValueContainer().decode(JSONValue.self)
        func nonEmpty(_ path: String) -> String? {
            guard let value = json[path: path]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        ttsEngine = nonEmpty("audio.tts.engine")
        ttsVoice = nonEmpty("audio.tts.voice")
        sttEngine = nonEmpty("audio.stt.engine").flatMap { $0 == "web" ? nil : $0 }
    }
}

extension Endpoint where Response == AudioConfig {
    /// `GET /api/config` (authenticated), reading only the audio setup.
    public static var audioConfig: Self {
        Endpoint(method: .get, path: "api/config", authentication: .required)
    }
}

extension Endpoint where Response == Data {
    /// `POST /api/v1/audio/speech` (needs `chat.tts` and a TTS engine): audio bytes (mp3 by default).
    public static func speech(text: String, voice: String?) -> Self {
        var body: [String: JSONValue] = ["input": .string(text)]
        if let voice { body["voice"] = .string(voice) }
        return Endpoint(method: .post, path: "api/v1/audio/speech", body: WireCoding.encode(.object(body)), authentication: .required) { $0 }
    }
}

extension WireCoding {
    static func encode(_ value: JSONValue) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    static func int(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let number): Int(exactly: number.rounded())
        case .string(let text): Int(text)
        default: nil
        }
    }
}
