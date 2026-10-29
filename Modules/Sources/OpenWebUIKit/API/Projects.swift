public import ChatDomain
public import Foundation

// Projects (server term: folders, `/api/v1/folders`) — docs/research/open-webui-api.md §9.8.
// Theseus-only fields (description, starred, archived) live under `folder.meta.theseus` (ADR 0020).

/// A Project: a named workspace that groups Chats and adds Instructions and Knowledge to them.
/// Server term: folder.
public struct Project: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    /// The enclosing folder, for folders nested in the web client. Theseus shows Projects flat.
    public var parentID: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Theseus-owned metadata (`meta.theseus`). Empty until `hasDetails`.
    public var metadata: ProjectMetadata
    /// Project Instructions (server term: `data.system_prompt`). Empty until `hasDetails`.
    public var instructions: String
    /// Knowledge files (server term: `data.files`). Empty until `hasDetails`.
    public var knowledge: [KnowledgeFile]
    /// `false` for rows of the Projects list endpoint, which leaves out `meta` and `data`; load
    /// `projectDetails(id:)` before trusting `metadata`, `instructions` or `knowledge`.
    public var hasDetails: Bool

    public init(
        id: String,
        name: String,
        parentID: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        metadata: ProjectMetadata = ProjectMetadata(),
        instructions: String = "",
        knowledge: [KnowledgeFile] = [],
        hasDetails: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
        self.instructions = instructions
        self.knowledge = knowledge
        self.hasDetails = hasDetails
    }

    public var isStarred: Bool { metadata.isStarred }
    public var isArchived: Bool { metadata.isArchived }
}

/// The client-defined Project fields Open WebUI has no column for, stored in `folder.meta.theseus`
/// (catalog: PROJ-02/07/08). The server merges `meta` one level deep, so this object is always
/// written whole; `extras` keeps keys a newer Theseus may have added.
public struct ProjectMetadata: Sendable, Hashable {
    /// What the user is trying to achieve (the create sheet's second question).
    public var description: String
    public var isStarred: Bool
    /// Archived Projects are hidden from the default Projects list (client-side filter).
    public var isArchived: Bool
    /// Unknown keys inside `meta.theseus`, sent back unchanged.
    public var extras: [String: JSONValue]

    public init(description: String = "", isStarred: Bool = false, isArchived: Bool = false, extras: [String: JSONValue] = [:]) {
        self.description = description
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.extras = extras
    }

    init(json: JSONValue?) {
        var object = json?.objectValue ?? [:]
        description = object.removeValue(forKey: "description")?.stringValue ?? ""
        isStarred = object.removeValue(forKey: "starred")?.boolValue ?? false
        isArchived = object.removeValue(forKey: "archived")?.boolValue ?? false
        extras = object
    }

    /// The `meta.theseus` object. Defaults are left out so untouched Projects stay clean.
    var json: JSONValue {
        var object = extras
        if !description.isEmpty { object["description"] = .string(description) }
        if isStarred { object["starred"] = .bool(true) }
        if isArchived { object["archived"] = .bool(true) }
        return .object(object)
    }
}

/// One Knowledge file of a Project. `reference` is the server's file reference as stored in
/// `folder.data.files`; Theseus sends it back unchanged when the list changes.
public struct KnowledgeFile: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var size: Int?
    public var contentType: String?
    public var reference: JSONValue

    init?(reference: JSONValue) {
        guard let id = reference[path: "id"]?.stringValue else { return nil }
        self.id = id
        self.reference = reference
        name = reference[path: "name"]?.stringValue ?? reference[path: "file.filename"]?.stringValue ?? "File"
        if case .number(let size) = reference[path: "size"] { self.size = Int(size) } else { size = nil }
        contentType = reference[path: "content_type"]?.stringValue
    }

    /// A document reference for a processed upload (the shape the server's retrieval expects,
    /// docs/research/open-webui-api.md §7.1).
    public init(uploaded file: UploadedFile) {
        id = file.id
        name = file.name
        size = file.size
        contentType = file.contentType
        var object: [String: JSONValue] = [
            "type": .string("file"),
            "id": .string(file.id),
            "url": .string(file.id),
            "name": .string(file.name),
            "status": .string("uploaded"),
        ]
        if let size = file.size { object["size"] = .number(Double(size)) }
        if let contentType = file.contentType { object["content_type"] = .string(contentType) }
        if let collection = file.collectionName { object["collection_name"] = .string(collection) }
        reference = .object(object)
    }
}

/// A partial Project update (`POST /api/v1/folders/{id}/update`). `nil` fields are left alone.
public struct ProjectUpdate: Sendable, Hashable {
    public var name: String?
    /// Replaces `meta.theseus` as a whole.
    public var metadata: ProjectMetadata?
    public var instructions: String?
    /// Replaces `data.files` as a whole.
    public var knowledge: [KnowledgeFile]?

    public init(
        name: String? = nil,
        metadata: ProjectMetadata? = nil,
        instructions: String? = nil,
        knowledge: [KnowledgeFile]? = nil
    ) {
        self.name = name
        self.metadata = metadata
        self.instructions = instructions
        self.knowledge = knowledge
    }

