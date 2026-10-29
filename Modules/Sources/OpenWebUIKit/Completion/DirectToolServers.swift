import Foundation

/// The user's personal connectors (Open WebUI's *direct tool servers*, ADR 0095): tool servers the
/// **device** calls. A completion lists their tools in `tool_servers`; when the model calls one,
/// the Server asks this session over the socket (`execute:tool`) and waits for the answer.
///
/// `ConnectorsFeature.PersonalConnectors` implements it; `CompletionSession.useDirectToolServers`
/// plugs it in.
public protocol DirectToolServers: Sendable {
    /// The `tool_servers` entries for a completion: one per enabled personal connector whose spec
    /// loaded, `{url, openapi, info, specs}` (the shape the web client sends). Never contains keys.
    func toolServersPayload() async -> [JSONValue]

    /// Runs one call and returns the answer for the Server: `[data, headers]`, or
    /// `[{error}, null]` on failure (`OpenAPIToolInvocation.result` / `.failure`).
    func execute(_ call: DirectToolCall) async -> JSONValue
}

/// One `execute:tool` request (`B/utils/middleware.py`): `{id, name, params, server, session_id}`,
/// where `server` is the `tool_servers` entry the tool came from (minus its `specs`).
public struct DirectToolCall: Sendable, Equatable {
    public let id: String
    /// The tool (an OpenAPI `operationId`).
    public let name: String
    public let params: [String: JSONValue]
    /// The tool server's base URL, which identifies the personal connector.
    public let serverURL: String
    /// The Chat the call belongs to (sent as `X-Session-Id`, like the web client).
    public let chatID: String?

    public init(id: String, name: String, params: [String: JSONValue], serverURL: String, chatID: String?) {
        self.id = id
        self.name = name
        self.params = params
        self.serverURL = serverURL
        self.chatID = chatID
    }

    /// Reads a call from a socket `events` envelope, or `nil` when it isn't an `execute:tool`.
    public init?(envelope: JSONValue) {
        guard envelope[path: "data.type"]?.stringValue == "execute:tool",
              let data = envelope.objectValue?["data"]?.objectValue?["data"],
              let name = data[path: "name"]?.stringValue
        else { return nil }
        self.init(
            id: data[path: "id"]?.stringValue ?? UUID().uuidString,
            name: name,
            params: data[path: "params"]?.objectValue ?? [:],
            serverURL: data[path: "server.url"]?.stringValue ?? "",
            chatID: envelope[path: "chat_id"]?.stringValue
        )
    }
}

enum DirectToolTimeout {
    /// Runs `work`, or answers with a tool error once `limit` has passed, so the Server's wait
    /// (unbounded by default) always ends.
    static func run(limit: Duration, _ work: @escaping @Sendable () async -> JSONValue) async -> JSONValue {
        await withTaskGroup(of: JSONValue?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            let seconds = limit.components.seconds
            return first ?? OpenAPIToolInvocation.failure("The connector didn't answer within \(seconds) seconds.")
        }
    }
}
