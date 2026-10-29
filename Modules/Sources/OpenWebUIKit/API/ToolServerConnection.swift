public import Foundation

/// One tool-server connection, as Open WebUI stores it in two places (#186):
///
/// - **Shared connectors** (admin): `TOOL_SERVER_CONNECTIONS`, the Server's config
///   (`GET/POST /api/v1/configs/tool_servers`, `ToolServerConnection` in `B/routers/configs.py`).
/// - **Personal connectors**: the user's *direct tool servers* at `ui.toolServers` in the user
///   settings, keys included, exactly as the web client stores them; the client calls them itself
///   (`execute:tool`: the browser on the web, the device in Theseus; ADR 0095 as amended by #189).
///
/// The wire object is free-form (`extra='allow'`), so the connection keeps every field as
/// `JSONValue` and the typed properties read and write through it: entries written by the web
/// admin or a newer Server round-trip unchanged.
public struct ToolServerConnection: Sendable, Equatable, Identifiable {
    /// `type`: how Open WebUI talks to the server.
    public enum ServerType: String, Sendable, CaseIterable {
        /// An OpenAPI server; its spec lives at `path` (default `openapi.json`).
        case openAPI = "openapi"
        /// An MCP server over Streamable HTTP.
        case mcp
    }

    /// `auth_type`. Theseus offers `none`, `bearer`, `session` and `oauth21`; the rest are kept
    /// as they are when an entry made in the web admin is edited.
    public enum AuthType: Sendable, Hashable {
        /// No `Authorization` header.
        case none
        /// `Authorization: Bearer <key>`.
        case bearer
        /// Forwards the signed-in user's Open WebUI Session token.
        case session
        /// Forwards the user's single sign-on access token (`system_oauth`).
        case systemOAuth
        /// MCP only: OAuth 2.1 with dynamic client registration; each user connects (ADR 0090).
        case oauth21
        /// MCP only: OAuth 2.1 with a static client id and secret.
        case oauth21Static
        case other(String)

        public init(wire: String?) {
            switch wire {
            case nil, "none": self = .none
            case "bearer": self = .bearer
            case "session": self = .session
            case "system_oauth": self = .systemOAuth
            case "oauth_2.1": self = .oauth21
            case "oauth_2.1_static": self = .oauth21Static
            case let other?: self = .other(other)
            }
        }

        public var wireValue: String {
            switch self {
            case .none: "none"
            case .bearer: "bearer"
            case .session: "session"
            case .systemOAuth: "system_oauth"
            case .oauth21: "oauth_2.1"
            case .oauth21Static: "oauth_2.1_static"
            case .other(let value): value
            }
        }

        /// Users sign in to the server themselves (the Connect sheet).
        public var isOAuth21: Bool { self == .oauth21 || self == .oauth21Static }
    }

    /// The stored object, unknown fields included.
    public private(set) var raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    // MARK: Identity

    /// `info.id` when set, otherwise the URL (personal connectors and some OpenAPI entries from
    /// the web admin have no id).
    public var id: String {
        let infoID = serverID
        return infoID.isEmpty ? "url:\(url)|\(path)" : infoID
    }

    /// `info.id`: the server id behind `server:<id>` / `server:mcp:<id>` tool ids. Never contains
    /// `:` or `|` (the Server splits on them).
    public var serverID: String {
        get { info["id"]?.stringValue ?? "" }
        set { info["id"] = .string(newValue) }
    }

    // MARK: Fields

    public var type: ServerType {
        get { raw["type"]?.stringValue.flatMap(ServerType.init(rawValue:)) ?? .openAPI }
        set { raw["type"] = .string(newValue.rawValue) }
    }

    public var url: String {
        get { raw["url"]?.stringValue ?? "" }
        set { raw["url"] = .string(newValue) }
    }

    /// OpenAPI: where the spec is, relative to `url` (or a full URL).
    public var path: String {
        get { raw["path"]?.stringValue ?? "" }
        set { raw["path"] = .string(newValue) }
    }

