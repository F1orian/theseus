@testable import ConnectorsFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// A Server whose `ui.toolServers` lives in memory, patched like Open WebUI patches `ui`.
final class SettingsServer: Sendable {
    private let settings: Mutex<JSONValue>
    /// When `false`, the Server drops `toolServers` from updates (no permission).
    let allowsPersonal: Bool

    init(toolServers: [JSONValue] = [], allowsPersonal: Bool = true) {
        settings = Mutex(.object(["ui": .object(["toolServers": .array(toolServers), "memory": .bool(true)]), "theseus": .object([:])]))
        self.allowsPersonal = allowsPersonal
    }

    var toolServers: [JSONValue] { settings.withLock { $0[path: "ui.toolServers"]?.arrayValue ?? [] } }

    func install(on transport: StubTransport) {
        transport.stub("GET", "api/v1/users/user/settings") { [self] _ in
            (200, (try? JSONEncoder().encode(settings.withLock { $0 })) ?? Data())
        }
        transport.stub("POST", "api/v1/users/user/settings/update") { [self] request in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
            let stored = settings.withLock { current -> JSONValue in
                var root = current.objectValue ?? [:]
                var ui = root["ui"]?.objectValue ?? [:]
                for (key, value) in body[path: "ui"]?.objectValue ?? [:] where key != "toolServers" || allowsPersonal {
                    ui[key] = value
                }
                root["ui"] = .object(ui)
                current = .object(root)
                return current
            }
            return (200, (try? JSONEncoder().encode(stored)) ?? Data())
        }
    }
}

private let notesURL = "http://localhost:8766"

