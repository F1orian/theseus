public import ChatDomain
import Foundation
public import OpenWebUIKit

/// Sends a thumbs-up or thumbs-down on a Response (MSG-06) the way the web client does: a
/// feedback record with the Chat snapshot (updated in place when the Message was rated before),
/// then the rating as `message.annotation` + `feedbackId` in the Chat, so every client shows it.
public struct FeedbackService: Sendable {
    public struct Rating: Sendable, Equatable {
        public var chatID: String
        public var messageID: String
        public var rating: MessageAnnotation.Rating
        public var comment: String
        public var modelID: String?
        public var siblingModelIDs: [String]
        /// The Message's earlier feedback record, if it was rated before.
        public var feedbackID: String?
        /// Reported as harmful or offensive (App Review 1.2, ADR 0172): a thumbs-down with a reason
        /// and the `reported` tag, so the Server's admins can find it in Evaluations.
        public var isReport: Bool

        public init(
            chatID: String,
            messageID: String,
            rating: MessageAnnotation.Rating,
            comment: String,
            modelID: String?,
            siblingModelIDs: [String] = [],
            feedbackID: String? = nil,
            isReport: Bool = false
        ) {
            self.chatID = chatID
            self.messageID = messageID
            self.rating = rating
            self.comment = comment
            self.modelID = modelID
            self.siblingModelIDs = siblingModelIDs
            self.feedbackID = feedbackID
            self.isReport = isReport
        }
    }

    /// What a report says in the Server's Evaluations (`data.reason`, `data.tags`).
    public static let reportReason = "Reported as harmful or offensive"
    public static let reportTag = "reported"

    let client: OpenWebUIClient

    public init(client: OpenWebUIClient) {
        self.client = client
    }

    /// Stores the rating; returns the annotation now on the Message.
    public func submit(_ rating: Rating) async throws(OpenWebUIError) -> MessageAnnotation {
        let chat = try await client.send(.rawChat(id: rating.chatID))
        let submission = FeedbackSubmission(
            rating: rating.rating,
            modelID: rating.modelID,
            comment: rating.comment,
            chatID: rating.chatID,
            messageID: rating.messageID,
            siblingModelIDs: rating.siblingModelIDs,
            snapshot: chat,
            reason: rating.isReport ? Self.reportReason : nil,
            tags: rating.isReport ? [Self.reportTag] : []
        )
        var record: FeedbackRecord?
        if let feedbackID = rating.feedbackID {
            // The record may have been deleted on the Server (e.g. from the web client).
            record = try? await client.send(.updateFeedback(id: feedbackID, submission))
        }
        if record == nil {
            record = try await client.send(.submitFeedback(submission))
        }
        let trimmed = rating.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = trimmed.isEmpty ? nil : trimmed
        let annotation = MessageAnnotation(rating: rating.rating, comment: comment, feedbackID: record?.id)

        // Annotate the stored Message; it's replaced as a whole, so start from the stored JSON.
        if case .object(var message)? = chat[path: "chat.history.messages"]?.objectValue?[rating.messageID] {
            var stored = message["annotation"]?.objectValue ?? [:]
            stored["rating"] = .number(Double(rating.rating.rawValue))
            stored["comment"] = comment.map(JSONValue.string) ?? .null
            message["annotation"] = .object(stored)
            if let id = record?.id { message["feedbackId"] = .string(id) }
            // The rating is already stored; a failed annotation only costs the thumb on other clients.
            _ = try? await client.send(.updateChatMessage(chatID: rating.chatID, messageID: rating.messageID, message: .object(message)))
        }
        return annotation
    }
}
