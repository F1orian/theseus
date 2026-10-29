import Foundation
public import Observation
public import OpenWebUIKit

/// Settings › Connectors › *Yours* (#186, #189, ADR 0095): the user's **personal connectors**,
/// Open WebUI's *direct tool servers*. They're stored exactly as the web client stores them, keys
/// included (`ui.toolServers` in the user settings), so a connector added in either client works
/// in both. **The device** calls them when a Response uses one of their tools (`execute:tool`,
/// through `runtime`), like the browser does on the web.
///
/// Only OpenAPI servers can be personal connectors: Open WebUI's direct tool servers don't speak
/// MCP.
@MainActor
@Observable
public final class PersonalConnectors {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Whether a connector's spec loaded on this device.
    public enum Status: Equatable, Sendable {
        case checking
        case ready(tools: [String])
        case failed(String)
    }

    public private(set) var connections: [ToolServerConnection] = []
    public private(set) var status: [String: Status] = [:]
    public private(set) var state: LoadState = .idle
    /// A failed save, shown at the bottom of the page.
    public var notice: String?
    /// The connector being saved or removed.
    public private(set) var busy: String?

    /// Answers the Server's `execute:tool` calls and lists the tools in completions.
    public let runtime: PersonalConnectorRuntime
    @ObservationIgnored let client: OpenWebUIClient
    /// Keys #186 kept in the Keychain, moved into the entries once (`moveKeychainKeys()`).
    @ObservationIgnored let legacyKeys: any ConnectorKeyStore

    public init(client: OpenWebUIClient, legacyKeys: any ConnectorKeyStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.client = client
        self.legacyKeys = legacyKeys
        runtime = PersonalConnectorRuntime(client: client, transport: transport)
    }

    /// Whether `connection` has a key (shown as "•••• set").
    public func hasKey(_ connection: ToolServerConnection) -> Bool {
        !connection.key.isEmpty
    }

    // MARK: Loading

    /// Reads `ui.toolServers`, moves any key #186 left in the Keychain into its entry, and checks
    /// each enabled connector's spec from the device.
    public func load(allowed: Bool) async {
        if state != .loaded { state = .loading }
        var loaded = false
        do {
            let settings = try await client.send(.userSettings)
            connections = settings.personalConnectors
            state = .loaded
            loaded = true
        } catch {
            if connections.isEmpty { state = .failed(error.message) } else { notice = error.message }
        }
        if loaded, allowed { await moveKeychainKeys() }
        await runtime.update(connections: connections, allowed: allowed)
        await refreshStatus()
    }

    /// #186 kept bearer keys in the Keychain and wrote `key: ""`. Puts each one into its entry
    /// (read-modify-write, only entries that still have no key: a key set meanwhile in the web
    /// app wins), then empties the Keychain. If the write fails the keys stay for the next try.
    func moveKeychainKeys() async {
        let moves = connections.compactMap { connection -> (id: String, key: String)? in
            guard connection.authType == .bearer, connection.key.isEmpty,
                  let key = legacyKeys.key(for: connection.id), !key.isEmpty
            else { return nil }
            return (connection.id, key)
        }
        if !moves.isEmpty {
            do {
                connections = try await client.updatePersonalConnectors { list throws(ToolServerEditError) in
                    for move in moves {
                        guard let index = list.firstIndex(where: { $0.id == move.id }), list[index].key.isEmpty else { continue }
                        list[index].key = move.key
                    }
                }
            } catch {
                return
            }
        }
        legacyKeys.removeAll()
    }

    private func refreshStatus() async {
        for connection in connections where connection.isEnabled {
            status[connection.id] = .checking
        }
        for connection in connections {
            guard connection.isEnabled else {
                status[connection.id] = nil
                continue
            }
            switch await runtime.check(connection) {
            case .success(let tools): status[connection.id] = .ready(tools: tools)
            case .failure(let error): status[connection.id] = .failed(error.message)
            }
        }
    }

    // MARK: Verify (from the device, like the web client)

    /// Fetches the spec of the connector `draft` describes, from the device, with `key`.
    public func verify(_ draft: ToolServerConnection.Draft, key: String?, existing: ToolServerConnection?) async -> Result<[String], ConnectorCheckError> {
        var withKey = draft
        withKey.key = key ?? ""
        let connection = existing?.applying(draft, key: key) ?? ToolServerConnection.personal(withKey)
        return await runtime.check(connection)
    }

    // MARK: Editing (read-modify-write of `ui.toolServers`, keys included like the web client)

