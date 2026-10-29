import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Connectors & tools (CONN-*): the tools list, OAuth sessions, `tool_ids` and extra variables on
/// completions, and the refusal for browser-only code execution.
@Suite("Connector endpoints")
struct ConnectorEndpointTests {
    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    @Test func recordedServerHasNoConnectors() throws {
        #expect(request(.tools).url?.absoluteString == "https://owui.example.com/api/v1/tools/")
        #expect(try Endpoint.tools.decode(Fixture.data("tools.json")).isEmpty)
    }

    @Test func toolsDecodeAllThreeKinds() throws {
        let tools = try Endpoint.tools.decode(Fixture.data("synthetic/tools.mixed.json"))
        #expect(tools.map(\.id) == ["weather", "server:crm", "server:mcp:linear", "server:mcp:docs", "server:mcp:search"])
        #expect(tools.map(\.kind) == [.workspaceTool, .toolServer, .mcpServer, .mcpServer, .mcpServer])

        let weather = tools[0]
        #expect(weather.description == "Current conditions and forecasts.")
        #expect(weather.hasUserValves)
        #expect(!weather.requiresSignIn && weather.isUsable)

        let linear = tools[2]
        #expect(linear.mcpServerID == "linear")
        #expect(linear.oauthClientID == "mcp:linear")
        #expect(linear.requiresSignIn && !linear.isUsable)
        let authorize = try #require(linear.authorizationURL(server: Fixture.serverURL))
        #expect(authorize.host() == "owui.example.com")
        #expect(authorize.path(percentEncoded: false) == "/oauth/clients/mcp:linear/authorize")

        let docs = tools[3]
        #expect(docs.description == nil, "empty descriptions are dropped")
        #expect(docs.isUsable && docs.requiresSignIn)

        let search = tools[4]
        #expect(!search.requiresSignIn, "MCP servers without OAuth need no connect step")
        #expect(search.authorizationURL(server: Fixture.serverURL) == nil)
        #expect(tools[1].authorizationURL(server: Fixture.serverURL) == nil)
    }

    @Test func disconnectDeletesTheOAuthSession() throws {
        let delete = request(.disconnectOAuthSession(provider: "mcp:linear"))
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path(percentEncoded: false) == "/api/v1/auths/oauth/sessions/mcp:linear")
        #expect(try Endpoint.disconnectOAuthSession(provider: "mcp:linear").decode(Fixture.data("synthetic/oauth-session.delete.json")))
    }

    @Test func modelPresetsCarryTheirConnectors() throws {
        let data = Data(#"{"data":[{"id":"helper","name":"Helper","info":{"meta":{"toolIds":["weather","server:mcp:docs"]}}}]}"#.utf8)
        let models = try Endpoint.models.decode(data)
        #expect(models.first?.toolIDs == ["weather", "server:mcp:docs"])
        let recorded = try Endpoint.models.decode(Fixture.data("models.json"))
        #expect(recorded.allSatisfy { $0.toolIDs.isEmpty })
    }

    @Test func recordedConfigReportsThePyodideEngine() throws {
        let config = try Endpoint.config.decode(Fixture.data("config.json"))
        #expect(config.features.codeInterpreterEngine == "pyodide")
        #expect(!config.features.runsCodeServerSide)
        let publicConfig = try Endpoint.config.decode(Fixture.data("config.public.json"))
        #expect(publicConfig.features.codeInterpreterEngine == nil)
    }

    // MARK: Completion body

    private func socketBody(_ request: CompletionRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: CompletionSession.socketBody(request, sessionID: "sid"))
    }

    @Test func enabledConnectorsGoOutAsToolIDs() throws {
        var request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi")
        #expect(try socketBody(request)[path: "tool_ids"] == nil, "no key without Connectors")
        request.toolIDs = ["weather", "server:mcp:docs"]
        #expect(try socketBody(request)[path: "tool_ids"] == .array([.string("weather"), .string("server:mcp:docs")]))
        let sse = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.sseBody(request))
        #expect(sse[path: "tool_ids"] == .array([.string("weather"), .string("server:mcp:docs")]))
    }

    @Test func extraVariablesJoinPersonalization() throws {
        var request = CompletionRequest(
            chatID: "c1", modelID: "m", prompt: "hi",
            personalization: ChatPersonalization(instructions: nil, preferredName: "Ada", usesMemory: false)
        )
        request.variables = ["{{USER_LOCATION}}": "48.137, 11.575 (lat, long)"]
        let variables = try socketBody(request)[path: "variables"]
        #expect(variables?.objectValue?["{{USER_NAME}}"] == .string("Ada"))
        #expect(variables?.objectValue?["{{USER_LOCATION}}"] == .string("48.137, 11.575 (lat, long)"))

        var anonymous = CompletionRequest(chatID: nil, modelID: "m", prompt: "hi")
        anonymous.variables = ["{{USER_LOCATION}}": "1, 2 (lat, long)"]
        let sse = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.sseBody(anonymous))
        #expect(sse[path: "variables"]?.objectValue?["{{USER_LOCATION}}"] == .string("1, 2 (lat, long)"))
    }

    // MARK: Browser-only calls (CONN-08)

    @Test func pyodideRunsAreRefusedWithAnErrorTheModelCanRead() {
        let envelope: JSONValue = .object([
            "chat_id": .string("c1"),
            "message_id": .string("m1"),
            "data": .object([
                "type": .string("execute:python"),
                "data": .object(["id": .string("run"), "code": .string("print(1)"), "session_id": .string("sid")]),
            ]),
        ])
        let decoded = ChatEventDecoder.decode(envelope, ackID: 7)
        #expect(decoded.map(\.kind) == [.unsupportedCall(type: "execute:python", ackID: 7)])

        let refusal = CompletionSession.refusal(for: "execute:python")
        #expect(refusal[path: "error"]?.stringValue?.contains("Jupyter") == true)
        #expect(CompletionSession.refusal(for: "confirmation") == .bool(false))
        #expect(CompletionSession.refusal(for: "execute:tool")[path: "error"] != nil)
    }
}