    public var authType: AuthType {
        get { AuthType(wire: raw["auth_type"]?.stringValue) }
        set { raw["auth_type"] = .string(newValue.wireValue) }
    }

    /// The bearer key as stored: in `TOOL_SERVER_CONNECTIONS` for shared connections, in the user
    /// settings for personal connectors (like the web client, #189).
    public var key: String {
        get { raw["key"]?.stringValue ?? "" }
        set { raw["key"] = .string(newValue) }
    }

    public var name: String {
        get { info["name"]?.stringValue ?? "" }
        set { info["name"] = .string(newValue) }
    }

    public var description: String {
        get { info["description"]?.stringValue ?? "" }
        set { info["description"] = .string(newValue) }
    }

    /// `config.enable`: whether the Server (or the client, for personal connectors) uses it.
    public var isEnabled: Bool {
        get { config["enable"]?.boolValue ?? false }
        set { config["enable"] = .bool(newValue) }
    }

    /// `config.access_grants`: who may use a shared connection. Empty means admins only.
    public var access: ToolServerAccess {
        get { ToolServerAccess(grants: config["access_grants"]?.arrayValue ?? []) }
        set { config["access_grants"] = .array(newValue.grants) }
    }

    /// `info.oauth_client_info`: the encrypted client the Server registered (OAuth 2.1 MCP).
    public var oauthClientInfo: String? {
        get { info["oauth_client_info"]?.stringValue }
        set { info["oauth_client_info"] = newValue.map(JSONValue.string) }
    }

    /// `info.oauth_client_id` (`oauth_2.1_static`): the client id of the OAuth app the admin created
    /// at the provider. The Server lays it over the registered client (`resolve_oauth_client_info`).
    public var oauthClientID: String {
        get { info["oauth_client_id"]?.stringValue ?? "" }
        set { info["oauth_client_id"] = .string(newValue) }
    }

    /// `info.oauth_client_secret` (`oauth_2.1_static`). Never shown again once saved.
    public var oauthClientSecret: String {
        get { info["oauth_client_secret"]?.stringValue ?? "" }
        set { info["oauth_client_secret"] = .string(newValue) }
    }

    /// `info.oauth_server_url` (`oauth_2.1_static`): the authorization server, when it isn't found
    /// from `url`. Empty means discover it from `url`, as the web admin sends it when left blank.
    public var oauthServerURL: String {
        get { info["oauth_server_url"]?.stringValue ?? "" }
        set { info["oauth_server_url"] = .string(newValue) }
    }

    /// `info.oauth_scope` (OAuth 2.1): the scopes to ask for. Empty uses the discovered ones.
    public var oauthScope: String {
        get { info["oauth_scope"]?.stringValue ?? "" }
        set {
            if newValue.isEmpty { info["oauth_scope"] = nil } else { info["oauth_scope"] = .string(newValue) }
        }
    }

    /// The display name: `info.name`, else the URL's host.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: url)?.host() ?? url
    }

    /// The tool id chats use for a shared connection (`server:<id>` / `server:mcp:<id>`).
    public var toolID: String {
        type == .mcp ? "server:mcp:\(serverID)" : "server:\(serverID)"
    }

    /// `spec_type: "json"`: the spec was pasted in the web client (`spec`, a JSON string) instead of
    /// being loaded from `path`. `nil` for URL specs, or when the pasted text isn't a JSON object.
    public var inlineSpec: JSONValue? {
        guard raw["spec_type"]?.stringValue == "json" else { return nil }
        switch raw["spec"] {
        case .string(let text)?:
            guard let document = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), document.objectValue != nil else { return nil }
            return document
        case .object(let object)?:
            return .object(object)
        default:
            return nil
        }
    }

    /// Whether the spec is pasted into the entry (`spec_type: "json"`) rather than at `path`.
    public var hasInlineSpec: Bool { raw["spec_type"]?.stringValue == "json" }

    /// The full spec URL for an OpenAPI server (`get_tool_server_url` in `B/utils/tools.py`).
    public var specURL: URL? {
        if path.contains("://") { return URL(string: path) }
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        let relative = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + relative)
    }

    private var info: [String: JSONValue] {
        get { raw["info"]?.objectValue ?? [:] }
        set { raw["info"] = .object(newValue) }
    }

    private var config: [String: JSONValue] {
        get { raw["config"]?.objectValue ?? [:] }
        set { raw["config"] = .object(newValue) }
    }

    public var jsonValue: JSONValue { .object(raw) }
}

