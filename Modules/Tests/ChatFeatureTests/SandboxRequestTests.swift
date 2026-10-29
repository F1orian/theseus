@testable import ChatFeature
import ChatDomain
import ComposerFeature
import Entitlements
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Code execution backed by the Server's sandbox (#132, ADR 0120): the model's terminal goes out
/// as `terminal_id` while the switch is on, never together with `features.code_interpreter`; picked
/// Skills go out as `skill_ids` (#140).
@Suite("Sandbox requests", .serialized)
@MainActor
struct SandboxRequestTests {
    private var terminalModel: Model {
        var model = haiku
        model.terminalID = "demo-sandbox"
        return model
    }

    private func sentBody(
        capabilities: Set<Capability>,
        model: Model? = nil,
        configure: (ConversationModel) -> Void = { _ in }
    ) async throws -> JSONValue {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
        let socket = SocketIOClient(server: Fixture.serverURL, connector: replay, backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20))) { "jwt" }
        let session = CompletionSession(client: client, socket: socket, joinTimeout: .milliseconds(800))
        let chosen = model ?? terminalModel
        let services = ChatServices(client: client, session: session, models: [chosen], defaultModelID: chosen.id) { _ in
            Capabilities(enabled: capabilities)
        }
        services.start()
        let conversation = services.newConversation()
        conversation.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        configure(conversation)
        await send(conversation, "[theseus-test] What is a maze?")
        let request = try #require(transport.requests.first { $0.url?.path() == "/api/chat/completions" })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(await until { !conversation.isStreaming })
        await services.stop()
        return body
    }

    private let everything = Set(Capability.allCases)

    @Test func theModelsTerminalGoesOutByDefault() async throws {
        let body = try await sentBody(capabilities: everything)
        #expect(body[path: "terminal_id"]?.stringValue == "demo-sandbox")
        // The sandbox backs Code execution: the browser-only interpreter stays off (ADR 0120).
        #expect(body[path: "features.code_interpreter"] == .bool(false))
    }

    @Test func switchingCodeExecutionOffSendsNoTerminal() async throws {
        let body = try await sentBody(capabilities: everything) { conversation in
            #expect(conversation.composer.availableToggles.contains(.codeInterpreter))
            #expect(conversation.composer.isOn(.codeInterpreter))
            conversation.composer.set(.codeInterpreter, on: false)
        }
        #expect(body[path: "terminal_id"] == nil)
    }

    @Test func withoutTheSandboxCapabilityNoTerminalOrSwitch() async throws {
        let body = try await sentBody(capabilities: everything.subtracting([.sandbox, .codeInterpreter])) { conversation in
            #expect(!conversation.composer.availableToggles.contains(.codeInterpreter))
        }
        #expect(body[path: "terminal_id"] == nil)
        #expect(body[path: "features.code_interpreter"] == nil)
    }

    @Test func aModelWithoutATerminalKeepsTheCodeInterpreter() async throws {
        // A Jupyter Server: the interpreter Capability resolves, the sandbox doesn't (ADR 0092 fallback).
        let body = try await sentBody(capabilities: everything.subtracting([.sandbox]), model: haiku) { conversation in
            conversation.composer.set(.codeInterpreter, on: true)
        }
        #expect(body[path: "terminal_id"] == nil)
        #expect(body[path: "features.code_interpreter"] == .bool(true))
    }

    @Test func pickedSkillsGoOutAsSkillIDs() async throws {
        let body = try await sentBody(capabilities: everything) { conversation in
            conversation.composer.setSkill("deep-research", selected: true)
            conversation.composer.setSkill("xlsx", selected: true)
            conversation.composer.setSkill("xlsx", selected: false)
        }
        #expect(body[path: "skill_ids"] == .array([.string("deep-research")]))
    }

    // MARK: Theseus Pro (ADR 0173)

    @Test func theFreeTierSendsTheSandboxWhileRunsRemainAndReportsTheResponse() async throws {
        let store = ProStore.free(allowance: SandboxAllowance(limit: 2))
        var finished = 0
        let body = try await sentBody(capabilities: everything) { conversation in
            conversation.services.composer.pro = store
            conversation.services.onSandboxResponseFinished = { _ in finished += 1 }
        }
        #expect(body[path: "terminal_id"]?.stringValue == "demo-sandbox")
        #expect(finished == 1)
        // The app counts only Responses that ran in the sandbox; this one didn't.
        #expect(store.allowance.remaining == 2)
    }

    @Test func usedUpFreeRunsSendNoTerminal() async throws {
        let allowance = SandboxAllowance(limit: 1)
        allowance.recordUse()
        let store = ProStore.free(allowance: allowance)
        var finished = 0
        let body = try await sentBody(capabilities: everything) { conversation in
            conversation.services.composer.pro = store
            conversation.services.onSandboxResponseFinished = { _ in finished += 1 }
            #expect(conversation.composer.isOn(.codeInterpreter))
            #expect(conversation.composer.sandboxAllowanceExhausted)
            #expect(conversation.composer.terminalID == nil)
        }
        #expect(body[path: "terminal_id"] == nil)
        #expect(body[path: "features.code_interpreter"] == .bool(false))
        #expect(finished == 0)
    }

    // MARK: The Jupyter code interpreter shares the free runs (ADR 0173 addendum)

    private var jupyter: Set<Capability> { everything.subtracting([.sandbox]) }

    @Test func theFreeTierSendsTheCodeInterpreterWhileRunsRemainAndReportsTheResponse() async throws {
        let store = ProStore.free(allowance: SandboxAllowance(limit: 2))
        var finished: [ResponseState] = []
        let body = try await sentBody(capabilities: jupyter, model: haiku) { conversation in
            conversation.services.composer.pro = store
            conversation.services.onSandboxResponseFinished = { finished.append($0) }
            conversation.composer.set(.codeInterpreter, on: true)
        }
        #expect(body[path: "features.code_interpreter"] == .bool(true))
        #expect(finished.count == 1, "checked once, when it ends")
        // A plain answer with the switch on ran no code, so it isn't a run.
        #expect(finished.allSatisfy { !$0.ranCodeInterpreter })
        #expect(store.allowance.remaining == 2)
    }

    @Test func usedUpFreeRunsSendNoCodeInterpreter() async throws {
        let allowance = SandboxAllowance(limit: 1)
        allowance.recordUse()
        let store = ProStore.free(allowance: allowance)
        var finished = 0
        let body = try await sentBody(capabilities: jupyter, model: haiku) { conversation in
            conversation.services.composer.pro = store
            conversation.services.onSandboxResponseFinished = { _ in finished += 1 }
            conversation.composer.set(.codeInterpreter, on: true)
            #expect(conversation.composer.sandboxAllowanceExhausted)
            #expect(conversation.composer.sandboxAllowanceSummary == "No free runs left today")
        }
        #expect(body[path: "terminal_id"] == nil)
        #expect(body[path: "features.code_interpreter"] == .bool(false))
        #expect(finished == 0)
    }

    @Test func retriesAndEditsLeaveTheCodeInterpreterOutOnceUsedUp() async throws {
        let allowance = SandboxAllowance(limit: 1)
        let store = ProStore.free(allowance: allowance)
        var options: [String: Bool] = [:]
        var exhausted: [String: Bool] = [:]
        _ = try await sentBody(capabilities: jupyter, model: haiku) { conversation in
            conversation.services.composer.pro = store
            conversation.composer.set(.codeInterpreter, on: true)
            options = conversation.options(for: haiku.id).features
            allowance.recordUse()
            exhausted = conversation.options(for: haiku.id).features
        }
        #expect(options["code_interpreter"] == true)
        #expect(exhausted["code_interpreter"] == false)
    }

    @Test func proKeepsTheCodeInterpreterOnceTheFreeRunsAreGone() async throws {
        let allowance = SandboxAllowance(limit: 1)
        allowance.recordUse()
        let backend = InMemoryProBackend(entitled: true)
        let store = ProStore(backend: backend, allowance: allowance)
        await store.refreshEntitlement()
        let body = try await sentBody(capabilities: jupyter, model: haiku) { conversation in
            conversation.services.composer.pro = store
            conversation.composer.set(.codeInterpreter, on: true)
        }
        #expect(body[path: "features.code_interpreter"] == .bool(true))
    }

    @Test func freeTierSkillsOpenThePaywallInsteadOfGoingOut() async throws {
        let body = try await sentBody(capabilities: everything) { conversation in
            conversation.services.composer.pro = .free()
            conversation.composer.setSkill("deep-research", selected: true)
            #expect(conversation.composer.paywallRequest == PaywallRequest(.skills))
            #expect(conversation.composer.selectedSkillIDs.isEmpty)
        }
        #expect(body[path: "skill_ids"] == nil || body[path: "skill_ids"] == .array([]))
    }
}
