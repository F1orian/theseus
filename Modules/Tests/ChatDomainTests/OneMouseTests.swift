import ChatDomain
import Foundation
import Testing

/// #190: one working mouse per Response, at its tail, with the latest Work. A Response that
/// interleaves reasoning and tool steps (reasoning → tools → reasoning → tools → reasoning) keeps
/// exactly one indicator; every Thinking part but the live tail is a finished step, even when the
/// Server never marks it done (it leaves a reasoning item `in_progress` when a tool call follows
/// it directly, until the Response ends).
@Suite("One mouse per Response (#190)")
struct OneMouseTests {
    /// One step of the walk: what the tail shows, and which Thinking part (if any) still thinks.
    private struct Step: CustomStringConvertible {
        let indicator: ResponseActivity.Work?
        let streamingThinking: [String]
        let finishedThinking: [String]
        let lastPartIsStreamingThinking: Bool

        var description: String {
            "indicator: \(indicator.map { "\($0)" } ?? "none"), thinking: \(streamingThinking), finished: \(finishedThinking)"
        }
    }

    private func step(_ state: ResponseState) -> Step {
        let parts = state.parts
        var streaming: [String] = []
        var finished: [String] = []
        for part in parts {
            if case .thinking(let id, _, _, let isStreaming, _) = part {
                if isStreaming { streaming.append(id) } else { finished.append(id) }
            }
        }
        var lastIsThinking = false
        if case .thinking(_, _, _, true, _)? = parts.last { lastIsThinking = true }
        return Step(
            indicator: ResponseActivity(state).indicator(stalled: false),
            streamingThinking: streaming,
            finishedThinking: finished,
            lastPartIsStreamingThinking: lastIsThinking
        )
    }

    /// Every Thinking part that still thinks is the last part, and there's at most one.
    private func expectOneLiveThinkingAtMost(_ state: ResponseState, _ comment: Comment) {
        let current = step(state)
        #expect(current.streamingThinking.count <= 1, comment)
        if !current.streamingThinking.isEmpty {
            #expect(current.lastPartIsStreamingThinking, "a Thinking part that isn't the tail is finished: \(comment)")
        }
    }

    private func reasoning(_ id: String) -> OutputItem {
        .reasoning(ReasoningOutput(id: id, status: .inProgress))
    }

    private func call(_ id: String, _ name: String, arguments: String = "{}") -> OutputItem {
        .toolCall(ToolCall(id: id, callID: id, name: name, arguments: arguments, status: .inProgress))
    }

    private func result(_ id: String) -> OutputItem {
        .toolResult(ToolResult(id: "fco-\(id)", callID: id, output: ["{}"], status: .completed))
    }