    /// Adds a connector, its key in the entry. Returns whether it saved.
    @discardableResult
    public func add(_ draft: ToolServerConnection.Draft, key: String?) async -> Bool {
        var withKey = draft
        withKey.key = key ?? ""
        let connection = ToolServerConnection.personal(withKey)
        return await save(busy: connection.id) { list throws(ToolServerEditError) in
            if list.contains(where: { $0.id == connection.id }) {
                throw .conflict(connection.displayName)
            }
            list.append(connection)
        }
    }

    /// Saves an edit. `key == nil` keeps the stored key.
    @discardableResult
    public func update(_ original: ToolServerConnection, with draft: ToolServerConnection.Draft, key: String?) async -> Bool {
        let edited = original.applying(draft, key: key)
        return await save(busy: original.id) { list throws(ToolServerEditError) in
            try list.replace(original.id, with: edited)
        }
    }

    public func setEnabled(_ connection: ToolServerConnection, _ isEnabled: Bool) async {
        var toggled = connection
        toggled.isEnabled = isEnabled
        let edited = toggled
        await save(busy: connection.id) { list throws(ToolServerEditError) in
            try list.replace(connection.id, with: edited)
        }
    }

    public func remove(_ connection: ToolServerConnection) async {
        await save(busy: connection.id) { list throws(ToolServerEditError) in
            try list.remove(connection.id)
        }
    }

    @discardableResult
    private func save(
        busy id: String,
        _ change: @escaping @Sendable (inout [ToolServerConnection]) throws(ToolServerEditError) -> Void
    ) async -> Bool {
        busy = id
        defer { busy = nil }
        do {
            connections = try await client.updatePersonalConnectors(change)
            notice = nil
            await runtime.update(connections: connections, allowed: true)
            await refreshStatus()
            return true
        } catch {
            notice = "Couldn't save. \(error.message)"
            return false
        }
    }

    /// Forgets any key #186 left in the Keychain for this Account (removing the Account from the
    /// device). Keys in the user settings belong to the Server, as for the web client.
    public func forgetKeys() {
        legacyKeys.removeAll()
    }
}

/// Why a connector's spec couldn't be loaded.
public struct ConnectorCheckError: Error, Sendable, Equatable {
    public let message: String
}

