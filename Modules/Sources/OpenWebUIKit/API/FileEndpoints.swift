public import Foundation

// Attachment helpers on top of `Files.swift` (docs/research/open-webui-api.md §7.1): the bytes to
// upload, the Message's file reference, raw content, deletion, and the Server's banners.

/// Bytes to upload as one Attachment.
public struct FileUpload: Sendable, Equatable {
    public var data: Data
    public var filename: String
    public var contentType: String

    public init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

extension UploadedFile {
    /// The reference a user Message carries for this file.
    public var reference: FileReference {
        FileReference(id: id, name: name, contentType: contentType, size: size, collectionName: collectionName)
    }
}

/// An uploaded file as a user Message references it (`user_message.files[]`, `type: "file"`).
/// Images are recognised by their `image/*` content type and stay on the Message only;
/// documents also go into the request's top-level `files` for retrieval.
public struct FileReference: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var contentType: String?
    public var size: Int?
    public var collectionName: String?
    /// Set when the file was put into the Chat's sandbox instead of the Server's file store
    /// (`chat_uploads: "filesystem"`, OT-05): the model reads it there, so it skips retrieval.
    public var sandbox: SandboxPlacement?

    public init(id: String, name: String, contentType: String?, size: Int?, collectionName: String? = nil, sandbox: SandboxPlacement? = nil) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.collectionName = collectionName
        self.sandbox = sandbox
    }

    public var isImage: Bool {
        contentType?.lowercased().hasPrefix("image/") ?? false
    }

    /// The wire shape the web client sends (`MessageInput.svelte` file items).
    public var jsonValue: JSONValue {
        if let sandbox {
            // A `filesystem` reference (F/lib/apis/terminal/index.ts): the path in the sandbox.
            var object: [String: JSONValue] = [
                "type": .string("filesystem"),
                "id": .string(sandbox.path),
                "path": .string(sandbox.path),
                "url": .string(sandbox.path),
                "name": .string(name),
                "status": .string("processed"),
                "terminal_id": .string(sandbox.terminalID),
                "session_id": sandbox.sessionID.map(JSONValue.string) ?? .null,
            ]
            if let size { object["size"] = .number(Double(size)) }
            return .object(object)
        }
        var object: [String: JSONValue] = [
            "type": .string("file"),
            "id": .string(id),
            "url": .string(id),
            "name": .string(name),
            "status": .string("uploaded"),
            "collection_name": .string(collectionName ?? ""),
        ]
        if let contentType { object["content_type"] = .string(contentType) }
        if let size { object["size"] = .number(Double(size)) }
        return .object(object)
    }
}

/// Where an Attachment landed in a Chat's sandbox (OT-05).
public struct SandboxPlacement: Sendable, Hashable {
    public var terminalID: String
    /// The absolute path in the sandbox.
    public var path: String
    /// The Chat (sandbox session) it was uploaded for; `nil` before a new Chat has its id.
    public var sessionID: String?

    public init(terminalID: String, path: String, sessionID: String?) {
        self.terminalID = terminalID
        self.path = path
        self.sessionID = sessionID
    }
}

/// A server-wide notice from the admin (`GET /api/v1/configs/banners`).
public struct ServerBanner: Sendable, Equatable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case info
        case success
        case warning
        case error
    }

    public let id: String
    public let kind: Kind
    public let title: String?
    public let content: String
    public let isDismissible: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, title, content, dismissible
    }

    public init(id: String, kind: Kind, title: String? = nil, content: String, isDismissible: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.isDismissible = isDismissible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(rawValue: (try container.decodeIfPresent(String.self, forKey: .type) ?? "info").lowercased()) ?? .info
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        isDismissible = try container.decodeIfPresent(Bool.self, forKey: .dismissible) ?? true
    }
}

extension Endpoint where Response == Data {
    /// `GET /api/v1/files/{id}/content`: the raw bytes (thumbnails and previews).
    public static func fileContent(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/files/\(id)/content", returnsJSON: false, authentication: .required) { $0 }
    }
}

extension Endpoint where Response == JSONValue {
    /// `DELETE /api/v1/files/{id}`: drops an upload the user removed before sending.
    public static func deleteFile(id: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/files/\(id)", authentication: .required)
    }
}

extension Endpoint where Response == [ServerBanner] {
    /// `GET /api/v1/configs/banners`: the admin's banners for this user.
    public static var banners: Self {
        Endpoint(method: .get, path: "api/v1/configs/banners", authentication: .required)
    }
}
