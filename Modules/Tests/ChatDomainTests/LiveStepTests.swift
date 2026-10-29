import ChatDomain
import Foundation
import Testing

/// #195: a live status shows once. A live step row at the tail is drawn by the tail mouse (its
/// title is the plaque); a live card shows the status itself and the mouse goes without a plaque;
/// with no live step, the plaque names the work.
@Suite("One live status (#195)")
struct LiveStepTests {
    private func call(_ id: String, _ name: String, arguments: String = "{}") -> OutputItem {
        .toolCall(ToolCall(id: id, callID: id, name: name, arguments: arguments, status: .inProgress))
    }

    private func result(_ id: String) -> OutputItem {
        .toolResult(ToolResult(id: "fco-\(id)", callID: id, output: ["{}"], status: .completed))
    }

    private func live(_ state: ResponseState, cards: Set<String> = []) -> LiveStep {
        LiveStep(parts: state.parts, activity: ResponseActivity(state)) { cards.contains($0.id) }
    }

    @Test func waitingForTheFirstTokenHasNoLiveStep() {
        let state = ResponseState()
        #expect(live(state) == .none)
        #expect(live(state).plaque(for: .thinking) == "Thinking…")
    }

    @Test func streamingThinkingAtTheTailIsDrawnByTheTail() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .reasoning(ReasoningOutput(id: "r1", status: .inProgress))))
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Hmm"))
        let step = live(state)
        #expect(step == .row(partID: "r1", title: "Thinking"))
        #expect(step.absorbedPartID == "r1")
        #expect(step.plaque(for: .thinking) == "Thinking…")
    }

    @Test func aRunningSearchAtTheTailIsDrawnByTheTailWithItsTitle() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "search_web", arguments: #"{"query":"mice"}"#)))
        let step = live(state)
        #expect(step == .row(partID: "tools-c1", title: "Searching the web"))
        #expect(step.plaque(for: .webSearch) == "Searching the web…")
        #expect(!step.stepShowsStatus)
    }

    @Test func aRunningFetchNamesItsHost() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "fetch_url", arguments: #"{"url":"https://www.github.com/x"}"#)))
        #expect(live(state).plaque(for: .readingPage(host: "github.com")) == "Reading github.com…")
    }

    @Test func aLiveCardShowsTheStatusAndTheMouseGoesWithoutAPlaque() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "run_command", arguments: #"{"command":"ls"}"#)))
        let step = live(state, cards: ["tools-c1"])
        #expect(step == .card(partID: "tools-c1"))
        #expect(step.absorbedPartID == nil, "the card draws itself")
        #expect(step.plaque(for: .runningCommand) == nil)
        #expect(step.stepShowsStatus)
    }

    @Test func aRunningCodeExecutionIsACard() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .codeExecution(CodeExecutionOutput(id: "x1", status: .inProgress, code: "print(1)"))))
        #expect(live(state) == .card(partID: "x1"))
    }

    @Test func aFinishedStepGivesTheTailBackItsPlaque() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "search_web")))
        state.apply(.itemAdded(outputIndex: 1, item: result("c1")))
        // Between parts: the tail thinks, the row is the quiet "Searched the web".
        #expect(live(state) == .none)
        #expect(live(state).plaque(for: ResponseActivity(state).indicator(stalled: false)!) == "Thinking…")
    }

    @Test func streamingTextAndPausesHaveNoLiveStep() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .text(TextOutput(id: "t1", status: .inProgress, parts: [""]))))
        state.apply(.delta(.text, itemID: "t1", outputIndex: 0, index: 0, text: "Hello"))
        #expect(live(state) == .none)

        let finished = ResponseState(output: [.text(TextOutput(id: "t1", status: .completed, parts: ["Hi"]))], content: "", isDone: true)
        #expect(live(finished) == .none)
    }

    /// A status line that isn't the tail (the Server lists status first) shows the status itself.
    @Test func aLiveStepThatIsNotTheTailShowsItsOwnStatus() {
        var state = ResponseState()
        state.apply(.status(StatusUpdate(action: "web_search", description: "Searching the web", isDone: false)))
        state.apply(.itemAdded(outputIndex: 0, item: .reasoning(ReasoningOutput(id: "r1", status: .inProgress))))
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Hmm"))
        #expect(live(state) == .card(partID: "status"))

        var alone = ResponseState()
        alone.apply(.status(StatusUpdate(action: "web_search", description: "Searching the web", isDone: false)))
        #expect(live(alone) == .row(partID: "status", title: "Searching the web"))
    }
}
