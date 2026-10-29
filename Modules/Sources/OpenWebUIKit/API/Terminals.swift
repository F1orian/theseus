public import Foundation

// Open Terminal (epic #139, ADR 0120): the Server's sandbox. Open WebUI lists the terminal servers
// an Account may use and reverse-proxies requests to them at `/api/v1/terminals/{id}/…`, adding the
// terminal's own key server-side. Theseus only ever sends its Session token
// (docs/research/open-terminal.md §3.5).

/// One terminal server the Account may use (`GET /api/v1/terminals/`). Server term: terminal
/// server; in UI copy it's the Chat's sandbox.
public struct TerminalServer: Sendable, Equatable, Identifiable, Decodable {
    /// How Attachments reach the model when this terminal backs a Chat (`config.chat_uploads`).
    public enum UploadMode: Sendable, Equatable {
        /// The normal upload pipeline (`/api/v1/files/`, retrieval).
        case `default`
        /// Into the sandbox's file system (`files/upload`, a `filesystem` file reference, OT-05).
        case filesystem
        case other(String)

        init(_ raw: String?) {
            switch raw ?? "default" {
            case "default": self = .default
            case "filesystem": self = .filesystem
            case let other: self = .other(other)
            }
        }
    }

    public let id: String
    public let name: String
    public let uploadMode: UploadMode

    public init(id: String, name: String, uploadMode: UploadMode = .default) {
        self.id = id
        self.name = name
        self.uploadMode = uploadMode
    }

    private enum CodingKeys: String, CodingKey { case id, name, config }
    private struct Config: Decodable {
        let chatUploads: String?
        enum CodingKeys: String, CodingKey { case chatUploads = "chat_uploads" }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        self.name = (name?.isEmpty ?? true) ? id : name ?? id
        let config = (try? container.decodeIfPresent(Config.self, forKey: .config)) ?? nil
        uploadMode = UploadMode(config?.chatUploads)
    }
}

/// `GET /files/cwd` through the proxy: the session's working directory and the browsing root.
public struct SandboxLocation: Sendable, Equatable, Decodable {
    public let cwd: String
    public let home: String?
    /// The top the file browser may show (`root.path`), with its label ("Home").
    public let rootPath: String?
    public let rootLabel: String?

    public init(cwd: String, home: String? = nil, rootPath: String? = nil, rootLabel: String? = nil) {
        self.cwd = cwd
        self.home = home
        self.rootPath = rootPath
        self.rootLabel = rootLabel
    }

    private enum CodingKeys: String, CodingKey { case cwd, home, root }
    private struct Root: Decodable {
        let path: String?
        let label: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decode(String.self, forKey: .cwd)
        home = (try? container.decodeIfPresent(String.self, forKey: .home)) ?? nil
        let root = (try? container.decodeIfPresent(Root.self, forKey: .root)) ?? nil
        rootPath = root?.path
        rootLabel = root?.label
    }
}

/// `GET /files/list`: one directory of the sandbox.
public struct SandboxDirectory: Sendable, Equatable, Decodable {
    public struct Entry: Sendable, Equatable, Identifiable, Decodable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int?
        public let modified: Date?

        public var id: String { name }

        public init(name: String, isDirectory: Bool, size: Int? = nil, modified: Date? = nil) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modified = modified
        }

        private enum CodingKeys: String, CodingKey { case name, type, size, modified }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            isDirectory = ((try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil) == "directory"
            size = ((try? container.decodeIfPresent(Double.self, forKey: .size)) ?? nil).map { Int($0) }
            modified = ((try? container.decodeIfPresent(Double.self, forKey: .modified)) ?? nil).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// The absolute path that was listed.
    public let path: String
    public let entries: [Entry]

    public init(path: String, entries: [Entry]) {
        self.path = path
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case path = "dir"
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        entries = (try? container.decodeIfPresent([Entry].self, forKey: .entries)) ?? []
    }
}

/// `GET /files/matches`: sandbox files whose name (or content) matches a query.
public struct SandboxSearchResult: Sendable, Equatable, Identifiable, Decodable {
    public let path: String
    public let name: String
    public let isDirectory: Bool

    public var id: String { path }

