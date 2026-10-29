@testable import ComposerFeature
import ChatDomain
import Entitlements
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Theseus Pro in the composer (ADR 0173): Voice mode and Skills open the paywall in the free
/// tier, and the sandbox goes quiet once today's free runs are used up.
@MainActor
@Suite("Theseus Pro in the composer")
struct ProGateComposerTests {
    private func composer(pro: ProStore) -> ComposerModel {
        var coder = model("coder", capabilities: ["file_upload": true, "terminal": true])
        coder.terminalID = "demo-sandbox"
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken())
        let services = ComposerServices(client: client, models: [coder], defaultModelIDs: []) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        services.setTerminals([TerminalServer(id: "demo-sandbox", name: "Sandbox", uploadMode: .filesystem)])
        services.pro = pro
        let composer = ComposerModel(services: services, selectedModelID: "coder")
        composer.chatID = "c1"
        return composer
    }

    @Test func voiceModeAsksForProInTheFreeTier() {
        let composer = composer(pro: .free())
        var started = false
        composer.startVoiceMode { started = true }
        #expect(!started)
        #expect(composer.paywallRequest == PaywallRequest(.voiceMode))
    }

    @Test func voiceModeStartsWithPro() {
        let composer = composer(pro: .unlocked())
        var started = false
        composer.startVoiceMode { started = true }
        #expect(started)
        #expect(composer.paywallRequest == nil)
    }

    @Test func removingASkillIsNeverGated() {
        let pro = ProStore.unlocked()
        let composer = composer(pro: pro)
        composer.setSkill("xlsx", selected: true)
        #expect(composer.selectedSkillIDs == ["xlsx"])
        composer.services.pro = .free()
        composer.setSkill("xlsx", selected: false)
        #expect(composer.selectedSkillIDs.isEmpty)
        #expect(composer.paywallRequest == nil)
    }

    @Test func theAllowanceDecidesTheSandbox() {
        let allowance = SandboxAllowance(limit: 1)
        let composer = composer(pro: .free(allowance: allowance))
        #expect(composer.terminalID == "demo-sandbox")
        #expect(composer.sandboxAllowanceSummary == "1 of 1 free runs left today")
        #expect(!composer.sandboxAllowanceExhausted)
        allowance.recordUse()
        #expect(composer.terminalID == nil)
        #expect(composer.sandboxUploadTerminal == nil, "uploads skip the sandbox too")
        #expect(composer.sandboxAllowanceExhausted)
        // Switched off, there's nothing to say.
        composer.set(.codeInterpreter, on: false)
        #expect(!composer.sandboxAllowanceExhausted)
    }

    /// A model without a terminal on a Jupyter Server: Code execution is the code interpreter.
    private func jupyterComposer(pro: ProStore) -> ComposerModel {
        let analyst = model("analyst", capabilities: ["code_interpreter": true])
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken())
        let jupyter = Set(Capability.allCases).subtracting([.sandbox])
        let services = ComposerServices(client: client, models: [analyst], defaultModelIDs: []) { _ in Capabilities(enabled: jupyter) }
        services.pro = pro
        let composer = ComposerModel(services: services, selectedModelID: "analyst")
        composer.set(.codeInterpreter, on: true)
        composer.text = "Average 3 and 5"
        return composer
    }

    @Test func theCodeInterpreterSharesTheAllowance() throws {
        let allowance = SandboxAllowance(limit: 1)
        let composer = jupyterComposer(pro: .free(allowance: allowance))
        #expect(!composer.codeExecutionUsesSandbox)
        #expect(composer.sandboxAllowanceSummary == "1 of 1 free runs left today")
        #expect(try #require(composer.submission()).features["code_interpreter"] == true)
        allowance.recordUse()
        #expect(composer.sandboxAllowanceExhausted)
        #expect(try #require(composer.submission()).features["code_interpreter"] == false)
        // Switched off, there's nothing to say.
        composer.set(.codeInterpreter, on: false)
        #expect(!composer.sandboxAllowanceExhausted)
    }

    @Test func proSendsTheCodeInterpreterWithoutALine() throws {
        let composer = jupyterComposer(pro: .unlocked())
        #expect(composer.sandboxAllowanceSummary == nil)
        #expect(try #require(composer.submission()).features["code_interpreter"] == true)
    }

    @Test func everySendWhileUsedUpBringsTheNoticeBack() {
        let allowance = SandboxAllowance(limit: 1)
        allowance.recordUse()
        let composer = jupyterComposer(pro: .free(allowance: allowance))
        #expect(composer.sandboxAllowanceExhausted)
        composer.isSandboxNoticeDismissed = true
        // The message went out without Code execution: say so again.
        composer.reset()
        #expect(!composer.isSandboxNoticeDismissed)
        #expect(composer.sandboxAllowanceExhausted)
    }

    // MARK: Connectors (ADR 0173 addendum)

    /// A model the admin set up with the `weather` Connector; `server:mcp:docs` is another one.
    private func connectorComposer(pro: ProStore) -> ComposerModel {
        var helper = model("helper")
        helper.toolIDs = ["weather"]
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport(), authorizer: StaticToken())
        let services = ComposerServices(client: client, models: [helper], defaultModelIDs: []) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        services.pro = pro
        let composer = ComposerModel(services: services, selectedModelID: "helper")
        composer.text = "What's on my calendar?"
        return composer
    }

    @Test func turningOnAConnectorAsksForProInTheFreeTier() throws {
        let composer = connectorComposer(pro: .free())
        #expect(composer.toolNeedsPro("server:mcp:docs"))
        composer.setTool("server:mcp:docs", on: true)
        #expect(composer.paywallRequest == PaywallRequest(.connectors))
        #expect(!composer.isToolOn("server:mcp:docs"))
        #expect(try #require(composer.submission()).toolIDs == ["weather"])
    }

    @Test func theModelsOwnConnectorsStayFree() throws {
        let composer = connectorComposer(pro: .free())
        #expect(!composer.toolNeedsPro("weather"))
        #expect(composer.isToolOn("weather"))
        // Turning it off and on again is never gated.
        composer.setTool("weather", on: false)
        #expect(try #require(composer.submission()).toolIDs == [])
        composer.setTool("weather", on: true)
        #expect(composer.paywallRequest == nil)
        #expect(try #require(composer.submission()).toolIDs == ["weather"])
    }

    @Test func proTurnsOnAnyConnector() throws {
        let composer = connectorComposer(pro: .unlocked())
        composer.setTool("server:mcp:docs", on: true)
        #expect(composer.paywallRequest == nil)
        #expect(try #require(composer.submission()).toolIDs == ["server:mcp:docs", "weather"])
    }

    @Test func connectorsTurnedOnWithProGoQuietWithoutIt() throws {
        // A refund, or the debug override: what Pro turned on stays off until Pro is back.
        let composer = connectorComposer(pro: .unlocked())
        composer.setTool("server:mcp:docs", on: true)
        composer.services.pro = .free()
        #expect(!composer.isToolOn("server:mcp:docs"))
        #expect(composer.enabledToolIDs == ["weather"])
    }

    @Test func proHasNoAllowanceLine() {
        let composer = composer(pro: .unlocked())
        #expect(composer.sandboxAllowanceSummary == nil)
        #expect(composer.terminalID == "demo-sandbox")
    }
}
