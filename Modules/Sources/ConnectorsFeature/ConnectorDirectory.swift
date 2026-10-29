import ChatDomain
public import Foundation
public import Observation
public import OpenWebUIKit

/// The Account's Connectors (CONN-02..05): what `GET /api/v1/tools/` lists, sorted A–Z, plus
/// connecting (MCP OAuth 2.1) and disconnecting. One per signed-in Account; Settings and the Add
/// to Chat sheet share it, so a Connector connected in one shows up in the other.
///
/// The Server decides what the Account may use. Admins manage the Server's tool-server
/// connections (`server`) and everyone may keep personal connectors (`personal`) where the
/// Server allows them (#186, ADR 0095). Workspace (Python) tools stay a web-admin job.
@MainActor
@Observable
public final class ConnectorDirectory {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var connectors: [ToolEntry] = []
    public private(set) var state: LoadState = .idle
    /// A problem to show over the list (a failed disconnect or connect).
    public var notice: String?
    /// The Connector whose disconnect is running.
    public private(set) var disconnecting: String?

    /// What this Account may do with connectors (#186); `.unknown` until `loadAccess()`.
    public private(set) var access: ConnectorAccess = .unknown
    /// The user's personal connectors (direct tool servers, synced with the web app, called from
    /// the device).
    public let personal: PersonalConnectors
    /// The Server's shared connections (admins).
    public let shared: ServerConnections

    public let client: OpenWebUIClient
    public var server: URL { client.server }
    /// The Server's host, as the UI names it ("From chat.example.com").
    public var host: String { ServerDisplay.host(server) }

    public init(
        client: OpenWebUIClient,
        connectors: [ToolEntry] = [],
        legacyKeys: any ConnectorKeyStore = InMemoryConnectorKeyStore(),
        toolTransport: any HTTPTransport = URLSessionTransport(),
        access: ConnectorAccess? = nil
    ) {
        self.client = client
        self.connectors = ConnectorCatalog.sorted(connectors)
        personal = PersonalConnectors(client: client, legacyKeys: legacyKeys, transport: toolTransport)
        shared = ServerConnections(client: client)
        if let access { self.access = access }
        if !connectors.isEmpty { state = .loaded }
        shared.onChange = { [weak self] in await self?.load() }
    }

    /// Reads the Account's role and permissions and the Server's tool-server switch, then loads
    /// personal connectors (they're also what chats send, so this runs at sign-in too).
    public func loadAccess() async {
        async let user = try? client.send(.sessionUser)
        async let config = try? client.send(.config)
        guard let user = await user, let config = await config else { return }
        access = ConnectorAccess(user: user, features: config.features)
        if access.canUsePersonal {
            await personal.load(allowed: true)
        } else {
            await personal.runtime.update(connections: [], allowed: false)
        }
    }

    /// The shared connection behind a Connector (admins; `nil` for workspace tools or before
    /// `shared` loaded).
    public func sharedConnection(for connector: ToolEntry) -> ToolServerConnection? {
        shared.connections.first { $0.toolID == connector.id }
    }

    // MARK: Lists

    /// Connectors a Chat can use right now: tools, tool servers and signed-in MCP servers (A–Z).
    public var usable: [ToolEntry] { connectors.filter(\.isUsable) }

    /// MCP servers that sign in with OAuth 2.1, connected or not: the directory (CONN-03).
    public var directory: [ToolEntry] { connectors.filter(\.requiresSignIn) }

    /// MCP servers still waiting to be connected.
    public var awaitingConnection: [ToolEntry] { connectors.filter { $0.requiresSignIn && !$0.isUsable } }

    public func connector(id: String) -> ToolEntry? {
        connectors.first { $0.id == id }
    }

    // MARK: Loading

    /// Loads the list; keeps the previous one if the Server can't be reached.
    public func load() async {
        if state != .loaded { state = .loading }
        do {
            connectors = ConnectorCatalog.sorted(try await client.send(.tools))
            state = .loaded
        } catch {
            if connectors.isEmpty { state = .failed(error.message) } else { notice = error.message }
        }
    }

    /// Loads once; later visits reuse the list (pull to refresh reloads).
    public func loadIfNeeded() async {
        guard state == .idle || isFailed else { return }
        await load()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: Connect (CONN-03)

    /// What the connect sheet needs: where to start and the Session token to sign the web view in
    /// with. `nil` (with a `notice`) when the Account has no Session token (API-key Accounts).
    public func connection(for connector: ToolEntry) async -> ConnectorAuthorization? {
        guard let start = connector.authorizationURL(server: server) else { return nil }
        guard let token = await client.sessionToken() else {
            notice = "Connecting needs a signed-in session. Sign in with your password or single sign-on and try again."
            return nil
        }
        return ConnectorAuthorization(connectorID: connector.id, name: connector.name, server: server, startURL: start, sessionToken: token)
    }

    /// Called when the connect sheet closes. Reloads, and reports whether the Connector is now usable.
    @discardableResult
    public func connectionFinished(_ connectorID: String, result: ConnectorAuthorization.Event?) async -> Bool {
        if case .failed(let message)? = result {
            notice = "Couldn't connect. \(message)"
        }
        await load()
        let connected = connector(id: connectorID)?.isUsable ?? false
        if case .finished? = result, !connected {
            notice = "\(connector(id: connectorID)?.name ?? "The connector") didn't finish connecting. Try again."
        }
        return connected
    }

    // MARK: Disconnect (CONN-05)

    /// Whether the Connector can be disconnected (a signed-in MCP server).
    public func canDisconnect(_ connector: ToolEntry) -> Bool {
        connector.requiresSignIn && connector.isUsable
    }

    /// Signs the Account out of `connector` (`DELETE /api/v1/auths/oauth/sessions/mcp:<id>`).
    public func disconnect(_ connector: ToolEntry) async {
        guard canDisconnect(connector), let provider = connector.oauthClientID else { return }
        disconnecting = connector.id
        defer { disconnecting = nil }
        do {
            _ = try await client.send(.disconnectOAuthSession(provider: provider))
        } catch .server(status: 404, _) {
            // Already gone on the Server: the reload below shows the truth.
        } catch {
            notice = "Couldn't disconnect \(connector.name). \(error.message)"
            return
        }
        await load()
    }
}

/// Sorting and searching Connectors (CONN-04): alphabetical only, since Open WebUI has no
/// popularity, recency or categories to sort or filter by.
public enum ConnectorCatalog {
    public static func sorted(_ connectors: [ToolEntry]) -> [ToolEntry] {
        connectors.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Connectors whose name or description contains every word of `query` (case- and
    /// diacritic-insensitive), still A–Z.
    public static func filter(_ connectors: [ToolEntry], matching query: String) -> [ToolEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return sorted(connectors) }
        return sorted(connectors).filter { connector in
            let haystack = "\(connector.name) \(connector.description ?? "")"
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