    private enum CodingKeys: String, CodingKey { case path, name, type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? (path as NSString).lastPathComponent
        isDirectory = ((try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil) == "directory"
    }
}

private struct SandboxSearchPage: Decodable {
    let results: [SandboxSearchResult]?
}

/// `POST /files/upload`: where an upload landed in the sandbox.
public struct SandboxUpload: Sendable, Equatable, Decodable {
    public let path: String
    public let size: Int?

    private enum CodingKeys: String, CodingKey { case path, size }

    public init(path: String, size: Int?) {
        self.path = path
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        size = ((try? container.decodeIfPresent(Double.self, forKey: .size)) ?? nil).map { Int($0) }
    }
}

extension Endpoint where Response == [TerminalServer] {
    /// `GET /api/v1/terminals/`: the enabled terminal servers this Account may use (never their keys).
    /// Empty when the Server turns tool servers off.
    public static var terminals: Self {
        Endpoint(method: .get, path: "api/v1/terminals/", authentication: .required)
    }
}

/// The proxy route for one Chat's sandbox session. Open WebUI turns `chats/{chat_id}` into the
/// terminal's `X-Session-Id`, which scopes the working directory and processes to the Chat, so
/// browsing sees what the model saw (B/routers/terminals.py).
private func sandboxPath(_ terminalID: String, chatID: String?, _ path: String) -> String {
    guard let chatID else { return "api/v1/terminals/\(terminalID)/\(path)" }
    return "api/v1/terminals/\(terminalID)/chats/\(chatID)/\(path)"
}

extension Endpoint where Response == SandboxLocation {
    /// `GET …/files/cwd`: the Chat's working directory (`chatID: nil`: the terminal's default, for a
    /// Chat the Server hasn't created yet).
    public static func sandboxLocation(terminalID: String, chatID: String?) -> Self {
        Endpoint(method: .get, path: sandboxPath(terminalID, chatID: chatID, "files/cwd"), authentication: .required)
    }
}

extension Endpoint where Response == SandboxDirectory {
    /// `GET …/files/list?directory=`.
    public static func sandboxDirectory(terminalID: String, chatID: String, path: String) -> Self {
        Endpoint(
            method: .get,
            path: sandboxPath(terminalID, chatID: chatID, "files/list"),
            query: [URLQueryItem(name: "directory", value: path)],
            authentication: .required
        )
    }
}

extension Endpoint where Response == [SandboxSearchResult] {
    /// `GET …/files/matches?query=&path=`: name matches under `path`.
    public static func sandboxSearch(terminalID: String, chatID: String, query: String, path: String) -> Self {
        Endpoint(
            method: .get,
            path: sandboxPath(terminalID, chatID: chatID, "files/matches"),
            query: [URLQueryItem(name: "query", value: query), URLQueryItem(name: "path", value: path)],
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode(SandboxSearchPage.self, from: data).results ?? []
        }
    }
}

extension Endpoint where Response == Data {
    /// `GET …/files/view?path=`: a sandbox file's bytes. `preview: true` asks for a PDF rendering of
    /// Office documents when the terminal can make one.
    public static func sandboxFile(terminalID: String, chatID: String, path: String, preview: Bool = false) -> Self {
        var query = [URLQueryItem(name: "path", value: path)]
        if preview { query.append(URLQueryItem(name: "preview", value: "true")) }
        return Endpoint(
            method: .get,
            path: sandboxPath(terminalID, chatID: chatID, "files/view"),
            query: query,
            returnsJSON: false,
            authentication: .required
        ) { $0 }
    }

    /// `POST …/files/archive {paths}`: the given files and folders as one ZIP.
    public static func sandboxArchive(terminalID: String, chatID: String, paths: [String]) -> Self {
        let body = try? WireCoding.encoder.encode(JSONValue.object(["paths": .array(paths.map(JSONValue.string))]))
        return Endpoint(
            method: .post,
            path: sandboxPath(terminalID, chatID: chatID, "files/archive"),
            body: body ?? Data(),
            returnsJSON: false,
            authentication: .required
        ) { $0 }
    }
}

extension Endpoint where Response == SandboxUpload {
    /// `POST …/files/upload?directory=` (multipart `file`): puts an Attachment into the sandbox (OT-05).
    public static func sandboxUpload(terminalID: String, chatID: String?, directory: String, filename: String, contentType: String, data: Data) -> Self {
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
            path: sandboxPath(terminalID, chatID: chatID, "files/upload"),
            query: [URLQueryItem(name: "directory", value: directory)],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authentication: .required
        )
    }
}