extension ToolServerConnection: Codable {
    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - Making connections

extension ToolServerConnection {
    /// What the Add connector sheet collects.
    public struct Draft: Sendable, Equatable {
        public var name: String
        public var url: String
        public var type: ServerType
        /// OpenAPI only.
        public var specPath: String
        public var authType: AuthType
        public var key: String
        public var description: String
        public var isEnabled: Bool
        public var access: ToolServerAccess
        /// `oauth_2.1_static` only: the OAuth app's client id.
        public var oauthClientID: String
        /// `oauth_2.1_static` only: the OAuth app's client secret (like `key`, only for new entries;
        /// edits pass it to `applying(_:key:clientSecret:)`).
        public var oauthClientSecret: String
        /// `oauth_2.1_static` only: the scopes to ask for (empty: the discovered ones).
        public var oauthScope: String

        public init(
            name: String = "",
            url: String = "",
            type: ServerType = .mcp,
            specPath: String = "openapi.json",
            authType: AuthType = .none,
            key: String = "",
            description: String = "",
            isEnabled: Bool = true,
            access: ToolServerAccess = .everyone,
            oauthClientID: String = "",
            oauthClientSecret: String = "",
            oauthScope: String = ""
        ) {
            self.name = name
            self.url = url
            self.type = type
            self.specPath = specPath
            self.authType = authType
            self.key = key
            self.description = description
            self.isEnabled = isEnabled
            self.access = access
            self.oauthClientID = oauthClientID
            self.oauthClientSecret = oauthClientSecret
            self.oauthScope = oauthScope
        }
    }

