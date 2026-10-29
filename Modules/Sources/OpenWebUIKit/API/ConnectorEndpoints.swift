public import Foundation

/// One Connector the Account can use (`GET /api/v1/tools/` → `ToolUserResponse`, `B/routers/tools.py`).
/// The server lists three kinds in one array: workspace tools (`<id>`), admin-configured OpenAPI
/// tool servers (`server:<id>`) and MCP servers (`server:mcp:<id>`). MCP servers that sign in with
/// OAuth 2.1 carry `authenticated`; everything else omits it.
public struct ToolEntry: Sendable, Equatable, Identifiable, Decodable {
    public enum Kind: Sendable, Equatable {
        /// A Python tool from the Server's workspace.
        case workspaceTool
        /// An OpenAPI tool server the admin configured.
        case toolServer
        /// An MCP server the admin configured.
        case mcpServer
    }

    /// The id sent in a completion's `tool_ids`.
    public let id: String
    public let name: String
    public let description: String?
    /// `true`/`false` for OAuth 2.1 MCP servers (signed in or not); `nil` when no sign-in is needed.
    public let authenticated: Bool?
    /// The tool has per-user settings (valves).
    public let hasUserValves: Bool

    public init(id: String, name: String, description: String? = nil, authenticated: Bool? = nil, hasUserValves: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.authenticated = authenticated
        self.hasUserValves = hasUserValves
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, meta, authenticated
        case hasUserValves = "has_user_valves"
    }

    private struct Meta: Decodable {
        let description: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.name = name.isEmpty ? id : name
        let description = (try? container.decodeIfPresent(Meta.self, forKey: .meta))?.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description?.isEmpty == false ? description : nil
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated)
        hasUserValves = try container.decodeIfPresent(Bool.self, forKey: .hasUserValves) ?? false
    }

    public var kind: Kind {
        if id.hasPrefix("server:mcp:") { return .mcpServer }
        if id.hasPrefix("server:") { return .toolServer }
        return .workspaceTool
    }

    /// The MCP server's own id (`server:mcp:<id>` → `<id>`), for MCP servers only.
    public var mcpServerID: String? {
        guard kind == .mcpServer else { return nil }
        return String(id.dropFirst("server:mcp:".count))
    }

    /// Whether the user signs in to this Connector (OAuth 2.1 MCP servers).
    public var requiresSignIn: Bool { authenticated != nil }

    /// Usable in a Chat: no sign-in needed, or signed in.
    public var isUsable: Bool { authenticated ?? true }

    /// The OAuth client the Server registered for an MCP server (`mcp:<id>`); also the provider
    /// name of the Account's OAuth session for it.
    public var oauthClientID: String? {
        mcpServerID.map { "mcp:\($0)" }
    }

    /// Where a signed-in web session starts the MCP OAuth 2.1 flow
    /// (`GET /oauth/clients/{client_id}/authorize`, `B/main.py`). It needs the Session token as
    /// the `token` cookie and finishes with a redirect to the Server's root (`/?error=…` on failure).
    public func authorizationURL(server: URL) -> URL? {
        guard requiresSignIn, let clientID = oauthClientID else { return nil }
        // `appending(path:)` percent-encodes what a path can't hold; `:` stays as the server expects.
        return server.appending(path: "oauth/clients/\(clientID)/authorize")
    }
}

extension Endpoint where Response == [ToolEntry] {
    /// `GET /api/v1/tools/`: the workspace tools, tool servers and MCP servers this Account can use.
    public static var tools: Self {
        Endpoint(method: .get, path: "api/v1/tools/", authentication: .required)
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/auths/oauth/sessions/{provider}`: signs the Account out of a Connector, e.g.
    /// provider `mcp:<server id>` (CONN-05). 404 when there was no session.
    public static func disconnectOAuthSession(provider: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/auths/oauth/sessions/\(provider)", authentication: .required)
    }
}
