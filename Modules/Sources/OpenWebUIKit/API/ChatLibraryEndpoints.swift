public import ChatDomain
import Foundation

// Chats library endpoints (CHATS-01…10): list, Starred (server term: pinned), search, star, rename,
// delete. Paths follow docs/research/open-webui-api.md §4.1.

extension Endpoint where Response == [ChatSummary] {
    /// `GET /api/v1/chats/?page=&include_pinned=&include_folders=`: 60 Chats per page, newest first.
    /// By default the server leaves out starred Chats and Chats in a Project; the flags add them.
    /// Rows don't say whether they are starred; combine with `starredChats` for that.
    public static func chats(page: Int, includeStarred: Bool, includeProjects: Bool) -> Self {
        Endpoint(
            method: .get,
            path: "api/v1/chats/",
            query: [
                URLQueryItem(name: "page", value: String(max(page, 1))),
                URLQueryItem(name: "include_pinned", value: includeStarred ? "true" : "false"),
                URLQueryItem(name: "include_folders", value: includeProjects ? "true" : "false"),
            ],
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode([ChatSummaryWire].self, from: data).map(\.domain)
        }
    }

    /// `GET /api/v1/chats/pinned`: every Starred chat (server term: pinned), newest first.
    public static var starredChats: Self {
        Endpoint(method: .get, path: "api/v1/chats/pinned", authentication: .required) { data in
            try WireCoding.decoder.decode([ChatSummaryWire].self, from: data).map { wire in
                var summary = wire.domain
                summary.isStarred = true
                return summary
            }
        }
    }

    /// `GET /api/v1/chats/search?text=&page=`: Chats whose title or Messages match `text`, 60 per
    /// page. Rows carry a `snippet` of the matching Message text when the match isn't in the title.
    public static func searchChats(text: String, page: Int) -> Self {
        Endpoint(
            method: .get,
            path: "api/v1/chats/search",
            query: [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ],
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode([ChatSummaryWire].self, from: data).map(\.domain)
        }
    }

    /// The server's page size for `searchChats(text:page:)`.
    public static var searchPageSize: Int { 60 }
}

extension Endpoint where Response == ChatSummary {
    /// `POST /api/v1/chats/{id}/pin`: **toggles** Starred (server term: pinned) and returns the Chat.
    public static func toggleStar(chatID: String) -> Self {
        Endpoint(method: .post, path: "api/v1/chats/\(chatID)/pin", authentication: .required) { data in
            try WireCoding.decoder.decode(ChatResponseSummaryWire.self, from: data).domain
        }
    }

    /// `POST /api/v1/chats/{id}` with `{chat:{title}}`. The server merges the patch into the Chat.
    public static func renameChat(id: String, title: String) -> Self {
        let body = try? WireCoding.encoder.encode(["chat": ["title": title]])
        return Endpoint(
            method: .post,
            path: "api/v1/chats/\(id)",
            body: body ?? Data(),
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode(ChatResponseSummaryWire.self, from: data).domain
        }
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/chats/{id}`: needs the `chat.delete` permission (Capability `deleteChat`).
    /// The server also cancels the Chat's running tasks.
    public static func deleteChat(id: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/chats/\(id)", authentication: .required)
    }
}

/// The list-relevant subset of `ChatResponse` (`B/models/chats.py`). Timestamps are epoch seconds.
private struct ChatResponseSummaryWire: Decodable {
    let id: String
    let title: String
    let updatedAt: Double
    let createdAt: Double
    let archived: Bool?
    let pinned: Bool?
    let folderID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, archived, pinned
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case folderID = "folder_id"
    }

    var domain: ChatSummary {
        ChatSummary(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isArchived: archived ?? false,
            isStarred: pinned ?? false,
            projectID: folderID
        )
    }
}