/// The device side of personal connectors (`DirectToolServers`), doing what the web client does in
/// the browser: loads each enabled connector's OpenAPI spec (from its URL, or pasted into the
/// entry), lists its tools in completions (`tool_servers`, without keys), and calls the connector
/// when the Server sends `execute:tool`, with the entry's key or the Session token.
public actor PersonalConnectorRuntime: DirectToolServers {
    private struct Loaded {
        let connection: ToolServerConnection
        let document: JSONValue
        let specs: [OpenAPIToolSpec]
        /// The server's own system prompt (`GET /system`, when its `/api/config` offers one).
        let systemPrompt: String?
    }

    private var connections: [ToolServerConnection] = []
    private var allowed = false
    private var loaded: [String: Loaded] = [:]
    private let client: OpenWebUIClient
    private let transport: any HTTPTransport
    private let specTimeout: Duration

    public init(client: OpenWebUIClient, transport: any HTTPTransport, specTimeout: Duration = .seconds(8)) {
        self.client = client
        self.transport = transport
        self.specTimeout = specTimeout
    }

    /// The connectors to use (only enabled ones count) and whether the Account may use them.
    public func update(connections: [ToolServerConnection], allowed: Bool) {
        self.connections = connections.filter { $0.isEnabled && $0.type == .openAPI }
        self.allowed = allowed
        // Specs stay cached only for connectors that didn't change.
        let current = self.connections
        loaded = loaded.filter { current.contains($0.value.connection) }
    }

    /// Loads `connection`'s spec from the device; returns its tool names.
    public func check(_ connection: ToolServerConnection) async -> Result<[String], ConnectorCheckError> {
        do {
            let document = try await spec(of: connection)
            let specs = OpenAPIToolSpec.tools(from: document)
            if connections.contains(connection) {
                let prompt = await systemPrompt(of: connection)
                loaded[connection.id] = Loaded(connection: connection, document: document, specs: specs, systemPrompt: prompt)
            }
            return .success(specs.map(\.name))
        } catch {
            return .failure(error)
        }
    }

    // MARK: DirectToolServers

    public func toolServersPayload() async -> [JSONValue] {
        guard allowed else { return [] }
        var payload: [JSONValue] = []
        for connection in connections {
            if loaded[connection.id] == nil { _ = await check(connection) }
            guard let entry = loaded[connection.id], !entry.specs.isEmpty else { continue }
            var server: [String: JSONValue] = [
                "url": .string(connection.url),
                "openapi": entry.document,
                "info": entry.document[path: "info"] ?? .object([:]),
                "specs": .array(entry.specs.map(\.jsonValue)),
            ]
            if let prompt = entry.systemPrompt { server["system_prompt"] = .string(prompt) }
            payload.append(.object(server))
        }
        return payload
    }

    public func execute(_ call: DirectToolCall) async -> JSONValue {
        let target = Self.trimmed(call.serverURL)
        guard let connection = connections.first(where: { Self.trimmed($0.url) == target }) else {
            return OpenAPIToolInvocation.failure("Tool Server Not Found")
        }
        if loaded[connection.id] == nil { _ = await check(connection) }
        guard let entry = loaded[connection.id] else {
            return OpenAPIToolInvocation.failure("Couldn't load \(connection.displayName)'s tools from this device.")
        }
        let invocation = OpenAPIToolInvocation(baseURL: connection.url, document: entry.document)
        let request: URLRequest
        do {
            request = try invocation.request(
                operation: call.name,
                params: call.params,
                bearerToken: await token(for: connection),
                sessionID: call.chatID
            )
        } catch .unknownOperation(let name) {
            return OpenAPIToolInvocation.failure("No matching route found for operationId: \(name)")
        } catch {
            return OpenAPIToolInvocation.failure("\(connection.displayName) has an invalid address.")
        }
        do {
            let (data, response) = try await transport.send(request)
            return OpenAPIToolInvocation.result(data: data, response: response)
        } catch let error as OpenWebUIError {
            return OpenAPIToolInvocation.failure("Couldn't reach \(connection.displayName): \(error.message)")
        } catch {
            return OpenAPIToolInvocation.failure("Couldn't reach \(connection.displayName).")
        }
    }

    // MARK: Helpers

    /// The bearer token for calls, as the web client picks it: the entry's key, or the Session
    /// token for `session`.
    private func token(for connection: ToolServerConnection) async -> String? {
        switch connection.authType {
        case .bearer:
            return connection.key.isEmpty ? nil : connection.key
        case .session:
            return await client.sessionToken()
        default:
            return nil
        }
    }

    private func spec(of connection: ToolServerConnection) async throws(ConnectorCheckError) -> JSONValue {
        if connection.hasInlineSpec {
            guard let document = connection.inlineSpec, document[path: "paths"] != nil else {
                throw ConnectorCheckError(message: "The spec pasted in the web app isn't a valid OpenAPI spec (JSON).")
            }
            return document
        }
        guard let url = connection.specURL, url.scheme == "http" || url.scheme == "https" else {
            throw ConnectorCheckError(message: "That address isn't a web address.")
        }
        if ["yaml", "yml"].contains(url.pathExtension.lowercased()) {
            throw ConnectorCheckError(message: "YAML specs only work in the web app. Point it at a JSON spec to use it here.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = specTimeout.seconds
        if let token = await token(for: connection) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as OpenWebUIError {
            throw ConnectorCheckError(message: "Couldn't reach it: \(error.message)")
        } catch {
            throw ConnectorCheckError(message: "Couldn't reach it.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let detail = response.statusCode == 401 || response.statusCode == 403 ? " Check the key." : ""
            throw ConnectorCheckError(message: "It answered with an error (\(response.statusCode)).\(detail)")
        }
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data), document[path: "paths"] != nil else {
            throw ConnectorCheckError(message: "There's no OpenAPI spec (JSON) at \(url.absoluteString).")
        }
        return document
    }

    /// The server's system prompt, the way the web client asks for it: `GET <url>/api/config`, and
    /// when `features.system` is on, `GET <url>/system` with the same token. `nil` when it has none.
    private func systemPrompt(of connection: ToolServerConnection) async -> String? {
        let base = Self.trimmed(connection.url)
        guard let configURL = URL(string: base + "/api/config"), let systemURL = URL(string: base + "/system"),
              configURL.scheme == "http" || configURL.scheme == "https"
        else { return nil }
        var configRequest = URLRequest(url: configURL)
        configRequest.timeoutInterval = specTimeout.seconds
        guard let (configData, configResponse) = try? await transport.send(configRequest),
              (200..<300).contains(configResponse.statusCode),
              let config = try? JSONDecoder().decode(JSONValue.self, from: configData),
              config[path: "features.system"]?.boolValue == true
        else { return nil }
        var request = URLRequest(url: systemURL)
        request.timeoutInterval = specTimeout.seconds
        if let token = await token(for: connection) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await transport.send(request), (200..<300).contains(response.statusCode),
              let prompt = (try? JSONDecoder().decode(JSONValue.self, from: data))?[path: "prompt"]?.stringValue, !prompt.isEmpty
        else { return nil }
        return prompt
    }

    private static func trimmed(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
