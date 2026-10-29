public import ChatDomain
public import Foundation

// Settings endpoints (SET-*): personal usage, the admin contact and Shared links.
// Paths follow docs/research/open-webui-api.md §1.1, §2 and §4.1.

// MARK: Usage (SET-09, "Server & usage")

/// Personal usage statistics (`GET /api/v1/users/usage`). Open WebUI has no plans or quotas;
/// these are the lifetime numbers Theseus shows instead of Billing.
public struct UsageStats: Sendable, Equatable, Decodable {
    public struct Totals: Sendable, Equatable, Decodable {
        public let lifetimeTokens: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let chats: Int
        public let messages: Int
        public let activeDays: Int
        public let currentStreak: Int
        public let longestStreak: Int
        public let modelsUsed: Int

        enum CodingKeys: String, CodingKey {
            case messages
            case lifetimeTokens = "lifetime_tokens"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case chats = "total_chats"
            case activeDays = "active_days"
            case currentStreak = "current_streak"
            case longestStreak = "longest_streak"
            case modelsUsed = "models_used"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func int(_ key: CodingKeys) throws -> Int {
                Int(try container.decodeIfPresent(Double.self, forKey: key) ?? 0)
            }
            lifetimeTokens = try int(.lifetimeTokens)
            inputTokens = try int(.inputTokens)
            outputTokens = try int(.outputTokens)
            chats = try int(.chats)
            messages = try int(.messages)
            activeDays = try int(.activeDays)
            currentStreak = try int(.currentStreak)
            longestStreak = try int(.longestStreak)
            modelsUsed = try int(.modelsUsed)
        }
    }

    public struct ModelUsage: Sendable, Equatable, Decodable, Identifiable {
        public let modelID: String
        public let messages: Int
        public let totalTokens: Int

        public var id: String { modelID }

        enum CodingKeys: String, CodingKey {
            case messages
            case modelID = "model_id"
            case totalTokens = "total_tokens"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelID = try container.decode(String.self, forKey: .modelID)
            messages = Int(try container.decodeIfPresent(Double.self, forKey: .messages) ?? 0)
            totalTokens = Int(try container.decodeIfPresent(Double.self, forKey: .totalTokens) ?? 0)
        }
    }

    public let totals: Totals
    public let topModels: [ModelUsage]
    /// The length of the reporting period in days (the server defaults to two years).
    public let periodDays: Int?

    enum CodingKeys: String, CodingKey {
        case totals, period
        case topModels = "top_models"
    }

    private struct Period: Decodable {
        let days: Int?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totals = try container.decode(Totals.self, forKey: .totals)
        topModels = try container.decodeIfPresent([ModelUsage].self, forKey: .topModels) ?? []
        periodDays = try container.decodeIfPresent(Period.self, forKey: .period)?.days
    }
}

extension Endpoint where Response == UsageStats {
    /// `GET /api/v1/users/usage`: the Account's own usage over the server's default period.
    public static var usage: Self {
        Endpoint(method: .get, path: "api/v1/users/usage", authentication: .required)
    }
}

// MARK: Admin contact (SET-07, SET-10)

/// Who runs the Server (`GET /api/v1/auths/admin/details`). Only available when the admin
/// enabled `SHOW_ADMIN_DETAILS`; otherwise the server answers 400.
public struct AdminContact: Sendable, Equatable, Decodable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }
}

extension Endpoint where Response == AdminContact {
    /// `GET /api/v1/auths/admin/details`.
    public static var adminContact: Self {
        Endpoint(method: .get, path: "api/v1/auths/admin/details", authentication: .optional)
    }
}

// MARK: Shared links (SET-08)

/// A Chat the Account shared as a link (`SharedChatResponse`). The link is a snapshot taken when
/// it was shared; `updatedAt` is when that happened.
public struct SharedChatLink: Sendable, Hashable, Identifiable, Decodable {
    public let chatID: String
    public let shareID: String
    public let title: String
    public let updatedAt: Date
    public let createdAt: Date

    public var id: String { chatID }

