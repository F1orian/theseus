public import Foundation

/// A Chat as it appears in the sidebar list: no Messages, just enough to render a row.
public struct ChatSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastReadAt: Date?
    /// A search snippet (only set by search endpoints).
    public var snippet: String?
    public var isArchived: Bool
    /// Starred (server term: pinned). Only known when the source reports it (`/chats/pinned`, a
    /// `ChatResponse`); plain list pages leave it `false`.
    public var isStarred: Bool
    /// The Project (server term: folder) the Chat belongs to, when known.
    public var projectID: String?

    public init(
        id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        lastReadAt: Date? = nil,
        snippet: String? = nil,
        isArchived: Bool = false,
        isStarred: Bool = false,
        projectID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.snippet = snippet
        self.isArchived = isArchived
        self.isStarred = isStarred
        self.projectID = projectID
    }

    /// Updated since the user last opened it.
    public var isUnread: Bool {
        guard let lastReadAt else { return false }
        return updatedAt > lastReadAt
    }
}
