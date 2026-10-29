import ChatDomain
import Foundation
public import Observation
public import OpenWebUIKit

/// Settings › Server administration › Connectors (#186, admins only): the Server's shared
/// tool-server connections (`TOOL_SERVER_CONNECTIONS`). Every write is read-modify-write: the list
/// is re-read right before writing and only the entry being changed differs, so edits made in the
/// web admin meanwhile survive.
@MainActor
@Observable
public final class ServerConnections {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var connections: [ToolServerConnection] = []
    public private(set) var groups: [UserGroup] = []
    public private(set) var state: LoadState = .idle
    public var notice: String?
    /// Why the last save failed, when there's something better to offer than the message: the
    /// provider doesn't let the Server register itself (#193).
    public var saveFailure: SaveFailure?
    /// The Server's `WEBUI_URL` (admin config), the base of OAuth callback URLs; `nil` until loaded
    /// or when it isn't set.
    public private(set) var webUIURL: String?

    public enum SaveFailure: Equatable, Sendable {
        /// Dynamic client registration failed (GitHub and many others don't offer it). `detail`
        /// is the Server's message.
        case dynamicRegistrationUnsupported(detail: String)
    }
    /// The connection being saved, toggled or removed.
    public private(set) var busy: String?

    @ObservationIgnored let client: OpenWebUIClient
    /// Called after every successful write, so the Account's tool list can reload.
    @ObservationIgnored var onChange: (@MainActor () async -> Void)?

    public init(client: OpenWebUIClient, connections: [ToolServerConnection] = []) {
        self.client = client
        self.connections = connections
        if !connections.isEmpty { state = .loaded }
    }

    public var host: String { ServerDisplay.host(client.server) }

