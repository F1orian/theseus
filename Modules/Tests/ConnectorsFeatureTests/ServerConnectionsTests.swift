@testable import ConnectorsFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// A Server whose `TOOL_SERVER_CONNECTIONS` lives in memory.
final class ToolServerConfigServer: Sendable {
    let list: Mutex<[JSONValue]>
    init(_ list: [JSONValue] = []) { self.list = Mutex(list) }

    func install(on transport: StubTransport) {
        transport.stub("GET", "api/v1/configs/tool_servers") { [self] _ in
            (200, (try? JSONEncoder().encode(JSONValue.object(["TOOL_SERVER_CONNECTIONS": .array(list.withLock { $0 })]))) ?? Data())
        }
        transport.stub("POST", "api/v1/configs/tool_servers") { [self] request in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
            list.withLock { $0 = body[path: "TOOL_SERVER_CONNECTIONS"]?.arrayValue ?? [] }
            return (200, request.httpBody ?? Data())
        }
    }
}

@MainActor
private func makeShared(_ server: ToolServerConfigServer) throws -> (ServerConnections, StubTransport) {
    let transport = StubTransport()
    server.install(on: transport)
    try transport.stub("GET", "api/v1/groups/", fixture: "groups.json")
    try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register.json")
    try transport.stub("POST", "api/v1/configs/tool_servers/verify", fixture: "synthetic/tool-server.verify-mcp.json")
    let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken("jwt"))
    return (ServerConnections(client: client), transport)
}