    /// A new shared connection, shaped like the web admin's "Add Connection" modal sends it
    /// (`AddToolServerModal.svelte`): `spec_type: "url"`, `config.function_name_filter_list`,
    /// `forward_cookies: false` for OpenAPI, and `oauth_resource_parameter: "auto"` for OAuth 2.1.
    /// OAuth 2.1 (static) adds `oauth_scope` when set, and `oauth_client_id`, `oauth_client_secret`
    /// and `oauth_server_url` (empty: discovered from `url`), as the web admin does.
    /// `serverID` should come from `ToolServerConnection.serverID(for:avoiding:)`.
    public static func shared(_ draft: Draft, serverID: String) -> ToolServerConnection {
        var connection = ToolServerConnection(raw: [:])
        connection.type = draft.type
        connection.url = normalizedURL(draft.url, type: draft.type)
        connection.raw["spec_type"] = .string("url")
        connection.raw["spec"] = .string("")
        connection.path = draft.type == .openAPI ? draft.specPath.trimmingCharacters(in: .whitespaces) : ""
        connection.authType = draft.authType
        if draft.type == .openAPI { connection.raw["forward_cookies"] = .bool(false) }
        connection.key = draft.authType == .bearer ? draft.key : ""
        connection.raw["config"] = .object([
            "enable": .bool(draft.isEnabled),
            "function_name_filter_list": .string(""),
            "access_grants": .array(draft.access.grants),
        ])
        var info: [String: JSONValue] = [
            "id": .string(serverID),
            "name": .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(draft.description.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if draft.type == .mcp, draft.authType.isOAuth21 {
            info["oauth_resource_parameter"] = .string("auto")
        }
        connection.raw["info"] = .object(info)
        if draft.type == .mcp, draft.authType == .oauth21Static {
            connection.oauthScope = Self.normalizedScope(draft.oauthScope)
            connection.oauthClientID = draft.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.oauthClientSecret = draft.oauthClientSecret
            connection.oauthServerURL = ""
        }
        return connection
    }

    /// The redirect URI the Server uses for an MCP server's OAuth client
    /// (`{WEBUI_URL}/oauth/clients/mcp:<id>/callback`, `B/utils/oauth.py`): the callback URL to
    /// register at the provider for an OAuth 2.1 (static) app. `base` is the Server's `WEBUI_URL`,
    /// or its address when that isn't set.
    public static func oauthCallbackURL(base: String, serverID: String) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        return "\(root)/oauth/clients/mcp:\(serverID)/callback"
    }

    /// Scopes as typed, trimmed (the Server splits them on spaces and commas).
    static func normalizedScope(_ scope: String) -> String {
        scope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new personal connector (a direct tool server in `ui.toolServers`), shaped like the web
    /// client's Settings › Integrations sends it (`AddToolServerModal` in `direct` mode). OpenAPI
    /// only; the bearer key is stored in the entry, like the web client does (#189), so both
    /// clients can call it.
    public static func personal(_ draft: Draft) -> ToolServerConnection {
        var connection = ToolServerConnection(raw: [:])
        connection.type = .openAPI
        connection.url = normalizedURL(draft.url, type: .openAPI)
        connection.raw["spec_type"] = .string("url")
        connection.raw["spec"] = .string("")
        connection.path = draft.specPath.trimmingCharacters(in: .whitespaces)
        connection.authType = draft.authType
        connection.key = draft.authType == .bearer ? draft.key : ""
        connection.raw["config"] = .object([
            "enable": .bool(draft.isEnabled),
            "function_name_filter_list": .string(""),
            "access_grants": .array([]),
        ])
        connection.raw["info"] = .object([
            "id": .string(""),
            "name": .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(draft.description.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
        return connection
    }

    /// Applies an edit to an existing entry, keeping every field the sheet doesn't show.
    /// `key == nil` keeps the stored key (the field showed "•••• set" and wasn't touched), and
    /// `clientSecret == nil` the stored OAuth client secret. Leaving OAuth 2.1 (static) removes the
    /// app's client id and secret.
    public func applying(_ draft: Draft, key: String?, clientSecret: String?) -> ToolServerConnection {
        var connection = applying(draft, key: key)
        if draft.type == .mcp, draft.authType == .oauth21Static {
            connection.oauthClientID = draft.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.oauthScope = Self.normalizedScope(draft.oauthScope)
            if let clientSecret { connection.oauthClientSecret = clientSecret }
            if connection.info["oauth_server_url"] == nil { connection.oauthServerURL = "" }
            if connection.info["oauth_resource_parameter"] == nil {
                connection.info["oauth_resource_parameter"] = .string("auto")
            }
        } else if authType == .oauth21Static {
            for field in ["oauth_client_id", "oauth_client_secret", "oauth_server_url"] {
                connection.info[field] = nil
            }
        }
        return connection
    }

    /// Applies an edit to an existing entry, keeping every field the sheet doesn't show.
    /// `key == nil` keeps the stored key (the field showed "•••• set" and wasn't touched).
    public func applying(_ draft: Draft, key: String?) -> ToolServerConnection {
        var connection = self
        connection.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.url = Self.normalizedURL(draft.url, type: draft.type)
        connection.type = draft.type
        // A spec pasted in the web client keeps its `path` as it was.
        if draft.type == .openAPI, !hasInlineSpec {
            connection.path = draft.specPath.trimmingCharacters(in: .whitespaces)
        }
        connection.authType = draft.authType
        if draft.authType != .bearer {
            connection.key = ""
        } else if let key {
            connection.key = key
        }
        connection.isEnabled = draft.isEnabled
        connection.access = draft.access
        return connection
    }

    /// The draft that edits this connection (the key is never copied into the form).
    public var draft: Draft {
        Draft(
            name: name,
            url: url,
            type: type,
            specPath: path.isEmpty ? "openapi.json" : path,
            authType: authType,
            key: "",
            description: description,
            isEnabled: isEnabled,
            access: access,
            oauthClientID: oauthClientID,
            oauthClientSecret: "",
            oauthScope: oauthScope
        )
    }

    /// The web admin trims trailing slashes from OpenAPI URLs; MCP servers keep theirs (a
    /// redirect could drop the auth header, open-webui#21179).
    static func normalizedURL(_ url: String, type: ServerType) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .openAPI {
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
        }
        return trimmed
    }

    /// A server id from `name` (lowercase, `-` between words, only letters, digits, `-` and `_`;
    /// like the web admin's slug), made unique against `existing`.
    public static func serverID(for name: String, avoiding existing: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasDash, !slug.isEmpty { slug.append("-"); lastWasDash = true }
            } else if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "connector" }
        var candidate = slug
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }
}

// MARK: - Access

/// Who may use a shared connection: `config.access_grants` (`has_connection_access` in
/// `B/utils/access_control`). No grants means admins only; a `user` grant for `*` means everyone.
public struct ToolServerAccess: Sendable, Equatable {
    public enum Audience: Sendable, Equatable {
        /// Every signed-in user (`{principal_type: user, principal_id: *, permission: read}`).
        case everyone
        /// Members of these groups (`principal_type: group`).
        case groups([String])
        /// Nobody but admins (no grants; the Server always lets admins use their connections).
        case adminsOnly
    }

    /// The grants as stored, unknown entries included.
    public let grants: [JSONValue]

    public init(grants: [JSONValue]) {
        self.grants = grants
    }

    public init(_ audience: Audience) {
        switch audience {
        case .everyone:
            grants = [Self.grant(type: "user", id: "*")]
        case .groups(let ids):
            grants = ids.map { Self.grant(type: "group", id: $0) }
        case .adminsOnly:
            grants = []
        }
    }

    public static let everyone = ToolServerAccess(.everyone)
    public static let adminsOnly = ToolServerAccess(.adminsOnly)

    /// The audience these grants amount to (read access).
    public var audience: Audience {
        let reads = grants.filter { $0[path: "permission"]?.stringValue == "read" }
        if reads.contains(where: { $0[path: "principal_type"]?.stringValue == "user" && $0[path: "principal_id"]?.stringValue == "*" }) {
            return .everyone
        }
        let groups = reads.compactMap { grant -> String? in
            guard grant[path: "principal_type"]?.stringValue == "group" else { return nil }
            return grant[path: "principal_id"]?.stringValue
        }
        return groups.isEmpty ? .adminsOnly : .groups(groups)
    }

    private static func grant(type: String, id: String) -> JSONValue {
        .object(["principal_type": .string(type), "principal_id": .string(id), "permission": .string("read")])
    }
}

// MARK: - Endpoints (admin)

/// `{"TOOL_SERVER_CONNECTIONS": [...]}`: the body of `GET/POST /api/v1/configs/tool_servers`.
public struct ToolServerConnections: Sendable, Equatable, Codable {
    public var connections: [ToolServerConnection]

    public init(_ connections: [ToolServerConnection]) {
        self.connections = connections
    }

    enum CodingKeys: String, CodingKey {
        case connections = "TOOL_SERVER_CONNECTIONS"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A fresh Server stores `null`.
        connections = try container.decodeIfPresent([ToolServerConnection].self, forKey: .connections) ?? []
    }
}

extension Endpoint where Response == ToolServerConnections {
    /// `GET /api/v1/configs/tool_servers` (admin): the Server's shared tool-server connections.
    public static var toolServerConnections: Self {
        Endpoint(method: .get, path: "api/v1/configs/tool_servers", authentication: .required)
    }

    /// `POST /api/v1/configs/tool_servers` (admin): **replaces** the whole list. Use
    /// `OpenWebUIClient.updateToolServerConnections(_:)`, which re-reads it first.
    public static func setToolServerConnections(_ connections: [ToolServerConnection]) -> Self {
        let body = try? WireCoding.encoder.encode(ToolServerConnections(connections))
        return Endpoint(method: .post, path: "api/v1/configs/tool_servers", body: body ?? Data(), authentication: .required)
    }
}

/// What `POST /api/v1/configs/tool_servers/verify` found (`B/routers/configs.py`):
/// - MCP: `{status, specs: [{name, description, parameters}]}` (the server's tools),
/// - MCP with OAuth 2.1: `{status, oauth_server_metadata: {issuer, authorization_endpoint, …}}`,
/// - OpenAPI: the spec document itself (its operations are the tools).
public struct ToolServerVerification: Sendable, Equatable {
    public struct Tool: Sendable, Equatable, Hashable {
        public let name: String
        public let description: String?
    }

    /// The tools the server offers, when the answer lists them.
    public let tools: [Tool]?
    /// The OAuth authorization server's issuer (OAuth 2.1 discovery).
    public let oauthIssuer: String?
    /// The spec's title (OpenAPI).
    public let title: String?
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        if let metadata = raw[path: "oauth_server_metadata"], metadata != .null {
            oauthIssuer = metadata[path: "issuer"]?.stringValue ?? metadata[path: "authorization_endpoint"]?.stringValue
            tools = nil
            title = nil
        } else if let specs = raw[path: "specs"]?.arrayValue {
            tools = specs.compactMap { spec in
                spec[path: "name"]?.stringValue.map { Tool(name: $0, description: spec[path: "description"]?.stringValue) }
            }
            oauthIssuer = nil
            title = nil
        } else if raw[path: "paths"] != nil {
            tools = OpenAPIToolSpec.tools(from: raw).map { Tool(name: $0.name, description: $0.description) }
            title = raw[path: "info.title"]?.stringValue
            oauthIssuer = nil
        } else {
            tools = nil
            oauthIssuer = nil
            title = nil
        }
    }
}

extension Endpoint where Response == ToolServerVerification {
    /// `POST /api/v1/configs/tool_servers/verify` (admin): the Server connects with `connection`
    /// (its auth included) and reports what it found. 400 with a `detail` when it can't.
    public static func verifyToolServer(_ connection: ToolServerConnection) -> Self {
        let body = try? WireCoding.encoder.encode(connection)
        return Endpoint(method: .post, path: "api/v1/configs/tool_servers/verify", body: body ?? Data(), authentication: .required) { data in
            ToolServerVerification(raw: try WireCoding.decoder.decode(JSONValue.self, from: data))
        }
    }
}

/// `POST /api/v1/configs/oauth/clients/register?type=mcp` (admin): the Server registers itself as
/// an OAuth client of an MCP server (dynamic client registration) and returns the client info,
/// encrypted, to be saved as the connection's `info.oauth_client_info`.
public struct OAuthClientRegistration: Sendable, Equatable, Decodable {
    public let status: Bool
    /// Encrypted by the Server; opaque to Theseus.
    public let clientInfo: String

