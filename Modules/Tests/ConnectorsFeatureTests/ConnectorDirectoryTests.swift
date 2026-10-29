import ComposerFeature
@testable import ConnectorsFeature
import Fixtures
import Foundation
import OpenWebUIKit
import SettingsFeature
import Synchronization
import Testing

final class StaticToken: RequestAuthorizer {
    let token: String?
    init(_ token: String? = "jwt") { self.token = token }
    func currentToken() async -> String? { token }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

@MainActor
func makeDirectory(_ transport: StubTransport, token: String? = "jwt") -> ConnectorDirectory {
    ConnectorDirectory(client: OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken(token)))
}

@Suite("Connector directory (CONN-02..05)")
@MainActor
struct ConnectorDirectoryTests {
    @Test func listsEveryKindAToZAndSplitsUsableFromAwaitingConnection() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        let directory = makeDirectory(transport)
        await directory.load()

        #expect(directory.state == .loaded)
        #expect(directory.connectors.map(\.name) == ["Atlas search", "Company docs", "Customer records", "Linear", "Weather"])
        #expect(directory.usable.map(\.id) == ["server:mcp:search", "server:mcp:docs", "server:crm", "weather"])
        #expect(directory.directory.map(\.id) == ["server:mcp:docs", "server:mcp:linear"], "only OAuth MCP servers")
        #expect(directory.awaitingConnection.map(\.id) == ["server:mcp:linear"])
    }

    @Test func emptyServerIsLoadedAndEmpty() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "tools.json")
        let directory = makeDirectory(transport)
        await directory.load()
        #expect(directory.state == .loaded)
        #expect(directory.connectors.isEmpty)
    }

    @Test func failuresKeepThePreviousList() async throws {
        let transport = StubTransport()
        let directory = makeDirectory(transport)
        transport.stub("GET", "api/v1/tools/", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        await directory.load()
        #expect(directory.state == .failed("boom"))

        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        await directory.load()
        transport.stub("GET", "api/v1/tools/", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        await directory.load()
        #expect(directory.state == .loaded)
        #expect(directory.connectors.count == 5)
        #expect(directory.notice == "boom")
    }

    // MARK: CONN-04

    @Test func searchMatchesNameAndDescriptionWordsAndStaysAlphabetical() async throws {
        let tools = try JSONDecoder().decode([ToolEntry].self, from: Fixture.data("synthetic/tools.mixed.json"))
        #expect(ConnectorCatalog.filter(tools, matching: "").map(\.name) == ["Atlas search", "Company docs", "Customer records", "Linear", "Weather"])
        #expect(ConnectorCatalog.filter(tools, matching: "LIN").map(\.name) == ["Linear"])
        #expect(ConnectorCatalog.filter(tools, matching: "orders").map(\.name) == ["Customer records"], "description")
        #expect(ConnectorCatalog.filter(tools, matching: "search knowledge").map(\.name) == ["Atlas search"], "every word")
        #expect(ConnectorCatalog.filter(tools, matching: "nothing like it").isEmpty)
    }

    // MARK: CONN-03

    @Test func connectingStartsTheServersOAuthFlowSignedIn() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        let directory = makeDirectory(transport)
        await directory.load()
        let linear = try #require(directory.connector(id: "server:mcp:linear"))

        let authorization = try #require(await directory.connection(for: linear))
        #expect(authorization.startURL.path(percentEncoded: false) == "/oauth/clients/mcp:linear/authorize")
        #expect(authorization.sessionToken == "jwt")
        #expect(authorization.startRequest.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        let cookie = try #require(authorization.sessionCookie)
        #expect(cookie.name == "token" && cookie.value == "jwt" && cookie.domain == "owui.example.com" && cookie.isSecure)

        // Tools without a sign-in have nothing to connect.
        #expect(await directory.connection(for: try #require(directory.connector(id: "weather"))) == nil)
    }

    @Test func accountsWithoutASessionTokenCannotConnect() async throws {
        let tools = try JSONDecoder().decode([ToolEntry].self, from: Fixture.data("synthetic/tools.mixed.json"))
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken(nil))
        let directory = ConnectorDirectory(client: client, connectors: tools)
        let linear = try #require(directory.connector(id: "server:mcp:linear"))
        #expect(await directory.connection(for: linear) == nil)
        #expect(directory.notice?.contains("signed-in session") == true)
    }

    @Test func finishingReloadsAndReportsWhetherItWorked() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        let directory = makeDirectory(transport)
        await directory.load()

        // The Server still says "not authenticated": the flow didn't stick.
        #expect(await directory.connectionFinished("server:mcp:linear", result: .finished) == false)
        #expect(directory.notice == "Linear didn't finish connecting. Try again.")

        directory.notice = nil
        let connected = try String(decoding: Fixture.data("synthetic/tools.mixed.json"), as: UTF8.self)
            .replacingOccurrences(of: #""authenticated": false"#, with: #""authenticated": true"#)
        transport.stub("GET", "api/v1/tools/", body: Data(connected.utf8))
        #expect(await directory.connectionFinished("server:mcp:linear", result: .finished))
        #expect(directory.notice == nil)
        #expect(directory.awaitingConnection.isEmpty)

        #expect(await directory.connectionFinished("server:mcp:linear", result: .failed("access_denied")))
        #expect(directory.notice == "Couldn't connect. access_denied")
    }

    // MARK: CONN-05

    @Test func disconnectDeletesTheSessionAndReloads() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        try transport.stub("DELETE", "api/v1/auths/oauth/sessions/mcp:docs", fixture: "synthetic/oauth-session.delete.json")
        let directory = makeDirectory(transport)
        await directory.load()
        let docs = try #require(directory.connector(id: "server:mcp:docs"))
        #expect(directory.canDisconnect(docs))
        #expect(!directory.canDisconnect(try #require(directory.connector(id: "weather"))), "no session to end")
        #expect(!directory.canDisconnect(try #require(directory.connector(id: "server:mcp:linear"))), "not connected")

        await directory.disconnect(docs)
        let methods = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path(percentEncoded: false) ?? "")" }
        #expect(methods.suffix(2) == ["DELETE /api/v1/auths/oauth/sessions/mcp:docs", "GET /api/v1/tools/"])
        #expect(directory.notice == nil)
    }

    @Test func failedDisconnectExplains() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        transport.stub("DELETE", "api/v1/auths/oauth/sessions/mcp:docs", status: 500, body: Data(#"{"detail":"nope"}"#.utf8))
        let directory = makeDirectory(transport)
        await directory.load()
        await directory.disconnect(try #require(directory.connector(id: "server:mcp:docs")))
        #expect(directory.notice == "Couldn't disconnect Company docs. nope")
    }

    // MARK: Registration (ADR 0006)

    @Test func settingsRowsAppearOnlyWhenTheServerHasConnectors() {
        let directory = makeDirectory(StubTransport())
        let location = LocationSharing(accountKey: "t", provider: FakeLocation())
        var without = SettingsExtensions()
        ConnectorsRegistration.register(in: &without, directory: directory, location: location, capabilities: Capabilities(enabled: []))
        #expect(!without.isRegistered(.connectors))
        #expect(without.isRegistered(.permissions))

        var with = SettingsExtensions()
        ConnectorsRegistration.register(in: &with, directory: directory, location: location, capabilities: Capabilities(enabled: [.connectors]))
        #expect(with.isRegistered(.connectors))
    }

    @Test func addToChatRowCountsTheChatsUsableConnectors() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        let directory = makeDirectory(transport)
        await directory.load()
        var extensions = AddToChatExtensions()
        ConnectorsRegistration.register(in: &extensions, directory: directory)

        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
        let services = ComposerServices(client: client, models: [Model(id: "m", name: "M")], defaultModelIDs: []) { _ in
            Capabilities(enabled: [.connectors])
        }
        let composer = ComposerModel(services: services, selectedModelID: "m")
        #expect(extensions.connectorsValue?(composer) == nil)
        composer.setTool("weather", on: true)
        composer.setTool("server:mcp:linear", on: true) // not connected: doesn't count
        #expect(extensions.connectorsValue?(composer) == "1 on")
        #expect(extensions.connectors != nil)
    }
}
