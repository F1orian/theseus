@testable import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Sends carry the Chat's Connectors as `tool_ids` (CONN-02) and the app's extra prompt
/// variables such as `{{USER_LOCATION}}` (CONN-07).
@Suite("Connector requests", .serialized)
@MainActor
struct ConnectorRequestTests {
    private func sentBody(capabilities: Set<Capability>, configure: (ChatServices, ConversationModel) -> Void) async throws -> JSONValue {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay, capabilities: capabilities)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        configure(services, model)
        await send(model, "[theseus-test] What is a maze?")
        let request = try #require(transport.requests.first { $0.url?.path() == "/api/chat/completions" })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(await until { !model.isStreaming })
        await services.stop()
        return body
    }

    @Test func enabledConnectorsAndLocationReachTheRequest() async throws {
        let body = try await sentBody(capabilities: Set(Capability.allCases)) { services, model in
            services.requestVariables = { ["{{USER_LOCATION}}": "48.137, 11.575 (lat, long)"] }
            model.composer.setTool("server:mcp:docs", on: true)
            model.composer.setTool("weather", on: true)
        }
        #expect(body[path: "tool_ids"] == .array([.string("server:mcp:docs"), .string("weather")]))
        #expect(body[path: "variables"]?.objectValue?["{{USER_LOCATION}}"] == .string("48.137, 11.575 (lat, long)"))
    }

    @Test func connectorsStayOffWithoutTheCapability() async throws {
        let body = try await sentBody(capabilities: Set(Capability.allCases).subtracting([.connectors])) { _, model in
            model.composer.setTool("weather", on: true)
        }
        #expect(body[path: "tool_ids"] == nil)
    }
}