    enum CodingKeys: String, CodingKey {
        case status
        case clientInfo = "oauth_client_info"
    }
}

extension Endpoint where Response == OAuthClientRegistration {
    /// Registers the Server as an OAuth 2.1 client of the MCP server at `url`, for connection
    /// `serverID` (the Server keys the client as `mcp:<serverID>`). Body as the web admin sends it:
    /// `{url, client_id: <server id>}` plus `oauth_scope` when given.
    public static func registerOAuthClient(url: String, serverID: String, scope: String? = nil) -> Self {
        registerOAuthClient(url: url, serverID: serverID, scope: scope, staticCredentials: nil)
    }

    /// OAuth 2.1 (static): the Server skips dynamic client registration, discovers the provider
    /// and builds the client from the admin's OAuth app (`get_oauth_client_info_with_static_credentials`).
    /// Body as the web admin's "Register Client" sends it for `oauth_2.1_static`: `{url,
    /// client_id: <server id>, client_secret, oauth_server_url}` plus `oauth_scope` when given. The
    /// app's own client id isn't sent; it's saved as `info.oauth_client_id`, which the Server lays
    /// over this client (`resolve_oauth_client_info`).
    public static func registerOAuthClient(
        url: String,
        serverID: String,
        scope: String?,
        staticCredentials: (clientSecret: String, oauthServerURL: String)?
    ) -> Self {
        var form: [String: JSONValue] = ["url": .string(url), "client_id": .string(serverID)]
        if let scope, !scope.isEmpty { form["oauth_scope"] = .string(scope) }
        if let staticCredentials {
            form["client_secret"] = .string(staticCredentials.clientSecret)
            form["oauth_server_url"] = .string(staticCredentials.oauthServerURL)
        }
        let body = try? WireCoding.encoder.encode(JSONValue.object(form))
        return Endpoint(
            method: .post,
            path: "api/v1/configs/oauth/clients/register",
            query: [URLQueryItem(name: "type", value: "mcp")],
            body: body ?? Data(),
            authentication: .required
        )
    }
}

extension OAuthClientRegistration {
    /// Whether a failed registration means the provider doesn't offer dynamic client registration
    /// (RFC 7591), like GitHub: the Server wraps every failure as 400 "Failed to register OAuth
    /// client: …" (`B/routers/configs.py`), and a missing or refusing registration endpoint reads
    /// "Dynamic client registration failed: <the provider's answer>" (`B/utils/oauth.py`), e.g.
    /// "404 page not found". Discovery failures and network errors don't count: switching to static
    /// credentials wouldn't help with those.
    public static func isDynamicRegistrationUnsupported(_ error: OpenWebUIError) -> Bool {
        guard case .server(let status, let detail?) = error, [400, 404, 405].contains(status) else { return false }
        let text = detail.lowercased()
        return text.contains("dynamic client registration failed")
            || text.contains("error parsing client registration response")
            || text.contains("registration not supported")
            || text.contains("registration is not supported")
    }
}

/// The bits of `GET /api/v1/auths/admin/config` (admin, read-only) Theseus needs: `WEBUI_URL`, the
/// base of the OAuth callback URLs the Server registers (`B/utils/oauth.py`).
public struct ServerAdminConfig: Sendable, Equatable, Decodable {
    /// `WEBUI_URL`; `nil` or empty when the admin hasn't set it (the Server then uses the address it
    /// was reached at).
    public let webUIURL: String?

