/// The user's feedback on an assistant Message (MSG-06): a thumb, an optional comment, and the
/// Server's feedback record it was sent as. Mirrors Open WebUI's `message.annotation` plus
/// `message.feedbackId`.
public struct MessageAnnotation: Sendable, Hashable {
    public enum Rating: Int, Sendable, Hashable, CaseIterable {
        case good = 1
        case bad = -1
    }

    public var rating: Rating
    public var comment: String?
    /// The id of the Server's feedback record (`/api/v1/evaluations/feedback/{id}`), so a changed
    /// rating updates it instead of adding a second one.
    public var feedbackID: String?

    public init(rating: Rating, comment: String? = nil, feedbackID: String? = nil) {
        self.rating = rating
        self.comment = comment
        self.feedbackID = feedbackID
    }
}
