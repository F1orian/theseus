public import ChatDomain
import Foundation

// Chat document and completion endpoints (docs/research/open-webui-api.md §4–5).

/// `GET /api/v1/chats/{id}`: a Chat with its full Message tree. Assistant Messages still being
/// generated come back with `isDone == false` and the server's snapshot so far (CHAT-12).
public struct ChatDocument: Sendable, Equatable {
    public var chat: Chat
    /// The Project (folder) id, if any.
    public var folderID: String? { chat.projectID }

    public init(chat: Chat) {
        self.chat = chat
    }
}

/// The immediate answer to a socket-mode completion request (`{status, task_ids, chat_id}`).
public struct CompletionAccepted: Sendable, Equatable, Decodable {
    public let chatID: String?
    public let taskIDs: [String]
    /// The Response paused on a tool approval or clarifying question.
    public let isPaused: Bool

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case taskIDs = "task_ids"
        case paused
    }

    public init(chatID: String?, taskIDs: [String], isPaused: Bool = false) {
        self.chatID = chatID
        self.taskIDs = taskIDs
        self.isPaused = isPaused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
        taskIDs = try container.decodeIfPresent([String].self, forKey: .taskIDs) ?? []
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

/// A Project (server term: folder), for the header chip.
public struct ProjectSummary: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
}

extension Endpoint where Response == ChatDocument {
    /// `GET /api/v1/chats/{id}` (with the live in-progress overlay).
    public static func chat(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/chats/\(id)", authentication: .required) { data in
            ChatDocument(chat: try WireCoding.decoder.decode(ChatWire.self, from: data).domain)
        }
    }

    /// `POST /api/v1/chats/new`: stores a Chat the client built (SSE fallback only; in socket
    /// mode the server creates Chats itself).
    static func createChat(body: Data) -> Self {
        Endpoint(method: .post, path: "api/v1/chats/new", body: body, authentication: .required) { data in
            ChatDocument(chat: try WireCoding.decoder.decode(ChatWire.self, from: data).domain)
        }
    }

    /// `POST /api/v1/chats/{id}`: merges `history.messages` message by message (SSE fallback).
    static func updateChat(id: String, body: Data) -> Self {
        Endpoint(method: .post, path: "api/v1/chats/\(id)", body: body, authentication: .required) { data in
            ChatDocument(chat: try WireCoding.decoder.decode(ChatWire.self, from: data).domain)
        }
    }
}

extension Endpoint where Response == JSONValue {
    /// `POST /api/tasks/chat/{chat_id}/stop`: stops generation; the partial Response is kept.
    public static func stopChat(id: String) -> Self {
        Endpoint(method: .post, path: "api/tasks/chat/\(id)/stop", authentication: .required)
    }

    /// `POST /api/v1/chats/{id}/messages/{message_id}/resolve` for a paused tool call.
    static func resolveToolCall(chatID: String, messageID: String, body: Data) -> Self {
        Endpoint(
            method: .post,
            path: "api/v1/chats/\(chatID)/messages/\(messageID)/resolve",
            body: body,
            authentication: .required
        )
    }
}

extension Endpoint where Response == [String] {
    /// `GET /api/tasks/chat/{chat_id}`: ids of generations still running for the Chat.
    public static func chatTasks(id: String) -> Self {
        Endpoint(method: .get, path: "api/tasks/chat/\(id)", authentication: .required) { data in
            try WireCoding.decoder.decode(TaskList.self, from: data).taskIDs
        }
    }
}

extension Endpoint where Response == Bool {
    /// `GET /health`: `true` when the Server answers.
    public static var health: Self {
        Endpoint(method: .get, path: "health", authentication: .none) { data in
            (try? WireCoding.decoder.decode(JSONValue.self, from: data))?[path: "status"]?.boolValue ?? false
        }
    }
}

extension Endpoint where Response == CompletionAccepted {
    /// `POST /api/chat/completions` in socket mode (`session_id` + chat fields).
    static func startCompletion(body: Data) -> Self {
        Endpoint(method: .post, path: "api/chat/completions", body: body, authentication: .required)
    }
}

extension Endpoint where Response == ProjectSummary {
    /// `GET /api/v1/folders/{id}`.
    public static func project(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/folders/\(id)", authentication: .required)
    }
}

private struct TaskList: Decodable {
    let taskIDs: [String]
    enum CodingKeys: String, CodingKey { case taskIDs = "task_ids" }
}

// MARK: - Wire shapes

/// `ChatResponse` (`B/models/chats.py`).
struct ChatWire: Decodable {
    struct Body: Decodable {
        let title: String?
        let models: [String]?
        let history: History?
    }

    struct History: Decodable {
        let currentId: String?
        let messages: [String: MessageWire]?
    }