@Suite("Shared connections (#186)")
@MainActor
struct ServerConnectionsTests {
    @Test func addingAnOAuthServerRegistersItsClientFirst() async throws {
        let server = ToolServerConfigServer()
        let (shared, transport) = try makeShared(server)
        await shared.load()
        let draft = ToolServerConnection.Draft(name: "[theseus-test] Notion", url: "https://mcp.notion.com/mcp", type: .mcp, authType: .oauth21)

        let saved = try #require(await shared.save(draft, key: nil, existing: nil))

        let calls = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(Array(calls.suffix(4)) == [
            "GET /api/v1/configs/tool_servers",
            "POST /api/v1/configs/oauth/clients/register",
            "GET /api/v1/configs/tool_servers",
            "POST /api/v1/configs/tool_servers",
        ])
        let register = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first { $0.url?.path() == "/api/v1/configs/oauth/clients/register" }?.httpBody))
        #expect(register == .object(["url": .string("https://mcp.notion.com/mcp"), "client_id": .string("theseus-test-notion")]))
        #expect(saved.oauthClientInfo == "gAAAAABn-encrypted-client-info")
        #expect(saved.toolID == "server:mcp:theseus-test-notion")
        #expect(server.list.withLock { $0.count } == 1)
    }

    @Test func addingABearerOpenAPIServerKeepsTheKeyOnTheServer() async throws {
        let server = ToolServerConfigServer()
        let (shared, _) = try makeShared(server)
        let draft = ToolServerConnection.Draft(name: "Notes", url: "http://192.168.1.20:8766", type: .openAPI, authType: .bearer, access: .adminsOnly)
        _ = try #require(await shared.save(draft, key: "sk-shared", existing: nil))
        let stored = try #require(server.list.withLock { $0.first })
        #expect(stored[path: "key"] == .string("sk-shared"))
        #expect(stored[path: "config.access_grants"] == .array([]))
        #expect(shared.audienceLabel(ToolServerConnection(raw: stored.objectValue ?? [:])) == "Only admins")
    }

    @Test func editWithoutReplacingTheKeyKeepsIt() async throws {
        let existing = ToolServerConnection.shared(
            .init(name: "Notes", url: "http://n.example.com", type: .openAPI, authType: .bearer, key: "sk-old"), serverID: "notes"
        )
        let server = ToolServerConfigServer([existing.jsonValue])
        let (shared, _) = try makeShared(server)
        await shared.load()
        var draft = existing.draft
        draft.description = "Shared notes"
        _ = try #require(await shared.save(draft, key: nil, existing: existing))
        #expect(server.list.withLock { $0.first?[path: "key"] } == .string("sk-old"))
        #expect(server.list.withLock { $0.first?[path: "info.description"] } == .string("Shared notes"))
    }

    @Test func disableAndRemoveTouchOnlyTheirEntry() async throws {
        let one = ToolServerConnection.shared(.init(name: "One", url: "https://one.example.com", type: .mcp), serverID: "one")
        var foreign = ToolServerConnection.shared(.init(name: "Two", url: "https://two.example.com", type: .mcp), serverID: "two").raw
        foreign["x_web_admin_only"] = .string("kept")
        let server = ToolServerConfigServer([one.jsonValue, .object(foreign)])
        let (shared, _) = try makeShared(server)
        await shared.load()
        var reloads = 0
        shared.onChange = { reloads += 1 }

        await shared.setEnabled(one, false)
        #expect(server.list.withLock { $0 }.map { $0[path: "config.enable"] } == [.bool(false), .bool(true)])
        #expect(server.list.withLock { $0.last } == .object(foreign))

        await shared.remove(try #require(shared.connections.first))
        #expect(server.list.withLock { $0 } == [.object(foreign)])
        #expect(reloads == 2, "the tool list reloads after each change")
    }

    @Test func removingSomethingAlreadyGoneReports() async throws {
        let gone = ToolServerConnection.shared(.init(name: "Gone", url: "https://g.example.com", type: .mcp), serverID: "gone")
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        await shared.remove(gone)
        #expect(shared.notice?.contains("isn't on the Server anymore") == true)
        #expect(!transport.requests.contains { $0.httpMethod == "POST" })
    }

    @Test func verifyShowsTheTools() async throws {
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        let draft = ToolServerConnection.Draft(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", type: .mcp)
        let result = try await shared.verify(draft, key: nil, existing: nil).get()
        #expect(result.tools?.count == 3)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.last?.httpBody))
        #expect(body[path: "info.id"] == .string("deepwiki"))
    }
}

/// #193: OAuth 2.1 MCP servers whose provider has no dynamic client registration (GitHub).
@Suite("Static OAuth connections (#193)")
@MainActor
struct StaticOAuthConnectionTests {
    private func requestBody(_ transport: StubTransport, _ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.last { $0.url?.path() == path }?.httpBody))
    }

    private func staticDraft() -> ToolServerConnection.Draft {
        ToolServerConnection.Draft(
            name: "[theseus-test] GitHub", url: "https://api.githubcopilot.com/mcp/", type: .mcp, authType: .oauth21Static,
            access: .adminsOnly, oauthClientID: "Ov23liExampleClient", oauthScope: ""
        )
    }

    @Test func addingRegistersTheAppsCredentialsThenSavesThem() async throws {
        let server = ToolServerConfigServer()
        let (shared, transport) = try makeShared(server)
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register-static.json")
        await shared.load()

        let saved = try #require(await shared.save(staticDraft(), key: nil, clientSecret: "s3cr3t", existing: nil))

        let calls = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(Array(calls.suffix(4)) == [
            "GET /api/v1/configs/tool_servers",
            "POST /api/v1/configs/oauth/clients/register",
            "GET /api/v1/configs/tool_servers",
            "POST /api/v1/configs/tool_servers",
        ])
        #expect(try requestBody(transport, "/api/v1/configs/oauth/clients/register") == .object([
            "url": .string("https://api.githubcopilot.com/mcp/"), "client_id": .string("theseus-test-github"),
            "client_secret": .string("s3cr3t"), "oauth_server_url": .string(""),
        ]))
        let stored = try #require(server.list.withLock { $0.first })
        #expect(stored[path: "auth_type"] == .string("oauth_2.1_static"))
        #expect(stored[path: "info.oauth_client_id"] == .string("Ov23liExampleClient"))
        #expect(stored[path: "info.oauth_client_secret"] == .string("s3cr3t"))
        #expect(stored[path: "info.oauth_server_url"] == .string(""))
        #expect(stored[path: "info.oauth_client_info"] == .string("gAAAAABn-encrypted-static-client-info"))
        #expect(stored[path: "info.oauth_resource_parameter"] == .string("auto"))
        #expect(saved.toolID == "server:mcp:theseus-test-github")
    }

    @Test func editingWithoutReplacingTheSecretKeepsItAndDoesntReRegister() async throws {
        var draft = staticDraft()
        draft.oauthClientSecret = "s3cr3t"
        var existing = ToolServerConnection.shared(draft, serverID: "theseus-test-github")
        existing.oauthClientInfo = "blob"
        let server = ToolServerConfigServer([existing.jsonValue])
        let (shared, transport) = try makeShared(server)
        await shared.load()

        var edit = existing.draft
        edit.description = "Repos and issues"
        _ = try #require(await shared.save(edit, key: nil, clientSecret: nil, existing: existing))
        #expect(!transport.requests.contains { $0.url?.path() == "/api/v1/configs/oauth/clients/register" })
        let stored = try #require(server.list.withLock { $0.first })
        #expect(stored[path: "info.oauth_client_secret"] == .string("s3cr3t"))
        #expect(stored[path: "info.oauth_client_info"] == .string("blob"))
        #expect(stored[path: "info.description"] == .string("Repos and issues"))

        // A new secret registers again with it.
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register-static.json")
        let current = try #require(shared.connections.first)
        _ = try #require(await shared.save(current.draft, key: nil, clientSecret: "n3w", existing: current))
        #expect(try requestBody(transport, "/api/v1/configs/oauth/clients/register")[path: "client_secret"] == .string("n3w"))
        #expect(server.list.withLock { $0.first?[path: "info.oauth_client_secret"] } == .string("n3w"))
        #expect(server.list.withLock { $0.first?[path: "info.oauth_client_info"] } == .string("gAAAAABn-encrypted-static-client-info"))
    }

    @Test func verifySendsNoAppCredentials() async throws {
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        try transport.stub("POST", "api/v1/configs/tool_servers/verify", fixture: "synthetic/tool-server.verify-oauth.json")
        var draft = staticDraft()
        draft.oauthClientSecret = "s3cr3t"
        let result = try await shared.verify(draft, key: nil, existing: nil).get()
        #expect(result.oauthIssuer == "https://mcp.example.com/")
        let body = try requestBody(transport, "/api/v1/configs/tool_servers/verify")
        #expect(body[path: "auth_type"] == .string("oauth_2.1_static"))
        #expect(body[path: "info.oauth_client_secret"] == nil && body[path: "info.oauth_client_id"] == nil)
        #expect(body[path: "info.oauth_resource_parameter"] == .string("auto"))
    }

    @Test func aNameTakenMeanwhileFailsInsteadOfMovingTheCallbackURL() async throws {
        let server = ToolServerConfigServer()
        let (shared, transport) = try makeShared(server)
        await shared.load()
        // Someone adds a connection with the same name in the web admin after the sheet opened.
        let other = ToolServerConnection.shared(.init(name: "[theseus-test] GitHub", url: "https://x.example.com", type: .mcp), serverID: "theseus-test-github")
        server.list.withLock { $0 = [other.jsonValue] }

        #expect(await shared.save(staticDraft(), key: nil, clientSecret: "s3cr3t", existing: nil) == nil)
        #expect(shared.notice?.contains("Pick another name") == true)
        #expect(!transport.requests.contains { $0.url?.path() == "/api/v1/configs/oauth/clients/register" })
        #expect(server.list.withLock { $0 } == [other.jsonValue])
    }

    @Test func theCallbackURLUsesTheServersWebUIURL() async throws {
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        try transport.stub("GET", "api/v1/auths/admin/config", fixture: "synthetic/auths.admin-config.json")
        let form = ConnectorForm(kind: .shared)
        form.draft.authType = .oauth21Static
        #expect(form.callbackURL(in: shared) == nil, "no name, no id yet")
        form.draft.name = "GitHub"
        #expect(form.callbackURL(in: shared) == "\(Fixture.serverURL.absoluteString)/oauth/clients/mcp:github/callback", "the Server's address until WEBUI_URL is known")
        await shared.load()
        #expect(form.callbackURL(in: shared) == "https://owui.example.com/oauth/clients/mcp:github/callback")
    }

    /// The owner's bug: GitHub has no dynamic client registration, so Save failed with the raw
    /// error. Now the sheet explains it and switches to static (or Bearer) keeping everything else.
    @Test func registrationNotSupportedOffersTheWaysForward() async throws {
        let server = ToolServerConfigServer()
        let (shared, transport) = try makeShared(server)
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", status: 400, fixture: "synthetic/oauth-client.register-dcr-unsupported.json")
        await shared.load()
        let form = ConnectorForm(kind: .shared)
        form.draft.name = "[theseus-test] GitHub"
        form.draft.url = "https://api.githubcopilot.com/mcp/"
        form.draft.authType = .oauth21
        form.draft.description = "Repos"
        form.draft.access = .adminsOnly

        #expect(await form.save(personal: nil, shared: shared) == nil)
        #expect(form.registrationUnsupported == "Failed to register OAuth client: Dynamic client registration failed: 404 page not found")
        #expect(shared.saveFailure == .dynamicRegistrationUnsupported(detail: "Failed to register OAuth client: Dynamic client registration failed: 404 page not found"))
        #expect(server.list.withLock { $0.isEmpty }, "nothing was saved")

        form.useStaticOAuth()
        #expect(form.registrationUnsupported == nil)
        #expect(form.draft.authType == .oauth21Static)
        #expect(form.draft.name == "[theseus-test] GitHub" && form.draft.url == "https://api.githubcopilot.com/mcp/")
        #expect(form.draft.description == "Repos" && form.draft.access == .adminsOnly, "every other field is kept")
        #expect(!form.isValid, "needs the app's client ID and secret")
        form.draft.oauthClientID = "Ov23liExampleClient"
        form.clientSecret = "s3cr3t"
        #expect(form.isValid)
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register-static.json")
        let saved = try #require(await form.save(personal: nil, shared: shared))
        #expect(saved.authType == .oauth21Static)
        #expect(form.usesOAuth, "Connect now is offered, as for OAuth 2.1")
        #expect(server.list.withLock { $0.first?[path: "info.oauth_client_id"] } == .string("Ov23liExampleClient"))
    }

    @Test func orAPersonalTokenWithAWarningForEveryone() async throws {
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", status: 400, fixture: "synthetic/oauth-client.register-dcr-unsupported.json")
        let form = ConnectorForm(kind: .shared)
        form.draft.name = "GitHub"
        form.draft.url = "https://api.githubcopilot.com/mcp/"
        form.draft.authType = .oauth21
        _ = await form.save(personal: nil, shared: shared)
        #expect(form.registrationUnsupported != nil)

        form.useBearerToken()
        #expect(form.draft.authType == .bearer && form.registrationUnsupported == nil)
        #expect(form.sharesOneAccount, "Everyone + one token: warn that all act as its account")
        form.draft.access = .adminsOnly
        #expect(!form.sharesOneAccount)
    }

    @Test func otherFailuresKeepThePlainMessage() async throws {
        let (shared, transport) = try makeShared(ToolServerConfigServer())
        transport.stub("POST", "api/v1/configs/oauth/clients/register", status: 400, body: Data(#"{"detail":"Failed to register OAuth client: Failed to discover OAuth metadata"}"#.utf8))
        let form = ConnectorForm(kind: .shared)
        form.draft.name = "Docs"
        form.draft.url = "https://mcp.example.com/mcp"
        form.draft.authType = .oauth21
        #expect(await form.save(personal: nil, shared: shared) == nil)
        #expect(form.registrationUnsupported == nil)
        #expect(shared.notice == "Couldn't save. Failed to register OAuth client: Failed to discover OAuth metadata")
    }
}

@Suite("Connector form (#186)")
@MainActor
struct ConnectorFormTests {
    @Test func validatesInline() {
        let form = ConnectorForm(kind: .shared)
        #expect(form.nameError != nil && form.urlError != nil)
        form.draft.name = "Docs"
        form.draft.url = "mcp.example.com"
        #expect(form.urlError == "Enter a full address, like https://tools.example.com.")
        form.draft.url = "https://mcp.example.com/mcp"
        #expect(form.isValid)
        form.draft.authType = .bearer
        #expect(form.keyError != nil)
        form.key = "sk"
        #expect(form.isValid)
        form.draft.type = .openAPI
        form.draft.specPath = " "
        #expect(form.specPathError != nil)
    }

    @Test func choicesFollowTheKindAndType() {
        let shared = ConnectorForm(kind: .shared)
        #expect(shared.types == [.mcp, .openAPI])
        #expect(shared.authTypes == [.none, .bearer, .session, .oauth21, .oauth21Static])
        shared.draft.authType = .oauth21
        shared.draft.type = .openAPI
        shared.typeChanged()
        #expect(shared.draft.authType == .none, "OAuth 2.1 is for MCP servers")

        let personal = ConnectorForm(kind: .personal)
        #expect(personal.types == [.openAPI])
        #expect(personal.authTypes == [.none, .bearer, .session])
        #expect(personal.draft.type == .openAPI)
    }

    @Test func aStoredKeyIsMaskedUntilReplaced() {
        let existing = ToolServerConnection.shared(.init(name: "N", url: "https://n.example.com", type: .openAPI, authType: .bearer, key: "sk"), serverID: "n")
        let form = ConnectorForm(kind: .shared, existing: existing, hasStoredKey: true)
        #expect(!form.isReplacingKey)
        #expect(form.keyError == nil)
        #expect(form.keyToSave == nil, "keeps the stored key")
        #expect(form.draft.key.isEmpty, "the key is never copied into the form")
        form.isReplacingKey = true
        form.key = "sk-new"
        #expect(form.keyToSave == "sk-new")
    }

    @Test func aStoredClientSecretIsMaskedUntilReplaced() {
        var draft = ToolServerConnection.Draft(name: "GitHub", url: "https://api.githubcopilot.com/mcp/", type: .mcp, authType: .oauth21Static, oauthClientID: "Ov23li")
        draft.oauthClientSecret = "s3cr3t"
        let existing = ToolServerConnection.shared(draft, serverID: "github")
        let form = ConnectorForm(kind: .shared, existing: existing)
        #expect(!form.isReplacingSecret)
        #expect(form.clientSecretError == nil && form.isValid)
        #expect(form.secretToSave == nil, "keeps the stored secret")
        #expect(form.clientSecret.isEmpty && form.draft.oauthClientSecret.isEmpty, "the secret is never copied into the form")
        #expect(form.draft.oauthClientID == "Ov23li")
        form.isReplacingSecret = true
        #expect(form.clientSecretError != nil)
        form.clientSecret = "n3w"
        #expect(form.secretToSave == "n3w")

        let fresh = ConnectorForm(kind: .shared)
        fresh.draft.name = "GitHub"
        fresh.draft.url = "https://api.githubcopilot.com/mcp/"
        fresh.draft.authType = .oauth21Static
        #expect(fresh.clientIDError == "Paste the OAuth app's client ID.")
        #expect(fresh.clientSecretError == "Paste the OAuth app's client secret.")
        fresh.draft.type = .openAPI
        fresh.typeChanged()
        #expect(fresh.draft.authType == .none, "static OAuth is for MCP servers too")
    }
}

@Suite("Connector access (#186)")
struct ConnectorAccessTests {
    @Test func gating() throws {
        let admin = try JSONDecoder().decode(SessionUser.self, from: Fixture.data("auths.json"))
        let on = ServerFeatures(raw: ["enable_tool_servers": .bool(true)])
        let off = ServerFeatures(raw: ["enable_tool_servers": .bool(false)])
        #expect(ConnectorAccess(user: admin, features: on) == ConnectorAccess(isAdmin: true, toolServersEnabled: true, personalPermitted: true))
        #expect(ConnectorAccess(user: admin, features: off).personalUnavailableReason == .toolServersOff)
        #expect(!ConnectorAccess(user: admin, features: off).canManageShared)

        let user = SessionUser(id: "u", name: "U", email: "u@example.com", role: .user, permissions: admin.permissions)
        let denied = ConnectorAccess(user: user, features: on)
        #expect(denied.personalUnavailableReason == .notPermitted, "direct_tool_servers is off on the recorded Server")
        #expect(!denied.canManageShared)
        let allowed = SessionUser(id: "u", name: "U", email: "u@example.com", role: .user,
                                  permissions: UserPermissions(raw: .object(["features": .object(["direct_tool_servers": .bool(true)])])))
        #expect(ConnectorAccess(user: allowed, features: on).canUsePersonal)
    }
}
