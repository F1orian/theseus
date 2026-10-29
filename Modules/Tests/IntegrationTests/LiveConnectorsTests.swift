import Auth
import ChatDomain
import ConnectorsFeature
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// #186 against the test Server: **writes**, allowed by the owner for this issue (2026-10-25) under
/// guardrails. Everything created is named `[theseus-test]` and removed again, even after a
/// failure; each test snapshots what it touches first and checks the Server is back to it.
/// Shared connections are created for admins only (no grants), so nobody else ever sees them.
@Suite(
    "Live connectors (opt-in: THESEUS_INTEGRATION=1 + .env)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
struct LiveConnectorsTests {
    private static let prefix = "[theseus-test]"

    private func signIn() async throws -> OpenWebUIClient {
        try await signInWithToken().client
    }

    private func signInWithToken() async throws -> (client: OpenWebUIClient, token: String) {
        let settings = try #require(LiveServer.settings)
        let transport = URLSessionTransport()
        guard case .signedIn(let signedIn) = try await PasswordSignIn(server: ServerProfile(url: settings.url, name: "Live"), transport: transport)
            .signIn(email: settings.email, password: settings.password)
        else { throw OpenWebUIError.unauthorized(detail: "sign-in failed") }
        let authenticator = SessionAuthenticator(token: signedIn.token) { throw OpenWebUIError.unauthorized(detail: nil) }
        return (OpenWebUIClient(server: settings.url, transport: transport, authorizer: authenticator), signedIn.token)
    }

    /// Removes every `[theseus-test]` shared connection (read-modify-write; others untouched).
    private func removeTestConnections(_ client: OpenWebUIClient) async {
        _ = try? await client.updateToolServerConnections { list throws(ToolServerEditError) in
            list.removeAll { $0.name.hasPrefix(Self.prefix) }
        }
    }

    @Test func sharedConnectionAddVerifyDisableRemove() async throws {
        let client = try await signIn()
        let before = try await client.send(.toolServerConnections).connections
        defer {
            Task { await removeTestConnections(client) }
        }

        // A public MCP server without sign-in, for admins only.
        let draft = ToolServerConnection.Draft(
            name: "\(Self.prefix) DeepWiki", url: "https://mcp.deepwiki.com/mcp", type: .mcp, authType: .none, access: .adminsOnly
        )
        let entry = ToolServerConnection.shared(draft, serverID: ToolServerConnection.serverID(for: draft.name, avoiding: Set(before.map(\.serverID))))
        let verified = try await client.send(.verifyToolServer(entry))
        #expect((verified.tools?.count ?? 0) > 0, "the Server reached DeepWiki and listed its tools")

        let added = try await client.updateToolServerConnections { list throws(ToolServerEditError) in try list.add(entry) }
        #expect(Array(added.prefix(before.count)) == before, "existing connections are untouched")
        let tools = try await client.send(.tools)
        #expect(tools.contains { $0.id == entry.toolID }, "the admin can use it in chats")

        var off = try #require(added.last)
        off.isEnabled = false
        let disabled = off
        _ = try await client.updateToolServerConnections { list throws(ToolServerEditError) in try list.replace(disabled.id, with: disabled) }
        #expect(try await client.send(.tools).contains { $0.id == entry.toolID } == false)

        let removed = try await client.updateToolServerConnections { list throws(ToolServerEditError) in try list.remove(disabled.id) }
        #expect(removed == before, "the Server is back to its snapshot")
        _ = try? await client.send(.signOut)
    }

    @Test func oauthDiscoveryAndClientRegistrationForAnOAuthMCPServer() async throws {
        let client = try await signIn()
        // Notion's MCP server signs in with OAuth 2.1 and dynamic client registration. Nothing is
        // saved on the Server: verify and register don't change TOOL_SERVER_CONNECTIONS.
        let before = try await client.send(.toolServerConnections).connections
        let entry = ToolServerConnection.shared(
            .init(name: "\(Self.prefix) Notion", url: "https://mcp.notion.com/mcp", type: .mcp, authType: .oauth21, access: .adminsOnly),
            serverID: "theseus-test-notion"
        )
        let discovery = try await client.send(.verifyToolServer(entry))
        #expect(discovery.oauthIssuer?.contains("notion") == true)
        let registration = try await client.send(.registerOAuthClient(url: entry.url, serverID: entry.serverID))
        #expect(registration.status)
        #expect(!registration.clientInfo.isEmpty)
        #expect(try await client.send(.toolServerConnections).connections == before)
        _ = try? await client.send(.signOut)
    }

    /// #193: GitHub's MCP server has no dynamic client registration. Checks that the Server says
    /// so in the way Theseus recognises, then saves a `[theseus-test]` OAuth 2.1 (static) entry
    /// (admins only) with a **dummy** OAuth app, the way the app does, and follows the Server's
    /// authorize endpoint up to GitHub: it must redirect to GitHub's authorize page with the dummy
    /// client id and the callback URL the sheet shows. Then the entry is removed and the Server is
    /// back to its snapshot. Nothing is sent to GitHub beyond discovery.
    @MainActor
    @Test func staticOAuthClientForGitHubRedirectsToGitHubWithTheCallbackURL() async throws {
        let (client, token) = try await signInWithToken()
        let before = try await client.send(.toolServerConnections).connections
        defer {
            Task { await removeTestConnections(client) }
        }
        let url = "https://api.githubcopilot.com/mcp/"
        let dummyClientID = "Ov23liTheseusTestDummy"

        // Dynamic registration fails the way the owner saw it, and Theseus recognises it.
        do {
            _ = try await client.send(.registerOAuthClient(url: url, serverID: "theseus-test-github"))
            Issue.record("GitHub unexpectedly accepted dynamic client registration")
        } catch {
            #expect(OAuthClientRegistration.isDynamicRegistrationUnsupported(error), "\(error.message)")
        }
        #expect(try await client.send(.toolServerConnections).connections == before, "a failed registration saves nothing")

        let shared = ServerConnections(client: client)
        await shared.load()
        let draft = ToolServerConnection.Draft(
            name: "\(Self.prefix) GitHub", url: url, type: .mcp, authType: .oauth21Static, access: .adminsOnly,
            oauthClientID: dummyClientID
        )
        let serverID = shared.plannedServerID(for: draft.name)
        let callback = shared.oauthCallbackURL(serverID: serverID)
        let check = try await shared.verify(draft, key: nil, existing: nil).get()
        #expect(check.oauthIssuer?.contains("github.com") == true, "discovery finds GitHub's sign-in")

        let saved = try #require(await shared.save(draft, key: nil, clientSecret: "theseus-test-dummy-secret", existing: nil), "\(shared.notice ?? "")")
        #expect(saved.authType == .oauth21Static && saved.oauthClientInfo != nil)
        let tools = try await client.send(.tools)
        #expect(tools.contains { $0.id == saved.toolID }, "the Server lists it for the admin")

        // The Server's authorize endpoint sends the browser to GitHub with the app's client id.
        var request = URLRequest(url: client.server.appending(path: "oauth/clients/mcp:\(serverID)/authorize"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        let http = try #require(response as? HTTPURLResponse)
        #expect([302, 303, 307].contains(http.statusCode), "status \(http.statusCode)")
        let location = try #require(http.value(forHTTPHeaderField: "Location").flatMap(URLComponents.init(string:)))
        #expect(location.host == "github.com" && location.path == "/login/oauth/authorize")
        let query = Dictionary((location.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(query["client_id"] == dummyClientID)
        #expect(query["redirect_uri"] == callback, "the callback URL the sheet shows is the one the Server uses")

        let removed = try await client.updateToolServerConnections { list throws(ToolServerEditError) in try list.remove(saved.id) }
        #expect(removed == before, "the Server is back to its snapshot")
        _ = try? await client.send(.signOut)
    }

    /// #189: personal connectors are stored like the web client stores them, keys included. Adds
    /// one the Theseus way and one the web way (the web client's exact entry shape), checks both
    /// with GET, then restores the snapshot of `ui.toolServers`. With `THESEUS_TOOLS_URL` (the stub
    /// server's `/stub-tools`, reachable from this Mac), the web-added one is also called from here
    /// with its stored key, as the app does.
    @MainActor
    @Test func personalConnectorsAreSyncedWithTheWebAppKeysIncluded() async throws {
        let toolsURL = ProcessInfo.processInfo.environment["THESEUS_TOOLS_URL"].flatMap { $0.isEmpty ? nil : $0 }
        let client = try await signIn()
        let snapshot = try await client.send(.userSettings).personalConnectors
        defer {
            Task {
                _ = try? await client.updatePersonalConnectors { list throws(ToolServerEditError) in
                    list.removeAll { $0.name.hasPrefix(Self.prefix) }
                }
            }
        }
        let theseus = ToolServerConnection.personal(.init(
            name: "\(Self.prefix) Notes", url: "http://127.0.0.1:9/theseus-test", type: .openAPI, specPath: "openapi.json",
            authType: .bearer, key: "theseus-test-key"
        ))
        let web = ToolServerConnection(raw: [
            "type": .string("openapi"), "url": .string(toolsURL ?? "http://127.0.0.1:9/theseus-test-web"), "spec_type": .string("url"),
            "spec": .string(""), "path": .string("openapi.json"), "auth_type": .string("bearer"), "key": .string("stub-tool-key"),
            "config": .object(["enable": .bool(true), "function_name_filter_list": .string(""), "access_grants": .array([])]),
            "info": .object(["id": .string(""), "name": .string("\(Self.prefix) Web notes"), "description": .string("")]),
        ])
        _ = try await client.updatePersonalConnectors { list throws(ToolServerEditError) in
            list.append(theseus)
            list.append(web)
        }
        let stored = try await client.send(.userSettings).personalConnectors
        #expect(stored.first { $0.id == theseus.id } == theseus, "added in Theseus: stored with its key")
        #expect(stored.first { $0.id == web.id } == web, "the web client's shape round-trips unchanged")
        #expect(stored.first { $0.id == theseus.id }?.key == "theseus-test-key")

        if let toolsURL {
            let personal = PersonalConnectors(client: client, legacyKeys: InMemoryConnectorKeyStore(), transport: URLSessionTransport())
            await personal.load(allowed: true)
            let result = await personal.runtime.execute(DirectToolCall(id: "live", name: "list_notes", params: ["tag": .string("work")], serverURL: toolsURL, chatID: nil))
            let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(text.contains("Ship #186"), "the web-added connector is usable with its stored key: \(text)")
        }

        let after = try await client.updatePersonalConnectors { list throws(ToolServerEditError) in
            list.removeAll { $0.name.hasPrefix(Self.prefix) }
        }
        #expect(after == snapshot, "ui.toolServers is back to its snapshot")
        _ = try? await client.send(.signOut)
    }

    /// The whole personal-connector loop with a real model: the completion lists a tool in
    /// `tool_servers`, the model calls it, the Server asks this session (`execute:tool`), and the
    /// answer reaches the model. An Incognito chat, so nothing is stored.
    @Test func aModelCallsAPersonalConnectorThroughExecuteTool() async throws {
        let client = try await signIn()
        let session = CompletionSession.live(client: client, credential: .sessionToken, serverSupportsWebSocket: true)
        let tools = SecretWordTool()
        session.useDirectToolServers(tools)
        let events = await session.events()
        await session.start()

        let models = try await client.send(.models)
        let model = try #require(models.first { $0.id.contains("haiku") } ?? models.first)
        let request = CompletionRequest(
            chatID: nil,
            modelID: model.id,
            prompt: "\(Self.prefix) Call the get_secret_word tool, then reply with only the word it returns.",
            isIncognito: true
        )
        let receipt = try await session.send(request)
        #expect(receipt.transport == .socket)

        var state = ResponseState()
        let deadline = ContinuousClock.now + .seconds(120)
        for await event in events where event.messageID == request.assistantMessageID {
            if case .response(let response) = event.kind { state.apply(response) }
            if state.isFinished || ContinuousClock.now > deadline { break }
        }
        #expect(tools.calls == ["get_secret_word"], "the Server asked this device to run the tool")
        #expect(state.text.contains("verdigris"), "the tool's answer reached the model")
        await session.shutdown()
        _ = try? await client.send(.signOut)
    }
}

/// A personal connector with one tool, answered in memory (no HTTP server needed: the device side
/// is what's under test).
private final class SecretWordTool: DirectToolServers {
    private let recorded = Mutex<[String]>([])
    var calls: [String] { recorded.withLock { $0 } }

    func toolServersPayload() async -> [JSONValue] {
        [.object([
            "url": .string("http://localhost:9/theseus-test"),
            "openapi": .object([
                "openapi": .string("3.1.0"),
                "info": .object(["title": .string("[theseus-test] Secrets"), "version": .string("1")]),
                "paths": .object(["/secret": .object(["get": .object(["operationId": .string("get_secret_word")])])]),
            ]),
            "info": .object(["title": .string("[theseus-test] Secrets"), "version": .string("1")]),
            "specs": .array([.object([
                "name": .string("get_secret_word"),
                "description": .string("Returns today's secret word."),
                "parameters": .object(["type": .string("object"), "properties": .object([:]), "required": .array([])]),
            ])]),
        ])]
    }

    func execute(_ call: DirectToolCall) async -> JSONValue {
        recorded.withLock { $0.append(call.name) }
        return .array([.object(["word": .string("verdigris")]), .object(["content-type": .string("application/json")])])
    }
}

/// Stops at the first redirect, so a test can read where the Server sends the browser.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