    public init(webUIURL: String?) {
        self.webUIURL = webUIURL
    }

    enum CodingKeys: String, CodingKey {
        case webUIURL = "WEBUI_URL"
    }
}

extension Endpoint where Response == ServerAdminConfig {
    /// `GET /api/v1/auths/admin/config` (admin).
    public static var adminConfig: Self {
        Endpoint(method: .get, path: "api/v1/auths/admin/config", authentication: .required)
    }
}

extension OpenWebUIClient {
    /// Read-modify-write of the shared connections: re-reads the list right before writing,
    /// applies `change` to that fresh list and writes it back. Entries `change` doesn't touch go
    /// back exactly as read, so concurrent edits in the web admin survive. Returns what the
    /// Server stored.
    @discardableResult
    public func updateToolServerConnections(
        _ change: @Sendable (inout [ToolServerConnection]) throws(ToolServerEditError) -> Void
    ) async throws(ToolServerEditError) -> [ToolServerConnection] {
        var connections: [ToolServerConnection]
        do {
            connections = try await send(.toolServerConnections).connections
        } catch {
            throw .server(error)
        }
        try change(&connections)
        do {
            return try await send(.setToolServerConnections(connections)).connections
        } catch {
            throw .server(error)
        }
    }
}

/// Why a read-modify-write of connections failed.
public enum ToolServerEditError: Error, Sendable, Equatable {
    /// The connection to edit or remove is gone (someone removed it meanwhile).
    case missing(String)
    /// Someone added a connection with the same id meanwhile.
    case conflict(String)
    case server(OpenWebUIError)

