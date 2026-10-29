import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func body(_ request: URLRequest?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(request?.httpBody))
}

private func client(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
}

/// The exact `TOOL_SERVER_CONNECTIONS` entries Theseus writes, one per type × auth (#186). They
/// follow the web admin's "Add Connection" modal (`AddToolServerModal.svelte`), so an entry made
/// in Theseus opens unchanged in the web admin.
@Suite("Shared connection bodies (#186)")
struct SharedConnectionBodyTests {
    private func draft(_ type: ToolServerConnection.ServerType, _ auth: ToolServerConnection.AuthType, key: String = "") -> ToolServerConnection.Draft {
        ToolServerConnection.Draft(
            name: " [theseus-test] Docs ",
            url: type == .openAPI ? "https://tools.example.com/docs/" : "https://mcp.example.com/mcp/",
            type: type,
            specPath: "openapi.json",
            authType: auth,
            key: key,
            description: "Team docs",
            isEnabled: true,
            access: .everyone
        )
    }

    private let everyone = #"[{"principal_type":"user","principal_id":"*","permission":"read"}]"#

    @Test func openAPINone() throws {
        let entry = ToolServerConnection.shared(draft(.openAPI, .none), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"openapi","url":"https://tools.example.com/docs","spec_type":"url","spec":"","path":"openapi.json",
         "auth_type":"none","forward_cookies":false,"key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func openAPIBearer() throws {
        let entry = ToolServerConnection.shared(draft(.openAPI, .bearer, key: "sk-123"), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"openapi","url":"https://tools.example.com/docs","spec_type":"url","spec":"","path":"openapi.json",
         "auth_type":"bearer","forward_cookies":false,"key":"sk-123",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func openAPISession() throws {
        // A key typed before switching away from Bearer is never sent.
        let entry = ToolServerConnection.shared(draft(.openAPI, .session, key: "left-over"), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"openapi","url":"https://tools.example.com/docs","spec_type":"url","spec":"","path":"openapi.json",
         "auth_type":"session","forward_cookies":false,"key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func mcpNone() throws {
        // MCP keeps its trailing slash and has no spec path or cookie forwarding.
        let entry = ToolServerConnection.shared(draft(.mcp, .none), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"mcp","url":"https://mcp.example.com/mcp/","spec_type":"url","spec":"","path":"",
         "auth_type":"none","key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func mcpBearer() throws {
        let entry = ToolServerConnection.shared(draft(.mcp, .bearer, key: "sk-123"), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"mcp","url":"https://mcp.example.com/mcp/","spec_type":"url","spec":"","path":"",
         "auth_type":"bearer","key":"sk-123",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func mcpSession() throws {
        let entry = ToolServerConnection.shared(draft(.mcp, .session), serverID: "theseus-test-docs")
        #expect(entry.jsonValue == (try json("""
        {"type":"mcp","url":"https://mcp.example.com/mcp/","spec_type":"url","spec":"","path":"",
         "auth_type":"session","key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs"}}
        """)))
    }

    @Test func mcpOAuth21() throws {
        var entry = ToolServerConnection.shared(draft(.mcp, .oauth21), serverID: "theseus-test-docs")
        entry.oauthClientInfo = "gAAAAABn-encrypted-client-info"
        #expect(entry.jsonValue == (try json("""
        {"type":"mcp","url":"https://mcp.example.com/mcp/","spec_type":"url","spec":"","path":"",
         "auth_type":"oauth_2.1","key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs",
                 "oauth_resource_parameter":"auto","oauth_client_info":"gAAAAABn-encrypted-client-info"}}
        """)))
        #expect(entry.toolID == "server:mcp:theseus-test-docs")
    }

    /// #193: OAuth 2.1 with the admin's own OAuth app, as the web admin saves `oauth_2.1_static`.
    @Test func mcpOAuth21Static() throws {
        var static21 = draft(.mcp, .oauth21Static, key: "left-over")
        static21.oauthClientID = " Ov23liExampleClient "
        static21.oauthClientSecret = "s3cr3t"
        static21.oauthScope = " repo read:org "
        var entry = ToolServerConnection.shared(static21, serverID: "theseus-test-docs")
        entry.oauthClientInfo = "gAAAAABn-encrypted-static-client-info"
        #expect(entry.jsonValue == (try json("""
        {"type":"mcp","url":"https://mcp.example.com/mcp/","spec_type":"url","spec":"","path":"",
         "auth_type":"oauth_2.1_static","key":"",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":\(everyone)},
         "info":{"id":"theseus-test-docs","name":"[theseus-test] Docs","description":"Team docs",
                 "oauth_resource_parameter":"auto","oauth_scope":"repo read:org",
                 "oauth_client_id":"Ov23liExampleClient","oauth_client_secret":"s3cr3t","oauth_server_url":"",
                 "oauth_client_info":"gAAAAABn-encrypted-static-client-info"}}
        """)))
        #expect(entry.draft.oauthClientID == "Ov23liExampleClient")
        #expect(entry.draft.oauthScope == "repo read:org")
        #expect(entry.draft.oauthClientSecret.isEmpty, "the secret is never copied into the form")

        // Without a scope there's no `oauth_scope` (the Server uses the discovered scopes).
        var bare = static21
        bare.oauthScope = ""
        #expect(ToolServerConnection.shared(bare, serverID: "x").jsonValue[path: "info.oauth_scope"] == nil)
    }

    @Test func editingAStaticOAuthEntryKeepsOrReplacesTheSecret() {
        var static21 = draft(.mcp, .oauth21Static)
        static21.oauthClientID = "client-a"
        static21.oauthClientSecret = "secret-a"
        var stored = ToolServerConnection.shared(static21, serverID: "gh")
        stored.oauthClientInfo = "blob"

        var edit = stored.draft
        edit.description = "Repos"
        let kept = stored.applying(edit, key: nil, clientSecret: nil)
        #expect(kept.oauthClientSecret == "secret-a" && kept.oauthClientID == "client-a" && kept.oauthClientInfo == "blob")
        #expect(kept.description == "Repos")

        edit.oauthClientID = "client-b"
        let replaced = stored.applying(edit, key: nil, clientSecret: "secret-b")
        #expect(replaced.oauthClientSecret == "secret-b" && replaced.oauthClientID == "client-b")

        // Leaving static OAuth drops the app's credentials.
        edit.authType = .bearer
        let bearer = stored.applying(edit, key: "ghp_token", clientSecret: nil)
        #expect(bearer.key == "ghp_token")
        #expect(bearer.jsonValue[path: "info.oauth_client_secret"] == nil)
        #expect(bearer.jsonValue[path: "info.oauth_client_id"] == nil)
    }

    @Test func theCallbackURLIsTheServersRedirectURI() {
        #expect(ToolServerConnection.oauthCallbackURL(base: "https://chat.example.com/", serverID: "github")
            == "https://chat.example.com/oauth/clients/mcp:github/callback")
        #expect(ToolServerConnection.oauthCallbackURL(base: "http://localhost:8765", serverID: "theseus-test-github")
            == "http://localhost:8765/oauth/clients/mcp:theseus-test-github/callback")
    }

    @Test func whoCanUseItMapsToAccessGrants() throws {
        var groups = draft(.mcp, .none)
        groups.access = ToolServerAccess(.groups(["g1", "g2"]))
        let grouped = ToolServerConnection.shared(groups, serverID: "x")
        #expect(grouped.jsonValue[path: "config.access_grants"] == (try json("""
        [{"principal_type":"group","principal_id":"g1","permission":"read"},
         {"principal_type":"group","principal_id":"g2","permission":"read"}]
        """)))
        #expect(grouped.access.audience == .groups(["g1", "g2"]))

        var mine = draft(.mcp, .none)
        mine.access = .adminsOnly
        let adminsOnly = ToolServerConnection.shared(mine, serverID: "x")
        #expect(adminsOnly.jsonValue[path: "config.access_grants"] == .array([]))
        #expect(adminsOnly.access.audience == .adminsOnly)
    }

    @Test func serverIDsAreSlugsAndUnique() {
        #expect(ToolServerConnection.serverID(for: "[theseus-test] Docs", avoiding: []) == "theseus-test-docs")
        #expect(ToolServerConnection.serverID(for: "Café  Notes!", avoiding: []) == "cafe-notes")
        #expect(ToolServerConnection.serverID(for: "Docs", avoiding: ["docs", "docs-2"]) == "docs-3")
        #expect(ToolServerConnection.serverID(for: "✨", avoiding: []) == "connector")
    }
}

/// Personal connectors (direct tool servers in `ui.toolServers`): OpenAPI only, shaped like the
/// web client's Settings › Integrations entries, the bearer key included (#189).
@Suite("Personal connector bodies (#186, #189)")
struct PersonalConnectorBodyTests {
    private func entry(_ auth: ToolServerConnection.AuthType) -> ToolServerConnection {
        ToolServerConnection.personal(ToolServerConnection.Draft(
            name: "[theseus-test] Notes", url: "http://localhost:8766/", type: .openAPI, specPath: "openapi.json",
            authType: auth, key: "sk-key", description: "", isEnabled: true, access: .everyone
        ))
    }

    @Test(arguments: [ToolServerConnection.AuthType.none, .bearer, .session])
    func personalEntry(auth: ToolServerConnection.AuthType) throws {
        #expect(entry(auth).jsonValue == (try json("""
        {"type":"openapi","url":"http://localhost:8766","spec_type":"url","spec":"","path":"openapi.json",
         "auth_type":"\(auth.wireValue)","key":"\(auth == .bearer ? "sk-key" : "")",
         "config":{"enable":true,"function_name_filter_list":"","access_grants":[]},
         "info":{"id":"","name":"[theseus-test] Notes","description":""}}
        """)))
    }

    @Test func aPastedSpecIsReadAndKeepsItsPathOnEdit() throws {
        var raw = entry(.none).raw
        raw["spec_type"] = .string("json")
        raw["spec"] = .string(#"{"openapi":"3.1.0","paths":{}}"#)
        raw["path"] = .string("")
        let pasted = ToolServerConnection(raw: raw)
        #expect(pasted.hasInlineSpec)
        #expect(pasted.inlineSpec?[path: "openapi"] == .string("3.1.0"))
        var edit = pasted.draft
        edit.name = "Renamed"
        #expect(pasted.applying(edit, key: nil).path == "", "a pasted spec has no path to set")
        #expect(entry(.none).inlineSpec == nil)
    }

    @Test func personalIDsComeFromTheURL() {
        #expect(entry(.none).id == "url:http://localhost:8766|openapi.json")
        #expect(entry(.none).specURL?.absoluteString == "http://localhost:8766/openapi.json")
    }
}

@Suite("Tool server endpoints (#186)")
struct ToolServerEndpointTests {
    let transport = StubTransport()

    @Test func decodesTheRecordedEmptyList() async throws {
        try transport.stub("GET", "api/v1/configs/tool_servers", fixture: "tool-servers.json")
        let list = try await client(transport).send(.toolServerConnections)
        #expect(list.connections.isEmpty)
    }

    @Test func decodesWebAdminEntries() throws {
        let list = try JSONDecoder().decode(ToolServerConnections.self, from: Fixture.data("synthetic/tool-servers.mixed.json"))
        #expect(list.connections.count == 3)
        let weather = list.connections[0]
        #expect(weather.type == .openAPI && weather.authType == .bearer && weather.isEnabled)
        #expect(weather.serverID == "" && weather.id == "url:https://tools.example.com/weather|openapi.json")
        #expect(weather.access.audience == .groups(["g-research"]))
        let notion = list.connections[1]
        #expect(notion.type == .mcp && notion.authType == .oauth21 && notion.toolID == "server:mcp:notion")
        #expect(notion.access.audience == .everyone)
        let sso = list.connections[2]
        #expect(sso.authType == .systemOAuth && !sso.isEnabled && sso.access.audience == .adminsOnly)
        #expect(sso.specURL?.absoluteString == "https://sso-tools.example.com/spec.yaml")
    }

    /// Read-modify-write: the list is re-read right before the write, only our entry changes,
    /// and every other entry (unknown fields, keys, headers) goes back byte-for-byte equal.
    @Test func addingKeepsOtherEntriesExactly() async throws {
        let stored = try Fixture.data("synthetic/tool-servers.mixed.json")
        try transport.stub("GET", "api/v1/configs/tool_servers", fixture: "synthetic/tool-servers.mixed.json")
        transport.stub("POST", "api/v1/configs/tool_servers") { request in (200, request.httpBody ?? Data()) }
        let added = ToolServerConnection.shared(.init(name: "Docs", url: "https://mcp.example.com/mcp", type: .mcp), serverID: "docs")

        let result = try await client(transport).updateToolServerConnections { list throws(ToolServerEditError) in
            try list.add(added)
        }

        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /api/v1/configs/tool_servers", "POST /api/v1/configs/tool_servers",
        ])
        let sent = try body(transport.requests.last)
        let original = try JSONDecoder().decode(JSONValue.self, from: stored)
        let sentList = try #require(sent[path: "TOOL_SERVER_CONNECTIONS"]?.arrayValue)
        let originalList = try #require(original[path: "TOOL_SERVER_CONNECTIONS"]?.arrayValue)
        #expect(Array(sentList.prefix(3)) == originalList)
        #expect(sentList.last == added.jsonValue)
        #expect(result.count == 4)
    }

    @Test func editingAndRemovingTouchOnlyTheirEntry() async throws {
        try transport.stub("GET", "api/v1/configs/tool_servers", fixture: "synthetic/tool-servers.mixed.json")
        transport.stub("POST", "api/v1/configs/tool_servers") { request in (200, request.httpBody ?? Data()) }
        let list = try JSONDecoder().decode(ToolServerConnections.self, from: Fixture.data("synthetic/tool-servers.mixed.json")).connections
        var edited = list[2]
        edited.isEnabled = true
        let sso = edited

        try await client(transport).updateToolServerConnections { list throws(ToolServerEditError) in
            try list.replace(sso.id, with: sso)
        }
        var sent = try #require(try body(transport.requests.last)[path: "TOOL_SERVER_CONNECTIONS"]?.arrayValue)
        #expect(sent[0] == list[0].jsonValue && sent[1] == list[1].jsonValue)
        #expect(sent[2][path: "config.enable"] == .bool(true))
        #expect(sent[2][path: "info"] == list[2].jsonValue[path: "info"])

        try await client(transport).updateToolServerConnections { list throws(ToolServerEditError) in
            try list.remove(list[1].id)
        }
        sent = try #require(try body(transport.requests.last)[path: "TOOL_SERVER_CONNECTIONS"]?.arrayValue)
        #expect(sent == [list[0].jsonValue, list[2].jsonValue])
    }

    @Test func editsOfAnEntryRemovedMeanwhileFail() async throws {
        try transport.stub("GET", "api/v1/configs/tool_servers", fixture: "tool-servers.json")
        let gone = ToolServerConnection.shared(.init(name: "Gone", url: "https://x.example.com", type: .mcp), serverID: "gone")
        await #expect(throws: ToolServerEditError.missing("Gone")) {
            try await client(transport).updateToolServerConnections { list throws(ToolServerEditError) in
                try list.replace(gone.id, with: gone)
            }
        }
        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" }, "Nothing is written")
    }

    @Test func aConcurrentAddOfTheSameNameIsReappliedUnderAFreshID() throws {
        var fresh = [ToolServerConnection.shared(.init(name: "Docs", url: "https://a.example.com", type: .mcp), serverID: "docs")]
        try fresh.add(ToolServerConnection.shared(.init(name: "Docs", url: "https://b.example.com", type: .mcp), serverID: "docs"))
        #expect(fresh.map(\.serverID) == ["docs", "docs-2"])

        var registered = ToolServerConnection.shared(.init(name: "Docs", url: "https://b.example.com", type: .mcp, authType: .oauth21), serverID: "docs")
        registered.oauthClientInfo = "encrypted"
        #expect(throws: ToolServerEditError.conflict("Docs")) { try fresh.add(registered) }
    }

    @Test func verifyBodyIsTheConnection() async throws {
        try transport.stub("POST", "api/v1/configs/tool_servers/verify", fixture: "synthetic/tool-server.verify-mcp.json")
        let entry = ToolServerConnection.shared(.init(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", type: .mcp), serverID: "deepwiki")
        let result = try await client(transport).send(.verifyToolServer(entry))
        #expect(try body(transport.requests.last) == entry.jsonValue)
        #expect(result.tools?.map(\.name) == ["read_wiki_structure", "read_wiki_contents", "ask_question"])
    }

    @Test func verifyResultsForEachKind() throws {
        let oauth = ToolServerVerification(raw: try JSONDecoder().decode(JSONValue.self, from: Fixture.data("synthetic/tool-server.verify-oauth.json")))
        #expect(oauth.tools == nil)
        #expect(oauth.oauthIssuer == "https://mcp.example.com/")

        let openAPI = ToolServerVerification(raw: try JSONDecoder().decode(JSONValue.self, from: Fixture.data("synthetic/openapi.notes.json")))
        #expect(openAPI.title == "[theseus-test] Notes")
        #expect(Set(openAPI.tools?.map(\.name) ?? []) == ["list_notes", "add_note", "get_note", "update_note"])
    }

    @Test func verifyErrorsCarryTheServersDetail() async throws {
        try transport.stub("POST", "api/v1/configs/tool_servers/verify", status: 400, fixture: "synthetic/tool-server.verify-error.json")
        let entry = ToolServerConnection.shared(.init(name: "Down", url: "https://down.example.com", type: .openAPI), serverID: "down")
        await #expect(throws: OpenWebUIError.server(status: 400, detail: "Failed to connect to the tool server")) {
            try await client(transport).send(.verifyToolServer(entry))
        }
    }

    @Test func oauthRegistrationMatchesTheWebAdmin() async throws {
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register.json")
        let registration = try await client(transport).send(.registerOAuthClient(url: "https://mcp.example.com/mcp", serverID: "notion"))
        let request = try #require(transport.requests.last)
        #expect(request.url?.query() == "type=mcp")
        #expect(try body(request) == (try json(#"{"url":"https://mcp.example.com/mcp","client_id":"notion"}"#)))
        #expect(registration.clientInfo == "gAAAAABn-encrypted-client-info")
    }

    /// #193: the web admin's "Register Client" for `oauth_2.1_static`: the connection id as
    /// `client_id`, the app's secret, and the (empty) OAuth server URL; the app's client id isn't sent.
    @Test func staticOAuthRegistrationMatchesTheWebAdmin() async throws {
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", fixture: "synthetic/oauth-client.register-static.json")
        let registration = try await client(transport).send(.registerOAuthClient(
            url: "https://api.githubcopilot.com/mcp/", serverID: "github", scope: "repo", staticCredentials: ("s3cr3t", "")
        ))
        let request = try #require(transport.requests.last)
        #expect(request.url?.query() == "type=mcp")
        #expect(try body(request) == (try json("""
        {"url":"https://api.githubcopilot.com/mcp/","client_id":"github","client_secret":"s3cr3t","oauth_server_url":"","oauth_scope":"repo"}
        """)))
        #expect(registration.clientInfo == "gAAAAABn-encrypted-static-client-info")
    }

    @Test func aProviderWithoutDynamicRegistrationIsRecognised() async throws {
        try transport.stub("POST", "api/v1/configs/oauth/clients/register", status: 400, fixture: "synthetic/oauth-client.register-dcr-unsupported.json")
        do {
            _ = try await client(transport).send(.registerOAuthClient(url: "https://api.githubcopilot.com/mcp/", serverID: "github"))
            Issue.record("registration should fail")
        } catch {
            #expect(OAuthClientRegistration.isDynamicRegistrationUnsupported(error))
        }
        #expect(OAuthClientRegistration.isDynamicRegistrationUnsupported(.server(status: 400, detail: "Failed to register OAuth client: Error parsing client registration response")))
        #expect(!OAuthClientRegistration.isDynamicRegistrationUnsupported(.server(status: 400, detail: "Failed to register OAuth client: Failed to discover OAuth metadata")))
        #expect(!OAuthClientRegistration.isDynamicRegistrationUnsupported(.transport(.timedOut)))
        #expect(!OAuthClientRegistration.isDynamicRegistrationUnsupported(.forbidden(detail: "Tool servers are disabled")))
    }

    @Test func adminConfigCarriesTheWebUIURL() async throws {
        try transport.stub("GET", "api/v1/auths/admin/config", fixture: "synthetic/auths.admin-config.json")
        let config = try await client(transport).send(.adminConfig)
        #expect(config.webUIURL == "https://owui.example.com")
        #expect(try JSONDecoder().decode(ServerAdminConfig.self, from: Data("{}".utf8)).webUIURL == nil)
    }
}

@Suite("Default user permissions (#186)")
struct DefaultUserPermissionsTests {
    @Test func setKeepsEveryOtherKey() throws {
        let recorded = try JSONDecoder().decode(DefaultUserPermissions.self, from: Fixture.data("users.default-permissions.json"))
        #expect(!recorded.allows(DefaultUserPermissions.personalConnectors))
        var changed = recorded
        changed.set(DefaultUserPermissions.personalConnectors, to: true)
        #expect(changed.allows(DefaultUserPermissions.personalConnectors))
        var raw = recorded.raw.objectValue ?? [:]
        var features = raw["features"]?.objectValue ?? [:]
        features["direct_tool_servers"] = .bool(true)
        raw["features"] = .object(features)
        #expect(changed.raw == .object(raw))
    }
}
