public import Foundation

// Files (`/api/v1/files`, docs/research/open-webui-api.md §7.1): upload, processing status and
// details. Used for Project Knowledge (PROJ-05); Attachments (ATT-*) can reuse them.

/// A file stored on the Server (`FileModel`).
public struct UploadedFile: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var size: Int?
    public var contentType: String?
    /// The vector collection the server built while processing; `nil` until processing finished.
    public var collectionName: String?

    public init(id: String, name: String, size: Int? = nil, contentType: String? = nil, collectionName: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.contentType = contentType
        self.collectionName = collectionName
    }
}

/// Where the server is in extracting and embedding an upload.
public enum FileProcessingStatus: Sendable, Hashable {
    case pending
    case completed
    /// Processing failed; the server's reason, if it gave one.
    case failed(String?)
}

extension Endpoint where Response == UploadedFile {
    /// `POST /api/v1/files/?process=true&process_in_background=true` as `multipart/form-data`.
    /// Processing continues on the server; poll `fileProcessingStatus(id:)` until it settles.
    /// Images for vision models upload with `process: false` (stored only, ATT-02).
    public static func uploadFile(filename: String, contentType: String, data: Data, process: Bool = true) -> Self {
        let boundary = "theseus-\(UUID().uuidString)"
        // Quotes and line breaks would break the part header.
        let safeName = filename.filter { $0 != "\"" && !$0.isNewline }
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return Endpoint(
            method: .post,
            path: "api/v1/files/",
            query: process
                ? [URLQueryItem(name: "process", value: "true"), URLQueryItem(name: "process_in_background", value: "true")]
                : [URLQueryItem(name: "process", value: "false")],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authentication: .required,
            decode: FileWire.decode
        )
    }

    /// `GET /api/v1/files/{id}`: metadata, including the collection name once processed.
    public static func fileDetails(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/files/\(id)", authentication: .required, decode: FileWire.decode)
    }
}

extension Endpoint where Response == FileProcessingStatus {
    /// `GET /api/v1/files/{id}/process/status` (the non-streaming form).
    public static func fileProcessingStatus(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/files/\(id)/process/status", authentication: .required) { data in
            let json = try WireCoding.decoder.decode(JSONValue.self, from: data)
            switch json[path: "status"]?.stringValue {
            case "completed": return .completed
            case "failed": return .failed(json[path: "error"]?.stringValue)
            default: return .pending
            }
        }
    }
}

/// `FileModel` (`B/models/files.py`).
private struct FileWire: Decodable {
    struct Meta: Decodable {
        let name: String?
        let contentType: String?
        let size: Int?
        let collectionName: String?

        enum CodingKeys: String, CodingKey {
            case name, size
            case contentType = "content_type"
            case collectionName = "collection_name"
        }
    }

    let id: String
    let filename: String?
    let meta: Meta?

    @Sendable static func decode(_ data: Data) throws -> UploadedFile {
        let wire = try WireCoding.decoder.decode(FileWire.self, from: data)
        return UploadedFile(
            id: wire.id,
            name: wire.meta?.name ?? wire.filename ?? "File",
            size: wire.meta?.size,
            contentType: wire.meta?.contentType,
            collectionName: wire.meta?.collectionName
        )
    }
}