    public var message: String {
        switch self {
        case .missing(let name): "\(name) isn't on the Server anymore. Someone may have removed it meanwhile."
        case .conflict(let name): "Another connection named \(name) was just added on the Server. Pick another name and try again."
        case .server(let error): error.message
        }
    }
}

extension Array where Element == ToolServerConnection {
    /// Adds `connection`, renaming its server id if the fresh list already has it (a concurrent
    /// add of the same name): the "re-apply onto the fresh list" rule. An OAuth 2.1 connection
    /// can't be renamed (its client was registered under the id), so that's a conflict.
    public mutating func add(_ connection: ToolServerConnection) throws(ToolServerEditError) {
        var connection = connection
        let taken = Set(map(\.serverID))
        if taken.contains(connection.serverID) {
            guard connection.oauthClientInfo == nil else { throw .conflict(connection.displayName) }
            connection.serverID = ToolServerConnection.serverID(for: connection.serverID, avoiding: taken)
        }
        append(connection)
    }

    /// Replaces the entry with `id` by `connection`, in place.
    public mutating func replace(_ id: String, with connection: ToolServerConnection) throws(ToolServerEditError) {
        guard let index = firstIndex(where: { $0.id == id }) else { throw .missing(connection.displayName) }
        self[index] = connection
    }