    public func load() async {
        if state != .loaded { state = .loading }
        do {
            connections = try await client.send(.toolServerConnections).connections
            state = .loaded
        } catch {
            if connections.isEmpty { state = .failed(error.message) } else { notice = error.message }
        }
        if let groups = try? await client.send(.userGroups) {
            self.groups = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let config = try? await client.send(.adminConfig) {
            let url = config.webUIURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            webUIURL = url.isEmpty ? nil : url
        }
    }

    /// The server id a new connection named `name` gets (`info.id`), against the loaded list.
    public func plannedServerID(for name: String) -> String {
        ToolServerConnection.serverID(for: name, avoiding: Set(connections.map(\.serverID)))
    }

    /// The callback URL to register at the provider for an OAuth 2.1 (static) app: the Server's
    /// `WEBUI_URL` (else its address) + `/oauth/clients/mcp:<id>/callback`.
    public func oauthCallbackURL(serverID: String) -> String {
        ToolServerConnection.oauthCallbackURL(base: webUIURL ?? client.server.absoluteString, serverID: serverID)
    }

    /// "Everyone on <host>", the group names, or "Only admins".
    public func audienceLabel(_ connection: ToolServerConnection) -> String {
        switch connection.access.audience {
        case .everyone: "Everyone on \(host)"
        case .adminsOnly: "Only admins"
        case .groups(let ids):
            ids.map { id in groups.first { $0.id == id }?.name ?? "1 group" }.formatted(.list(type: .and))
        }
    }

    // MARK: Verify

    /// Asks the Server to connect with what the sheet holds (`/tool_servers/verify`). `key == nil`
    /// verifies with the stored key of `existing`.
    public func verify(_ draft: ToolServerConnection.Draft, key: String?, existing: ToolServerConnection?) async -> Result<ToolServerVerification, ConnectorCheckError> {
        let connection = candidate(draft, key: key, existing: existing)
        do {
            return .success(try await client.send(.verifyToolServer(connection)))
        } catch {
            return .failure(ConnectorCheckError(message: error.message))
        }
    }

    /// What Verify sends. Like the web admin's verify, it carries no OAuth app credentials
    /// (discovery doesn't need them).
    private func candidate(_ draft: ToolServerConnection.Draft, key: String?, existing: ToolServerConnection?) -> ToolServerConnection {
        var connection: ToolServerConnection
        if let existing {
            connection = existing.applying(draft, key: key, clientSecret: nil)
        } else {
            var created = draft
            created.key = key ?? ""
            connection = ToolServerConnection.shared(created, serverID: plannedServerID(for: draft.name))
        }
        if connection.authType == .oauth21Static {
            var raw = connection.raw
            var info = raw["info"]?.objectValue ?? [:]
            info["oauth_client_id"] = nil
            info["oauth_client_secret"] = nil
            raw["info"] = .object(info)
            connection = ToolServerConnection(raw: raw)
        }
        return connection
    }

    // MARK: Save

    /// Adds (`existing == nil`) or edits a connection. OAuth 2.1 MCP servers get the Server
    /// registered as their OAuth client first, like the web admin's "Register Client": by dynamic
    /// client registration, or (OAuth 2.1 static) from the admin's OAuth app. Returns the stored
    /// connection, or `nil` (with `notice`, and `saveFailure` when there's a way forward) when it
    /// failed. `clientSecret == nil` keeps a stored OAuth client secret.
    @discardableResult
    public func save(
        _ draft: ToolServerConnection.Draft,
        key: String?,
        clientSecret: String? = nil,
        existing: ToolServerConnection?
    ) async -> ToolServerConnection? {
        busy = existing?.id ?? "new"
        defer { busy = nil }
        saveFailure = nil
        do {
            let stored: ToolServerConnection
            if let existing {
                var edited = existing.applying(draft, key: key, clientSecret: clientSecret)
                let staticChanged = draft.authType == .oauth21Static
                    && (clientSecret != nil || edited.oauthClientID != existing.oauthClientID || edited.oauthScope != existing.oauthScope)
                if draft.type == .mcp, draft.authType.isOAuth21,
                   edited.oauthClientInfo == nil || edited.url != existing.url || existing.authType != draft.authType || staticChanged {
                    edited.oauthClientInfo = try await register(edited)
                }
                let result = edited
                connections = try await client.updateToolServerConnections { list throws(ToolServerEditError) in
                    try list.replace(existing.id, with: result)
                }
                stored = connections.first { $0.id == result.id } ?? result
            } else {
                // Pick the id against the freshest list, so the OAuth client is registered under
                // the id the entry is stored with.
                let planned = plannedServerID(for: draft.name)
                let fresh = try await client.send(.toolServerConnections).connections
                var created = draft
                created.key = key ?? ""
                created.oauthClientSecret = clientSecret ?? ""
                let serverID = ToolServerConnection.serverID(for: draft.name, avoiding: Set(fresh.map(\.serverID)))
                // A static app's callback URL names the id shown in the sheet: someone took it
                // meanwhile, so the app at the provider would point at the wrong connection.
                if draft.type == .mcp, draft.authType == .oauth21Static, serverID != planned {
                    throw ToolServerEditError.conflict(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                var connection = ToolServerConnection.shared(created, serverID: serverID)
                if draft.type == .mcp, draft.authType.isOAuth21 {
                    connection.oauthClientInfo = try await register(connection)
                }
                let result = connection
                connections = try await client.updateToolServerConnections { list throws(ToolServerEditError) in
                    try list.add(result)
                }
                stored = connections.last { $0.url == result.url && $0.name == result.name } ?? result
            }
            notice = nil
            await onChange?()
            return stored
        } catch let error as ToolServerEditError {
            notice = "Couldn't save. \(error.message)"
        } catch let error as OpenWebUIError {
            notice = "Couldn't save. \(error.message)"
            if draft.authType == .oauth21, OAuthClientRegistration.isDynamicRegistrationUnsupported(error) {
                saveFailure = .dynamicRegistrationUnsupported(detail: error.message)
            }
        } catch {
            notice = "Couldn't save."
        }
        return nil
    }

    private func register(_ connection: ToolServerConnection) async throws(OpenWebUIError) -> String {
        if connection.authType == .oauth21Static {
            return try await client.send(.registerOAuthClient(
                url: connection.url,
                serverID: connection.serverID,
                scope: connection.oauthScope,
                staticCredentials: (connection.oauthClientSecret, connection.oauthServerURL)
            )).clientInfo
        }
        return try await client.send(.registerOAuthClient(url: connection.url, serverID: connection.serverID)).clientInfo
    }

    public func setEnabled(_ connection: ToolServerConnection, _ isEnabled: Bool) async {
        var toggled = connection
        toggled.isEnabled = isEnabled
        let edited = toggled
        await write(busy: connection.id) { list throws(ToolServerEditError) in
            try list.replace(connection.id, with: edited)
        }
    }

    public func remove(_ connection: ToolServerConnection) async {
        await write(busy: connection.id) { list throws(ToolServerEditError) in
            try list.remove(connection.id)
        }
    }

    private func write(busy id: String, _ change: @escaping @Sendable (inout [ToolServerConnection]) throws(ToolServerEditError) -> Void) async {
        busy = id
        defer { busy = nil }
        do {
            connections = try await client.updateToolServerConnections(change)
            notice = nil
            await onChange?()
        } catch {
            notice = "Couldn't save. \(error.message)"
            await load()
        }
    }
}