    public init(chatID: String, shareID: String, title: String, updatedAt: Date, createdAt: Date) {
        self.chatID = chatID
        self.shareID = shareID
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    /// The public web URL of the snapshot (`{server}/s/{share_id}`).
    public func url(server: URL) -> URL {
        server.appending(path: "s").appending(path: shareID)
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case chatID = "chat_id"
        case shareID = "share_id"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID) ?? container.decode(String.self, forKey: .id)
        shareID = try container.decode(String.self, forKey: .shareID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        updatedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .updatedAt))
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
    }
}

/// The read-only snapshot behind a Shared link: the title and the active path of its Message tree.
public struct SharedChatSnapshot: Sendable, Equatable {
    public let title: String
    public let messages: [Message]
    /// The name on the first user Message, when the server recorded it.
    public let sharedByName: String?
    public let updatedAt: Date

    public init(title: String, messages: [Message], sharedByName: String?, updatedAt: Date) {
        self.title = title
        self.messages = messages
        self.sharedByName = sharedByName
        self.updatedAt = updatedAt
    }
}

extension Endpoint where Response == [SharedChatLink] {
    /// `GET /api/v1/chats/shared?page=`: the Account's Shared links, most recently shared first.
    public static func sharedChats(page: Int) -> Self {
        Endpoint(
            method: .get,
            path: "api/v1/chats/shared",
            query: [URLQueryItem(name: "page", value: String(max(page, 1)))],
            authentication: .required
        )
    }
}

extension Endpoint where Response == SharedChatSnapshot {
    /// `GET /api/v1/chats/share/{share_id}`: the snapshot as others see it.
    public static func sharedChatSnapshot(shareID: String) -> Self {
        Endpoint(method: .get, path: "api/v1/chats/share/\(shareID)", authentication: .required) { data in
            try WireCoding.decoder.decode(SharedSnapshotWire.self, from: data).domain
        }
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/chats/{id}/share`: deletes the Shared link; the Chat itself stays.
    public static func unshareChat(chatID: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/chats/\(chatID)/share", authentication: .required) { data in
            (try? WireCoding.decoder.decode(Bool.self, from: data)) ?? true
        }
    }

    /// `DELETE /api/v1/chats/share/all`: deletes every Shared link of the Account.
    public static var unshareAllChats: Self {
        Endpoint(method: .delete, path: "api/v1/chats/share/all", authentication: .required) { data in
            (try? WireCoding.decoder.decode(Bool.self, from: data)) ?? true
        }
    }
}

/// The subset of a shared `ChatResponse` the snapshot view needs.
private struct SharedSnapshotWire: Decodable {
    struct Body: Decodable {
        let title: String?
        let history: History?
    }

    struct History: Decodable {
        let currentId: String?
        let messages: [String: MessageWire]?
    }

    struct MessageWire: Decodable {
        struct Author: Decodable {
            let name: String?
        }

        let id: String
        let parentId: String?
        let childrenIds: [String]?
        let role: String
        let content: String?
        let model: String?
        let timestamp: Double?
        let user: Author?
    }

    let title: String?
    let chat: Body?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case title, chat
        case updatedAt = "updated_at"
    }

    var domain: SharedChatSnapshot {
        let wires = chat?.history?.messages ?? [:]
        let messages = wires.values.compactMap { wire -> Message? in
            guard let role = Message.Role(rawValue: wire.role) else { return nil }
            return Message(
                id: wire.id,
                parentID: wire.parentId,
                childIDs: wire.childrenIds ?? [],
                role: role,
                content: wire.content ?? "",
                modelID: wire.model,
                createdAt: Date(timeIntervalSince1970: wire.timestamp ?? 0)
            )
        }
        let tree = MessageTree(messages: messages, currentID: chat?.history?.currentId)
        let path = tree.activePath
        let author = path.first { $0.role == .user }.flatMap { wires[$0.id]?.user?.name }
        return SharedChatSnapshot(
            title: title ?? chat?.title ?? "",
            messages: path,
            sharedByName: author,
            updatedAt: Date(timeIntervalSince1970: updatedAt ?? 0)
        )
    }
}