    /// Removes the entry with `id`.
    public mutating func remove(_ id: String) throws(ToolServerEditError) {
        guard let index = firstIndex(where: { $0.id == id }) else { throw .missing(id) }
        self.remove(at: index)
    }
}

// MARK: - Personal connectors (user settings)

extension UserSettings {
    /// The user's personal connectors (`ui.toolServers`), as stored, in order.
    public var personalConnectors: [ToolServerConnection] {
        (raw["ui"]?[path: SharedInterfaceSetting.personalConnectors.rawValue]?.arrayValue ?? []).compactMap { value in
            value.objectValue.map(ToolServerConnection.init(raw:))
        }
    }
}

extension OpenWebUIClient {
    /// Read-modify-write of the personal connectors (`ui.toolServers`): re-reads the settings
    /// right before writing, applies `change` to that fresh list and writes back only
    /// `{"ui": {"toolServers": …}}` (ADR 0030). Entries `change` doesn't touch (added in the web
    /// client, unknown fields) go back as read. Throws `.forbidden` when the Server dropped the
    /// write because the Account may not use personal connectors.
    @discardableResult
    public func updatePersonalConnectors(
        _ change: @Sendable (inout [ToolServerConnection]) throws(ToolServerEditError) -> Void
    ) async throws(ToolServerEditError) -> [ToolServerConnection] {
        var connections: [ToolServerConnection]
        do {
            connections = try await send(.userSettings).personalConnectors
        } catch {
            throw .server(error)
        }
        try change(&connections)
        let list = JSONValue.array(connections.map(\.jsonValue))
        let stored: UserSettings
        do {
            stored = try await send(.updateSharedInterfaceSettings([.personalConnectors: list]))
        } catch {
            throw .server(error)
        }
        guard stored.raw["ui"]?[path: SharedInterfaceSetting.personalConnectors.rawValue] == list else {
            throw .server(.forbidden(detail: "Your Server admin hasn't allowed personal connectors."))
        }
        return stored.personalConnectors
    }
}

// MARK: - Groups (who can use a shared connection)

/// A user group (`GET /api/v1/groups/`, `GroupResponse` in `B/models/groups.py`). Admins get every
/// group; others only their own.
public struct UserGroup: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let memberCount: Int?

    public init(id: String, name: String, memberCount: Int? = nil) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case memberCount = "member_count"
    }
}

extension Endpoint where Response == [UserGroup] {
    /// `GET /api/v1/groups/`.
    public static var userGroups: Self {
        Endpoint(method: .get, path: "api/v1/groups/", authentication: .required)
    }
}