    let id: String
    let title: String?
    let chat: Body
    let updatedAt: Double?
    let createdAt: Double?
    let pinned: Bool?
    let archived: Bool?
    let folderID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, chat, pinned, archived
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case folderID = "folder_id"
    }

    var domain: Chat {
        let messages = (chat.history?.messages ?? [:]).map { key, value in value.domain(fallbackID: key) }
        var result = Chat(
            id: id,
            title: title ?? chat.title ?? "",
            tree: MessageTree(messages: messages, currentID: chat.history?.currentId),
            createdAt: Date(timeIntervalSince1970: createdAt ?? 0),
            updatedAt: Date(timeIntervalSince1970: updatedAt ?? createdAt ?? 0),
            isStarred: pinned ?? false,
            isArchived: archived ?? false,
            projectID: folderID
        )
        result.modelIDs = chat.models ?? []
        return result
    }
}

/// One `chat.history.messages[id]` node. Unknown fields are ignored; the server owns the
/// document, so the client never writes it back in socket mode.
struct MessageWire: Decodable {
    let id: String?
    let parentId: String?
    let childrenIds: [String]?
    let role: String?
    let content: String
    let model: String?
    let timestamp: Double?
    let done: Bool?
    let output: [OutputItem]?
    let sources: [Source]?
    let statusHistory: [StatusUpdate]?
    let error: String?
    let followUps: [String]?
    let files: [Attachment]
    let annotation: MessageAnnotation?
    let embeds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, parentId, childrenIds, role, content, model, timestamp, done, output, sources, statusHistory, error, followUps
        case annotation, feedbackId, files, embeds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        id = optional(String.self, .id)
        parentId = optional(String.self, .parentId)
        childrenIds = optional([String].self, .childrenIds)
        role = optional(String.self, .role)
        // User content may be OpenAI multimodal parts; keep the text parts.
        if let text = optional(String.self, .content) {
            content = text
        } else if let parts = optional([JSONValue].self, .content) {
            content = parts.compactMap { $0[path: "text"]?.stringValue }.joined(separator: "\n")
        } else {
            content = ""
        }
        model = optional(String.self, .model)
        timestamp = optional(Double.self, .timestamp)
        done = optional(Bool.self, .done)
        output = optional([OutputItem].self, .output)
        sources = optional([Source].self, .sources)
        statusHistory = optional([StatusUpdate].self, .statusHistory)
        let errorValue = optional(JSONValue.self, .error)
        error = errorValue?.stringValue ?? errorValue?[path: "content"]?.stringValue
        followUps = optional([String].self, .followUps)
        // Tool embeds are HTML documents or URLs; anything else is skipped.
        embeds = optional([JSONValue].self, .embeds)?.compactMap(\.stringValue)
        // MSG-06: `annotation.rating` is ±1 (the web client may also store a 1…10 score; ignore it).
        let rating = optional(JSONValue.self, .annotation)?[path: "rating"].flatMap(WireCoding.int)
        annotation = rating.flatMap(MessageAnnotation.Rating.init(rawValue:)).map { rating in
            MessageAnnotation(
                rating: rating,
                comment: optional(JSONValue.self, .annotation)?[path: "comment"]?.stringValue,
                feedbackID: optional(String.self, .feedbackId)
            )
        }
        files = (optional([JSONValue].self, .files) ?? []).enumerated().compactMap { index, file in
            Self.attachment(from: file, index: index)
        }
    }

    /// `message.files[]` items the conversation can show: uploaded files (`type: "file"`) and
    /// inline images (`type: "image"`). Knowledge, notes and other references are skipped.
    static func attachment(from file: JSONValue, index: Int) -> Attachment? {
        let type = file[path: "type"]?.stringValue ?? "file"
        switch type {
        case "image":
            guard let url = file[path: "url"]?.stringValue, !url.isEmpty else { return nil }
            return Attachment(id: file[path: "id"]?.stringValue ?? "image-\(index)", name: file[path: "name"]?.stringValue ?? "Image", kind: .image, url: url)
        case "file", "doc":
            guard let id = file[path: "id"]?.stringValue ?? file[path: "file.id"]?.stringValue else { return nil }
            let contentType = file[path: "content_type"]?.stringValue ?? file[path: "file.meta.content_type"]?.stringValue
            let name = file[path: "name"]?.stringValue ?? file[path: "file.meta.name"]?.stringValue ?? "File"
            let size = (file[path: "size"] ?? file[path: "file.meta.size"])?.numberValue.map { Int($0) }
            let isImage = contentType?.lowercased().hasPrefix("image/") ?? false
            return Attachment(id: id, name: name, kind: isImage ? .image : .document, contentType: contentType, size: size)
        default:
            return nil
        }
    }

    func domain(fallbackID: String) -> Message {
        // Timestamps are seconds; some clients wrote milliseconds.
        let seconds = timestamp.map { $0 > 100_000_000_000 ? $0 / 1000 : $0 } ?? 0
        var message = Message(
            id: id ?? fallbackID,
            parentID: parentId,
            childIDs: childrenIds ?? [],
            role: Message.Role(rawValue: role ?? "") ?? .assistant,
            content: content,
            modelID: model,
            createdAt: Date(timeIntervalSince1970: seconds),
            isDone: done ?? true,
            output: output ?? [],
            sources: sources ?? [],
            statusHistory: statusHistory ?? [],
            error: error,
            followUps: followUps ?? [],
            annotation: annotation,
            embeds: embeds ?? []
        )
        message.attachments = files
        return message
    }
}