    var json: JSONValue {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let metadata { body["meta"] = .object(["theseus": metadata.json]) }
        var data: [String: JSONValue] = [:]
        if let instructions { data["system_prompt"] = .string(instructions) }
        if let knowledge { data["files"] = .array(knowledge.map(\.reference)) }
        if !data.isEmpty { body["data"] = .object(data) }
        return .object(body)
    }
}

// MARK: - Endpoints

extension Endpoint where Response == [Project] {
    /// `GET /api/v1/folders/`: every Project of the Account. Rows have no details (see `Project.hasDetails`).
    public static var projects: Self {
        Endpoint(method: .get, path: "api/v1/folders/", authentication: .required) { data in
            try WireCoding.decoder.decode([ProjectWire].self, from: data).map { $0.domain(hasDetails: false) }
        }
    }
}

extension Endpoint where Response == Project {
    /// `GET /api/v1/folders/{id}`: one Project with its metadata, Instructions and Knowledge.
    public static func projectDetails(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/folders/\(id)", authentication: .required, decode: ProjectWire.decodeDetails)
    }

    /// `POST /api/v1/folders/` with `{name, meta:{theseus:{description}}}`. The server refuses a
    /// name that's already taken (400 "Folder already exists").
    public static func createProject(name: String, description: String) -> Self {
        var body: [String: JSONValue] = ["name": .string(name)]
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            body["meta"] = .object(["theseus": ProjectMetadata(description: description).json])
        }
        return Endpoint(
            method: .post,
            path: "api/v1/folders/",
            body: try? WireCoding.encoder.encode(JSONValue.object(body)),
            authentication: .required,
            decode: ProjectWire.decodeDetails
        )
    }

    /// `POST /api/v1/folders/{id}/update`: name, `meta.theseus` and `data` keys merge one level
    /// deep on the server, so only the parts in `update` change.
    public static func updateProject(id: String, _ update: ProjectUpdate) -> Self {
        Endpoint(
            method: .post,
            path: "api/v1/folders/\(id)/update",
            body: try? WireCoding.encoder.encode(update.json),
            authentication: .required,
            decode: ProjectWire.decodeDetails
        )
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/folders/{id}?delete_contents=`: with `deleteChats` the Project's Chats are
    /// deleted too; otherwise the server moves them out of the Project.
    public static func deleteProject(id: String, deleteChats: Bool) -> Self {
        Endpoint(
            method: .delete,
            path: "api/v1/folders/\(id)",
            query: [URLQueryItem(name: "delete_contents", value: deleteChats ? "true" : "false")],
            authentication: .required
        )
    }
}

extension Endpoint where Response == [ChatSummary] {
    /// `GET /api/v1/chats/folder/{id}/list?page=`: the Project's Chats, newest first, 10 per page.
    public static func projectChats(projectID: String, page: Int) -> Self {
        Endpoint(
            method: .get,
            path: "api/v1/chats/folder/\(projectID)/list",
            query: [URLQueryItem(name: "page", value: String(max(page, 1)))],
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode([ChatSummaryWire].self, from: data).map { wire in
                var chat = wire.domain
                chat.projectID = projectID
                return chat
            }
        }
    }

    /// The server's page size for `projectChats(projectID:page:)`.
    public static var projectChatsPageSize: Int { 10 }
}

extension Endpoint where Response == ChatSummary {
    /// `POST /api/v1/chats/{id}/folder` with `{folder_id}`: moves a Chat into a Project, or out of
    /// every Project with `nil`.
    public static func moveChat(id: String, toProject projectID: String?) -> Self {
        let body: JSONValue = .object(["folder_id": projectID.map(JSONValue.string) ?? .null])
        return Endpoint(
            method: .post,
            path: "api/v1/chats/\(id)/folder",
            body: try? WireCoding.encoder.encode(body),
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode(MovedChatWire.self, from: data).domain
        }
    }
}

// MARK: - Wire shapes

/// `FolderModel` / `FolderNameIdResponse` (`B/models/folders.py`). Timestamps are epoch seconds.
private struct ProjectWire: Decodable {
    let id: String
    let name: String
    let parentID: String?
    let meta: JSONValue?
    let data: JSONValue?
    let createdAt: Double
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, meta, data
        case parentID = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    @Sendable static func decodeDetails(_ data: Data) throws -> Project {
        try WireCoding.decoder.decode(ProjectWire.self, from: data).domain(hasDetails: true)
    }

    func domain(hasDetails: Bool) -> Project {
        let files = data?[path: "files"]
        var knowledge: [KnowledgeFile] = []
        if case .array(let references) = files {
            knowledge = references.compactMap(KnowledgeFile.init(reference:))
        }
        return Project(
            id: id,
            name: name,
            parentID: parentID,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            metadata: ProjectMetadata(json: meta?[path: "theseus"]),
            instructions: data?[path: "system_prompt"]?.stringValue ?? "",
            knowledge: knowledge,
            hasDetails: hasDetails
        )
    }
}

/// The list-relevant subset of `ChatResponse` after a move.
private struct MovedChatWire: Decodable {
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
