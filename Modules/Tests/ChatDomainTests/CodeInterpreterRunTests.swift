import ChatDomain
import Foundation
import Testing

/// ADR 0173 (addendum): a Response counts against the free code execution runs when the Server's
/// code interpreter really ran code for it, not when it was merely allowed to.
@Suite("Code interpreter runs")
struct CodeInterpreterRunTests {
    private let answer = OutputItem.text(TextOutput(id: "msg_1", status: .completed, parts: ["The mean is 4."]))

    @Test func aPlainAnswerRanNothing() {
        let state = ResponseState(output: [answer], content: "The mean is 4.", isDone: true)
        #expect(!state.ranCodeInterpreter)
        #expect(!ResponseState().ranCodeInterpreter)
    }

    @Test func aLegacyCodeInterpreterItemCounts() {
        // Legacy function calling: the Server runs `<code_interpreter>` blocks and stores the item.
        let run = OutputItem.codeExecution(CodeExecutionOutput(id: "ci_1", status: .completed, code: "print(sum([3, 5]) / 2)", stdout: "4.0\n"))
        let state = ResponseState(output: [run, answer], content: "The mean is 4.", isDone: true)
        #expect(state.ranCodeInterpreter)
    }

    @Test func anEmptyCodeItemDoesNot() {
        let empty = OutputItem.codeExecution(CodeExecutionOutput(id: "ci_1", status: .completed, code: "  "))
        #expect(!ResponseState(output: [empty, answer], content: "", isDone: true).ranCodeInterpreter)
    }

    @Test func aNativeExecuteCodeCallWithAResultCounts() {
        // Native function calling: the builtin `execute_code` tool, answered by the Server.
        let call = OutputItem.toolCall(ToolCall(id: "fc_1", callID: "call_1", name: "execute_code", arguments: #"{"code":"print(4)"}"#, status: .completed))
        let result = OutputItem.toolResult(ToolResult(id: "fco_1", callID: "call_1", output: ["4"], status: .completed))
        #expect(ResponseState(output: [call, result, answer], content: "", isDone: true).ranCodeInterpreter)
        // Asked for but never run (denied, or the Response stopped first): nothing ran.
        #expect(!ResponseState(output: [call, answer], content: "", isDone: true).ranCodeInterpreter)
    }

    @Test func otherToolsDontCount() {
        let call = OutputItem.toolCall(ToolCall(id: "fc_1", callID: "call_1", name: "search_web", arguments: "{}", status: .completed))
        let result = OutputItem.toolResult(ToolResult(id: "fco_1", callID: "call_1", output: ["…"], status: .completed))
        #expect(!ResponseState(output: [call, result, answer], content: "", isDone: true).ranCodeInterpreter)
    }

    @Test func serializedContentCountsToo() {
        let content = """
        <details type="code_interpreter" done="true" output="4.0">
        <summary>Analyzed</summary>
        ```python
        print(4.0)
        ```
        </details>
        The mean is 4.
        """
        #expect(ResponseState(output: [], content: content, isDone: true).ranCodeInterpreter)
        #expect(!ResponseState(output: [], content: "The mean is 4.", isDone: true).ranCodeInterpreter)
    }
}