private func toolServerTransport() throws -> StubTransport {
    let tools = StubTransport()
    try tools.stub("GET", "openapi.json", fixture: "synthetic/openapi.notes.json")
    tools.stub("GET", "notes") { request in
        let tag = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tag" }?.value ?? "all"
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? "none"
        return (200, Data(#"{"notes":["milk"],"tag":"\#(tag)","auth":"\#(auth)"}"#.utf8))
    }
    return tools
}

@MainActor
private func makePersonal(server: SettingsServer, legacyKeys: InMemoryConnectorKeyStore = InMemoryConnectorKeyStore(), tools: StubTransport) -> (PersonalConnectors, StubTransport) {
    let transport = StubTransport()
    server.install(on: transport)
    let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken("jwt"))
    return (PersonalConnectors(client: client, legacyKeys: legacyKeys, transport: tools), transport)
}

private func draft(auth: ToolServerConnection.AuthType = .bearer) -> ToolServerConnection.Draft {
    ToolServerConnection.Draft(name: "[theseus-test] Notes", url: notesURL + "/", type: .openAPI, specPath: "openapi.json", authType: auth)
}

/// An entry as the web client's Settings › Integrations writes it (`AddToolServerModal`, `direct`).
private func webEntry(url: String = notesURL, key: String = "sk-web", enabled: Bool = true, extra: [String: JSONValue] = [:]) -> JSONValue {
    var entry: [String: JSONValue] = [
        "type": .string("openapi"), "url": .string(url), "spec_type": .string("url"), "spec": .string(""),
        "path": .string("openapi.json"), "auth_type": .string("bearer"), "key": .string(key),
        "config": .object(["enable": .bool(enabled), "function_name_filter_list": .string(""), "access_grants": .array([])]),
        "info": .object(["id": .string(""), "name": .string("Web notes"), "description": .string("")]),
    ]
    entry.merge(extra) { _, new in new }
    return .object(entry)
}

@Suite("Personal connectors (#186, synced with the web app #189)")
@MainActor
struct PersonalConnectorsTests {
    @Test func addingStoresTheEntryWithItsKeyLikeTheWebClient() async throws {
        let web = webEntry(url: "https://web.example.com", enabled: false, extra: ["x_future": .bool(true)])
        let server = SettingsServer(toolServers: [web])
        let (personal, transport) = makePersonal(server: server, tools: try toolServerTransport())
        await personal.load(allowed: true)
        #expect(personal.connections.count == 1)

        #expect(await personal.add(draft(), key: "sk-secret"))

        // Read-modify-write: re-read, then a `ui`-only patch.
        let methods = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(methods.suffix(2) == ["GET /api/v1/users/user/settings", "POST /api/v1/users/user/settings/update"])
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.last?.httpBody))
        #expect(sent.objectValue?.keys.sorted() == ["ui"])
        #expect(sent[path: "ui"]?.objectValue?.keys.sorted() == ["toolServers"])
        // The web client's entry goes back untouched; ours has the web client's shape, key included.
        #expect(server.toolServers.first == web)
        var expected = webEntry(key: "sk-secret").objectValue ?? [:]
        expected["info"] = .object(["id": .string(""), "name": .string("[theseus-test] Notes"), "description": .string("")])
        #expect(server.toolServers.last == .object(expected))
        let added = try #require(personal.connections.last)
        #expect(personal.hasKey(added))
        guard case .ready(let tools)? = personal.status[added.id] else {
            Issue.record("The spec loads from the device after saving")
            return
        }
        #expect(tools.sorted() == ["add_note", "get_note", "list_notes", "update_note"])
    }

    @Test func aServerThatDropsTheWriteIsReported() async throws {
        let server = SettingsServer(allowsPersonal: false)
        let (personal, _) = makePersonal(server: server, tools: try toolServerTransport())
        await personal.load(allowed: true)
        #expect(await personal.add(draft(), key: "sk") == false)
        #expect(personal.notice?.contains("hasn't allowed personal connectors") == true)
        #expect(personal.connections.isEmpty)
    }

    @Test func editingKeepsTheKeyUnlessReplaced() async throws {
        let server = SettingsServer(toolServers: [webEntry(extra: ["x_future": .bool(true)])])
        let (personal, _) = makePersonal(server: server, tools: try toolServerTransport())
        await personal.load(allowed: true)
        let original = try #require(personal.connections.first)
        var edit = original.draft
        edit.name = "Renamed"

        #expect(await personal.update(original, with: edit, key: nil))
        #expect(server.toolServers.first?[path: "key"] == .string("sk-web"), "the key stays with the entry")
        #expect(server.toolServers.first?[path: "info.name"] == .string("Renamed"))
        #expect(server.toolServers.first?[path: "x_future"] == .bool(true), "unknown fields survive")

        let renamed = try #require(personal.connections.first)
        #expect(await personal.update(renamed, with: renamed.draft, key: "sk-new"))
        #expect(server.toolServers.first?[path: "key"] == .string("sk-new"))
    }

    @Test func keysFromTheKeychainMoveIntoTheEntriesOnce() async throws {
        // #186 wrote `key: ""` and kept the key on the device; the web app set "sk-web" on another.
        let fromTheDevice = webEntry(key: "")
        let fromTheWeb = webEntry(url: "https://web.example.com", key: "sk-web")
        let server = SettingsServer(toolServers: [fromTheDevice, fromTheWeb])
        let deviceID = ToolServerConnection(raw: fromTheDevice.objectValue ?? [:]).id
        let webID = ToolServerConnection(raw: fromTheWeb.objectValue ?? [:]).id
        let legacy = InMemoryConnectorKeyStore([deviceID: "sk-device", webID: "sk-stale", "url:gone|openapi.json": "sk-orphan"])
        let (personal, _) = makePersonal(server: server, legacyKeys: legacy, tools: try toolServerTransport())

        await personal.load(allowed: true)
        #expect(server.toolServers.first?[path: "key"] == .string("sk-device"))
        #expect(server.toolServers.last?[path: "key"] == .string("sk-web"), "a key set in the web app wins")
        #expect(legacy.isEmpty, "the Keychain is emptied after the move")
        #expect(personal.connections.allSatisfy(personal.hasKey))
    }

    @Test func keysStayInTheKeychainWhenTheMoveFails() async throws {
        let entry = webEntry(key: "")
        let server = SettingsServer(toolServers: [entry], allowsPersonal: false)
        let id = ToolServerConnection(raw: entry.objectValue ?? [:]).id
        let legacy = InMemoryConnectorKeyStore([id: "sk-device"])
        let (personal, _) = makePersonal(server: server, legacyKeys: legacy, tools: try toolServerTransport())
        await personal.load(allowed: true)
        #expect(legacy.key(for: id) == "sk-device", "kept for the next try")
        #expect(server.toolServers.first?[path: "key"] == .string(""))
    }

    @Test func aConnectorAddedInTheWebAppIsUsable() async throws {
        let server = SettingsServer(toolServers: [webEntry()])
        let tools = try toolServerTransport()
        let (personal, _) = makePersonal(server: server, tools: tools)
        await personal.load(allowed: true)
        let result = await personal.runtime.execute(DirectToolCall(id: "1", name: "list_notes", params: [:], serverURL: notesURL, chatID: nil))
        #expect(result.arrayValue?.first?[path: "auth"] == .string("Bearer sk-web"))
    }

    @Test func disablingAndRemoving() async throws {
        let server = SettingsServer()
        let (personal, _) = makePersonal(server: server, tools: try toolServerTransport())
        await personal.load(allowed: true)
        #expect(await personal.add(draft(), key: "sk"))
        let added = try #require(personal.connections.first)

        await personal.setEnabled(added, false)
        #expect(server.toolServers.first?[path: "config.enable"] == .bool(false))
        #expect(await personal.runtime.toolServersPayload().isEmpty, "turned-off connectors aren't offered")

        await personal.remove(try #require(personal.connections.first))
        #expect(server.toolServers.isEmpty)
    }

    @Test func verifyLoadsTheSpecFromTheDevice() async throws {
        let tools = try toolServerTransport()
        let (personal, _) = makePersonal(server: SettingsServer(), tools: tools)
        let result = await personal.verify(draft(), key: "sk-typed", existing: nil)
        #expect((try? result.get())?.sorted() == ["add_note", "get_note", "list_notes", "update_note"])
        #expect(tools.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-typed")
        #expect(tools.requests.last?.url?.absoluteString == "\(notesURL)/openapi.json")

        let missing = StubTransport()
        let (broken, _) = makePersonal(server: SettingsServer(), tools: missing)
        if case .failure(let error) = await broken.verify(draft(), key: nil, existing: nil) {
            #expect(error.message.contains("404"))
        } else {
            Issue.record("A missing spec fails")
        }
    }
}

