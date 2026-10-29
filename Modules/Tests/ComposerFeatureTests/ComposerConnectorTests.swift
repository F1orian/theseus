@testable import ComposerFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Connectors per Chat (CONN-02), the code execution switch (CONN-08) and web search consent (CONN-01).
@Suite("Composer Connectors & tools")
@MainActor
struct ComposerConnectorTests {
    private func services(features: [String: JSONValue], models: [Model]) -> ComposerServices {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken())
        return ComposerServices(client: client, models: models, defaultModelIDs: []) { model in
            guard let admin = SessionUserFixture.admin else { return Capabilities(enabled: []) }
            return Capabilities.resolve(features: ServerFeatures(raw: features), user: admin, model: model)
        }
    }

    private let toolsOn: [String: JSONValue] = ["enable_tools": .bool(true), "enable_tool_servers": .bool(true)]

    @Test func connectorsStartFromTheModelPresetAndAreSwitchedPerChat() {
        var preset = Model(id: "helper", name: "Helper", ownedBy: "openai")
        preset.toolIDs = ["weather"]
        let composer = ComposerModel(services: services(features: toolsOn, models: [preset]), selectedModelID: "helper")
        #expect(composer.isToolOn("weather"))
        #expect(!composer.isToolOn("server:mcp:docs"))

        composer.setTool("server:mcp:docs", on: true)
        composer.setTool("weather", on: false)
        #expect(composer.enabledToolIDs == ["server:mcp:docs"])

        composer.text = "What's on my calendar?"
        #expect(composer.submission()?.toolIDs == ["server:mcp:docs"])
        composer.reset()
        #expect(composer.enabledToolIDs == ["server:mcp:docs"], "the choice lasts for the Chat")
    }

    @Test func noToolIDsWhenTheServerHasNoConnectors() {
        var preset = Model(id: "helper", name: "Helper", ownedBy: "openai")
        preset.toolIDs = ["weather"]
        let composer = ComposerModel(services: services(features: [:], models: [preset]), selectedModelID: "helper")
        composer.text = "hi"
        #expect(composer.submission()?.toolIDs == [])
    }

    @Test func codeExecutionIsASwitchOnlyWithAServerSideEngine() {
        let coder = Model(id: "coder", name: "Coder", ownedBy: "openai")
        // `ServerFeatures(raw:)` alone carries no engine (as with Jupyter-less configs), so the flag decides.
        let unknownEngine = ComposerModel(services: services(features: ["enable_code_interpreter": .bool(true)], models: [coder]), selectedModelID: "coder")
        #expect(unknownEngine.availableToggles.contains(.codeInterpreter))
        #expect(FeatureToggle.codeInterpreter.title == "Code execution")

        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken())
        var pyodideFeatures = ServerFeatures(raw: ["enable_code_interpreter": .bool(true)])
        pyodideFeatures.codeInterpreterEngine = "pyodide"
        let pyodide = ComposerServices(client: client, models: [coder], defaultModelIDs: []) { model in
            guard let admin = SessionUserFixture.admin else { return Capabilities(enabled: []) }
            return Capabilities.resolve(features: pyodideFeatures, user: admin, model: model)
        }
        let composer = ComposerModel(services: pyodide, selectedModelID: "coder")
        #expect(!composer.availableToggles.contains(.codeInterpreter))
        composer.text = "plot it"
        #expect(composer.submission()?.features["code_interpreter"] == nil, "never requested where it can't run")
    }

    @Test func webSearchConsentComesFromTheConfig() throws {
        let services = services(features: toolsOn, models: [])
        #expect(services.webSearchConfirmation == nil)
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"""
        {"name":"S","version":"0.12.3","features":{"enable_web_search":true,"enable_web_search_confirmation":true,
         "web_search_confirmation_content":"Queries go to Brave."}}
        """#.utf8))
        services.configure(config: config, accountName: nil)
        #expect(services.webSearchConfirmation == "Queries go to Brave.")
    }
}