    /// reasoning → search → reasoning → fetch → reasoning → text, the way the Server streams it:
    /// `output_item.added` per item, deltas, and no `done` for a reasoning item a tool call follows.
    @Test func reasoningToolsReasoningToolsReasoningKeepsOneIndicatorWithTheLatestWork() {
        var state = ResponseState()
        #expect(step(state).indicator == .thinking, "sent: thinking")

        // 1. Reasoning streams at the tail: the tail mouse ponders (THINKING…), nothing else does.
        state.apply(.itemAdded(outputIndex: 0, item: reasoning("r1")))
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "I should search first."))
        #expect(step(state).indicator == .thinking)
        #expect(step(state).streamingThinking == ["r1"])
        expectOneLiveThinkingAtMost(state, "reasoning 1")

        // 2. A web search starts; the Server leaves r1 `in_progress`.
        state.apply(.itemAdded(outputIndex: 1, item: call("c1", "search_web", arguments: #"{"query":"open webui release"}"#)))
        #expect(step(state).indicator == .webSearch)
        #expect(step(state).streamingThinking.isEmpty, "superseded by the tool step: r1 is finished")
        #expect(step(state).finishedThinking == ["r1"])
        state.apply(.itemDone(outputIndex: 1, item: .toolCall(ToolCall(id: "c1", callID: "c1", name: "search_web", arguments: #"{"query":"open webui release"}"#, status: .completed))))
        #expect(step(state).indicator == .webSearch, "the call runs until its result arrives")

        // 3. The result lands: between parts, the mouse thinks.
        state.apply(.itemDone(outputIndex: 2, item: result("c1")))
        #expect(step(state).indicator == .thinking)
        #expect(step(state).streamingThinking.isEmpty)

        // 4. Reasoning again.
        state.apply(.itemAdded(outputIndex: 3, item: reasoning("r2")))
        state.apply(.delta(.reasoning, itemID: "r2", outputIndex: 3, index: 0, text: "Now the release notes."))
        #expect(step(state).indicator == .thinking)
        #expect(step(state).streamingThinking == ["r2"])
        #expect(step(state).finishedThinking == ["r1"])
        expectOneLiveThinkingAtMost(state, "reasoning 2")

        // 5. Reading a page.
        state.apply(.itemAdded(outputIndex: 4, item: call("c2", "fetch_url", arguments: #"{"url":"https://www.example.com/notes"}"#)))
        #expect(step(state).indicator == .readingPage(host: "example.com"))
        #expect(step(state).streamingThinking.isEmpty)
        #expect(step(state).finishedThinking == ["r1", "r2"])
        state.apply(.itemDone(outputIndex: 5, item: result("c2")))
        #expect(step(state).indicator == .thinking)

        // 6. Reasoning a third time, then the answer.
        state.apply(.itemAdded(outputIndex: 6, item: reasoning("r3")))
        state.apply(.delta(.reasoning, itemID: "r3", outputIndex: 6, index: 0, text: "Compare."))
        #expect(step(state).indicator == .thinking)
        #expect(step(state).streamingThinking == ["r3"])
        expectOneLiveThinkingAtMost(state, "reasoning 3")
        state.apply(.delta(.text, itemID: "m1", outputIndex: 7, index: 0, text: "Open WebUI"))
        #expect(step(state).streamingThinking.isEmpty, "the text supersedes r3")
        #expect(ResponseActivity(state) == .streamingText)
        #expect(ResponseActivity(state).indicator(stalled: true) == .thinking, "a stalled stream brings the one mouse back")

        // 7. Done: no mouse, every Thinking part finished.
        state.apply(.completed(output: nil))
        #expect(step(state).indicator == nil)
        #expect(step(state).streamingThinking.isEmpty)
        #expect(step(state).finishedThinking == ["r1", "r2", "r3"])
    }

    /// A reasoning item a clarifying question follows: paused on the user, the tail peeks and the
    /// Thinking part above the card is finished.
    @Test func aQuestionSupersedesTheThinkingBeforeIt() {
        let question = #"{"questions":[{"id":"q","header":"Q","question":"Which?","options":[{"label":"A","description":"a"}]}]}"#
        let state = ResponseState(
            output: [
                .reasoning(ReasoningOutput(id: "r1", status: .inProgress, content: ["Ask first."])),
                .toolCall(ToolCall(id: "c1", callID: "c1", name: "ask_user", arguments: question, status: .pending)),
            ],
            content: "",
            isDone: false
        )
        #expect(step(state).indicator == .waitingOnYou)
        #expect(step(state).streamingThinking.isEmpty)
    }

    /// Legacy `<details type="reasoning">` serialization: only an open block at the end thinks.
    @Test func serializedThinkingBeforeAToolStepIsFinished() {
        let content = """
        <details type="reasoning" done="false">
        <summary>Thinking…</summary>
        > First thought
        </details>
        <details type="tool_calls" done="false" id="c1" name="search_web" arguments="{}">
        <summary>Tool Executing...</summary>
        </details>
        """
        var state = ResponseState()
        state.apply(.legacyText(content))
        let current = step(state)
        #expect(current.streamingThinking.isEmpty, "\(current)")
    }
}
