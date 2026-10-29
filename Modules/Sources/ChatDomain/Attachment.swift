/// A file, photo or camera capture the user added to a Message (CONTEXT.md: Attachment).
public struct Attachment: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Shown as a thumbnail; reaches vision models as an image.
        case image
        /// Shown as a file card; the server extracts its text for retrieval.
        case document
    }

    /// The server file id (`/api/v1/files/{id}`), or a synthetic id for inline images.
    public let id: String
    public var name: String
    public var kind: Kind
    public var contentType: String?
    /// Bytes, when known.
    public var size: Int?
    /// An inline `data:` URL (incognito images) or external URL; `nil` for server files.
    public var url: String?

    public init(id: String, name: String, kind: Kind, contentType: String? = nil, size: Int? = nil, url: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.url = url
    }

    /// `true` when the bytes live on the Server (`GET /api/v1/files/{id}/content`).
    public var isServerFile: Bool { url == nil }

    /// A short type badge for file cards ("PDF", "TXT", "DOCX").
    public var typeBadge: String {
        let ext = name.split(separator: ".").count > 1 ? name.split(separator: ".").last.map(String.init) : nil
        if let ext, !ext.isEmpty, ext.count <= 5 { return ext.uppercased() }
        if let subtype = contentType?.split(separator: "/").last, !subtype.isEmpty {
            return String(subtype.prefix(5)).uppercased()
        }
        return "FILE"
    }
}
