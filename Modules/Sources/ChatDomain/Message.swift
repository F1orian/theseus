public import Foundation

/// A single user or assistant entry in a Chat, and one node of its `MessageTree`.
public struct Message: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
        case system
    }

    public let id: String
    public var parentID: String?
    /// Children in creation order; the last child is the newest Branch.
    public var childIDs: [String]
    public var role: Role
    public var content: String
    /// For assistant Messages: the model that produced it.
    public var modelID: String?
    public var createdAt: Date
    /// `false` while a Response is still streaming.
    public var isDone: Bool
    /// Assistant Messages: the structured Response (`output` items).
    public var output: [OutputItem]
    public var sources: [Source]
    public var statusHistory: [StatusUpdate]
    /// Assistant Messages: why the Response failed (`message.error.content`).
    public var error: String?
    /// Suggested next prompts (`message.followUps`).
    public var followUps: [String]
    /// User Messages: the files and photos sent with it (`message.files`).
    public var attachments: [Attachment] = []
    /// Assistant Messages: the user's thumb and comment (MSG-06), if any.
    public var annotation: MessageAnnotation?
    /// Assistant Messages: rich views tools attached (`message.embeds`): HTML documents or URLs.
    public var embeds: [String]

    public init(
        id: String,
        parentID: String?,
        childIDs: [String] = [],
        role: Role,
        content: String,
        modelID: String? = nil,
        createdAt: Date,
        isDone: Bool = true,
        output: [OutputItem] = [],
        sources: [Source] = [],
        statusHistory: [StatusUpdate] = [],
        error: String? = nil,
        followUps: [String] = [],
        annotation: MessageAnnotation? = nil,
        embeds: [String] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.childIDs = childIDs
        self.role = role
        self.content = content
        self.modelID = modelID
        self.createdAt = createdAt
        self.isDone = isDone
        self.output = output
        self.sources = sources
        self.statusHistory = statusHistory
        self.error = error
        self.followUps = followUps
        self.annotation = annotation
        self.embeds = embeds
    }

    /// The stored Response of an assistant Message, ready to render or to resume streaming into.
    public var response: ResponseState {
        ResponseState(
            output: output,
            content: content,
            sources: sources,
            statusHistory: statusHistory,
            followUps: followUps,
            error: error,
            isDone: isDone,
            embeds: embeds,
            files: role == .assistant ? attachments : []
        )
    }
}

/// One conversation: a title plus its Message tree.
public struct Chat: Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var tree: MessageTree
    public var createdAt: Date
    public var updatedAt: Date
    /// Server term: pinned.
    public var isStarred: Bool
    public var isArchived: Bool
    /// The Project (server term: folder) the Chat belongs to.
    public var projectID: String?
    /// Models selected for this Chat (`chat.models`).
    public var modelIDs: [String] = []

    public init(
        id: String,
        title: String,
        tree: MessageTree,
        createdAt: Date,
        updatedAt: Date,
        isStarred: Bool = false,
        isArchived: Bool = false,
        projectID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.tree = tree
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.projectID = projectID
    }
}
