import ChatDomain
import Entitlements
import Foundation
@testable import SandboxFeature
import Testing

/// ADR 0173 (addendum): the sandbox and the Jupyter code interpreter share one free daily count
/// of code execution runs. A Response that ran code counts once; one that only had the switch on
/// doesn't.
@MainActor
@Suite("Code execution runs")
struct CodeExecutionRunTests {
    private let answer = OutputItem.text(TextOutput(id: "msg_1", status: .completed, parts: ["4.0"]))

    private func executeCode(_ n: Int) -> [OutputItem] {
        [
            .toolCall(ToolCall(id: "fc_\(n)", callID: "call_\(n)", name: "execute_code", arguments: #"{"code":"print(4.0)"}"#, status: .completed)),
            .toolResult(ToolResult(id: "fco_\(n)", callID: "call_\(n)", output: ["4.0"], status: .completed)),
        ]
    }

    @Test func aJupyterRunCountsOnce() {
        let store = ProStore.free(allowance: SandboxAllowance(limit: 5))
        // Two interpreter calls in one Response are still one run.
        let response = ResponseState(output: executeCode(1) + executeCode(2) + [answer], content: "", isDone: true)
        #expect(Sandbox.ranCode(response))
        Sandbox.recordRun(of: response, in: store)
        #expect(store.allowance.remaining == 4)
    }

    @Test func aLegacyInterpreterItemCounts() {
        let store = ProStore.free(allowance: SandboxAllowance(limit: 5))
        let run = OutputItem.codeExecution(CodeExecutionOutput(id: "ci_1", status: .completed, code: "print(4.0)", stdout: "4.0"))
        Sandbox.recordRun(of: ResponseState(output: [run, answer], content: "", isDone: true), in: store)
        #expect(store.allowance.remaining == 4)
    }

    @Test func aPlainMessageDoesntCount() {
        let store = ProStore.free(allowance: SandboxAllowance(limit: 5))
        let response = ResponseState(output: [answer], content: "4.0", isDone: true)
        #expect(!Sandbox.ranCode(response))
        Sandbox.recordRun(of: response, in: store)
        #expect(store.allowance.remaining == 5)
    }

    @Test func proCountsNothing() async {
        let allowance = SandboxAllowance(limit: 5)
        let store = ProStore(backend: InMemoryProBackend(entitled: true), allowance: allowance)
        await store.refreshEntitlement()
        Sandbox.recordRun(of: ResponseState(output: executeCode(1), content: "", isDone: true), in: store)
        #expect(allowance.remaining == 5)
    }
}