@Suite("Personal connectors on the device (#186, #189)")
struct PersonalConnectorRuntimeTests {
    private func runtime(tools: StubTransport) -> PersonalConnectorRuntime {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken("jwt-session"))
        return PersonalConnectorRuntime(client: client, transport: tools)
    }

    private func connection(auth: ToolServerConnection.AuthType, enabled: Bool = true) -> ToolServerConnection {
        var draft = ToolServerConnection.Draft(name: "Notes", url: notesURL, type: .openAPI, specPath: "openapi.json", authType: auth, key: "sk-secret")
        draft.isEnabled = enabled
        return ToolServerConnection.personal(draft)
    }

    @Test func payloadListsSpecsButNoKeys() async throws {
        let notes = connection(auth: .bearer)
        let runtime = runtime(tools: try toolServerTransport())
        await runtime.update(connections: [notes, connection(auth: .none, enabled: false)], allowed: true)

        let payload = await runtime.toolServersPayload()
        #expect(payload.count == 1)
        let entry = try #require(payload.first)
        #expect(entry[path: "url"] == .string(notesURL))
        #expect(entry[path: "info.title"] == .string("[theseus-test] Notes"))
        #expect(entry[path: "specs"]?.arrayValue?.count == 4)
        #expect(entry[path: "system_prompt"] == nil)
        let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!encoded.contains("sk-secret"), "completions carry specs, never keys")

        await runtime.update(connections: [notes], allowed: false)
        #expect(await runtime.toolServersPayload().isEmpty, "not permitted: nothing is sent")
    }

    @Test(arguments: [
        (ToolServerConnection.AuthType.bearer, "Bearer sk-secret"),
        (.session, "Bearer jwt-session"),
        (.none, "none"),
    ])
    func executeCallsTheServerWithTheUsersAuth(auth: ToolServerConnection.AuthType, header: String) async throws {
        let notes = connection(auth: auth)
        let tools = try toolServerTransport()
        let runtime = runtime(tools: tools)
        await runtime.update(connections: [notes], allowed: true)

        let result = await runtime.execute(DirectToolCall(id: "1", name: "list_notes", params: ["tag": .string("work")], serverURL: notesURL + "/", chatID: "c1"))
        let body = try #require(result.arrayValue?.first)
        #expect(body[path: "tag"] == .string("work"))
        #expect(body[path: "auth"] == .string(header))
        #expect(tools.requests.last?.value(forHTTPHeaderField: "X-Session-Id") == "c1")
    }

    @Test func aSpecPastedInTheWebAppIsUsed() async throws {
        let document = String(decoding: try Fixture.data("synthetic/openapi.notes.json"), as: UTF8.self)
        let pasted = ToolServerConnection(raw: webEntry(key: "", extra: [
            "spec_type": .string("json"), "spec": .string(document), "path": .string(""), "auth_type": .string("none"),
        ]).objectValue ?? [:])
        let tools = try toolServerTransport()
        let runtime = runtime(tools: tools)
        await runtime.update(connections: [pasted], allowed: true)
        #expect((try? await runtime.check(pasted).get())?.count == 4)
        #expect(!tools.requests.contains { $0.url?.path() == "/openapi.json" }, "nothing to fetch")
        let result = await runtime.execute(DirectToolCall(id: "1", name: "list_notes", params: [:], serverURL: notesURL, chatID: nil))
        #expect(result.arrayValue?.first?[path: "notes"] != nil)
    }

    @Test func yamlSpecsExplainThemselves() async throws {
        var yaml = connection(auth: .none)
        yaml.path = "openapi.yaml"
        let runtime = runtime(tools: try toolServerTransport())
        if case .failure(let error) = await runtime.check(yaml) {
            #expect(error.message.contains("YAML"))
        } else {
            Issue.record("YAML specs aren't parsed on the device")
        }
    }

    @Test func theServersSystemPromptJoinsThePayload() async throws {
        let tools = try toolServerTransport()
        tools.stub("GET", "api/config") { _ in (200, Data(#"{"features":{"system":true}}"#.utf8)) }
        tools.stub("GET", "system") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
            return (200, Data(#"{"prompt":"Use notes sparingly."}"#.utf8))
        }
        let runtime = runtime(tools: tools)
        await runtime.update(connections: [connection(auth: .bearer)], allowed: true)
        let payload = await runtime.toolServersPayload()
        #expect(payload.first?[path: "system_prompt"] == .string("Use notes sparingly."))
    }

    @Test func unknownServersAndFailuresAreToolErrors() async throws {
        let runtime = runtime(tools: StubTransport())
        await runtime.update(connections: [connection(auth: .none)], allowed: true)
        let unknown = await runtime.execute(DirectToolCall(id: "1", name: "x", params: [:], serverURL: "https://other.example.com", chatID: nil))
        #expect(unknown == OpenAPIToolInvocation.failure("Tool Server Not Found"))
        let unreachable = await runtime.execute(DirectToolCall(id: "2", name: "list_notes", params: [:], serverURL: notesURL, chatID: nil))
        #expect(unreachable.arrayValue?.first?[path: "error"]?.stringValue?.contains("Couldn't load") == true)
    }
}
