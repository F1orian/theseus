import ChatDomain
import Foundation
import Testing

private func text(_ id: String, _ parts: String..., status: ItemStatus = .inProgress) -> OutputItem {
    .text(TextOutput(id: id, status: status, parts: parts))
}

@Suite("ResponseState reducer")
struct ResponseStateTests {
    @Test func startsWaitingAndStreamsTextDeltas() {
        var state = ResponseState()
        #expect(state.phase == .waiting)

        state.apply(.delta(.text, itemID: "msg_1", outputIndex: 0, index: 0, text: "A maze "))
        #expect(state.phase == .streaming)
        state.apply(.delta(.text, itemID: "msg_1", outputIndex: 0, index: 0, text: "is a puzzle."))

        #expect(state.output == [.text(TextOutput(id: "msg_1", status: .inProgress, parts: ["A maze is a puzzle."]))])
        #expect(state.text == "A maze is a puzzle.")
    }

    @Test func deltaPastTheEndCreatesTypedPlaceholders() {
        var state = ResponseState()
        state.apply(.delta(.reasoning, itemID: "r_1", outputIndex: 0, index: 0, text: "17 × 23"))
        state.apply(.delta(.text, itemID: "msg_1", outputIndex: 1, index: 0, text: "391"))

        guard case .reasoning(let reasoning) = state.output.first, case .text(let answer) = state.output.last else {
            Issue.record("unexpected output \(state.output)")
            return
        }
        #expect(reasoning.id == "r_1")
        #expect(reasoning.text == "17 × 23")
        #expect(answer.text == "391")
    }

    @Test func textDeltasNeverLandOnReasoningItems() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .reasoning(ReasoningOutput(id: "r_1", status: .inProgress))))
        state.apply(.delta(.text, itemID: nil, outputIndex: 0, index: 0, text: "stray"))
        #expect(state.text.isEmpty)
        state.apply(.delta(.reasoning, itemID: nil, outputIndex: 0, index: 0, text: "thought"))
        #expect(state.parts.first == .thinking(id: "r_1", text: "thought", summary: "", isStreaming: true, duration: nil))
    }

    @Test func itemIDWinsOverOutputIndex() {
        var state = ResponseState()
        state.apply(.snapshot([text("a", "first", status: .completed), text("b", "second")]))
        state.apply(.delta(.text, itemID: "b", outputIndex: 0, index: 0, text: "!"))
        #expect(state.text == "first\n\nsecond!")
    }

    @Test func addedItemsMatchByIDOrCallIDAndInsertAtIndex() {
        var state = ResponseState()
        let search = ToolCall(id: "t1", callID: "t1", name: "search_web", status: .inProgress)
        state.apply(.itemAdded(outputIndex: 0, item: .toolCall(search)))
        state.apply(.itemAdded(outputIndex: 0, item: text("m", "intro")))
        #expect(state.output.map(\.type) == ["message", "function_call"])

        var updated = search
        updated.arguments = #"{"query":"maze"}"#
        state.apply(.itemAdded(outputIndex: 5, item: .toolCall(updated)))
        #expect(state.output.count == 2)
        #expect(state.output[1] == .toolCall(updated))
    }

    @Test func toolArgumentsStreamAndFinalize() {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .toolCall(ToolCall(id: "t1", callID: "t1", name: "search_web", status: .inProgress))))
        state.apply(.delta(.toolArguments, itemID: "t1", outputIndex: 0, index: 0, text: #"{"query": "#))
        state.apply(.delta(.toolArguments, itemID: "t1", outputIndex: 0, index: 0, text: #""maze"}"#))
        guard case .toolCall(let call) = state.output.first else { Issue.record("no call"); return }
        #expect(call.arguments == #"{"query": "maze"}"#)

        state.apply(.fieldDone(.toolArguments, itemID: "t1", outputIndex: 0, index: 0, text: #"{"query":"labyrinth"}"#))
        guard case .toolCall(let final) = state.output.first else { Issue.record("no call"); return }
        #expect(final.arguments == #"{"query":"labyrinth"}"#)
    }

    @Test func snapshotReplacesAccumulatedOutput() {
        var state = ResponseState()
        state.apply(.delta(.text, itemID: "x", outputIndex: 0, index: 0, text: "tail only"))
        state.apply(.snapshot([text("m", "The whole text so far")]))
        #expect(state.text == "The whole text so far")
    }

    @Test func completedTakesFinalOutputAndClosesActiveItems() {
        var state = ResponseState()
        state.apply(.delta(.text, itemID: "m", outputIndex: 0, index: 0, text: "partial"))
        state.apply(.completed(output: nil))
        #expect(state.phase == .completed)
        #expect(state.output.first?.status == .completed)
        #expect(state.isFinished)

        var other = ResponseState()
        other.apply(.completed(output: [text("m", "final", status: .completed)]))
        #expect(other.text == "final")
    }

    @Test func cancelKeepsPartialTextAndMarksItIncomplete() {
        var state = ResponseState()
        state.apply(.delta(.text, itemID: "m", outputIndex: 0, index: 0, text: "**The Long Way Round**"))
        state.apply(.cancelled(output: nil))
        #expect(state.phase == .stopped)
        #expect(state.text == "**The Long Way Round**")
        #expect(state.output.first?.status == .incomplete)
        // A second, empty cancel (the server sends two) changes nothing.
        state.apply(.cancelled(output: nil))
        #expect(state.text == "**The Long Way Round**")
    }

    @Test func failureRecordsTheErrorMessage() {
        var state = ResponseState()
        state.apply(.failed("max_tokens: must be greater than or equal to 0"))
        #expect(state.phase == .failed)
        #expect(state.error == "max_tokens: must be greater than or equal to 0")
        // A late `done` doesn't hide the error.
        state.apply(.completed(output: nil))
        #expect(state.phase == .failed)
    }

    @Test func silentReasoningShowsThinkingUntilTextArrives() {
        var state = ResponseState()
        state.apply(.legacyReasoningDelta(""))
        #expect(state.isThinkingSilently)
        #expect(state.phase == .waiting)
        state.apply(.delta(.text, itemID: "m", outputIndex: 0, index: 0, text: "Hi"))
        #expect(!state.isThinkingSilently)
    }

    @Test func legacyTextSplitsThinkingTags() {
        var state = ResponseState()
        state.apply(.legacyTextDelta("<think>6 × 7"))
        #expect(state.parts == [.thinking(id: "legacy-thinking", text: "6 × 7", summary: "", isStreaming: true, duration: nil)])
        state.apply(.legacyTextDelta(" = 42.</think>\n\n42"))
        state.apply(.completed(output: nil))
        #expect(state.parts == [
            .thinking(id: "legacy-thinking", text: "6 × 7 = 42.", summary: "", isStreaming: false, duration: nil),
            .text(id: "legacy-text", markdown: "42", isStreaming: false),
        ])
        #expect(state.text == "42")
    }

    @Test func statusUpdatesCollapseRepeatsAndSourcesAccumulate() {
        var state = ResponseState()
        state.apply(.status(StatusUpdate(action: "web_search", description: "Searching the web")))
        state.apply(.status(StatusUpdate(action: "web_search", description: "Searching the web", isDone: true)))
        #expect(state.statusHistory.count == 1)
        #expect(state.statusHistory.first?.isDone == true)

        state.apply(.source(Source(id: "https://a.example", name: "A")))
        state.apply(.source(Source(id: "https://b.example", name: "B")))
        #expect(state.sources.map(\.name) == ["A", "B"])
        state.apply(.sources([Source(id: "c", name: "C")]))
        #expect(state.sources.map(\.name) == ["C"])
    }

    @Test func storedMessagesRestoreTheirPhase() {
        let done = ResponseState(output: [text("m", "x", status: .completed)], content: "x", isDone: true)
        #expect(done.phase == .completed)
        let stopped = ResponseState(output: [text("m", "x", status: .incomplete)], content: "x", isDone: true)
        #expect(stopped.phase == .stopped)
        let failed = ResponseState(output: [], content: "", error: "boom", isDone: true)
        #expect(failed.phase == .failed)
        var overlay = ResponseState(output: [], content: "", isDone: false)
        #expect(overlay.phase == .waiting)
        overlay.resume()
        #expect(!overlay.isFinished)
        let legacy = ResponseState(output: [], content: "Plain stored text", isDone: true)
        #expect(legacy.text == "Plain stored text")
    }
}

@Suite("Response parts")
struct ResponsePartTests {
    @Test func toolCallsGroupIntoOneActivityLineWithResults() {
        var state = ResponseState()
        state.apply(.snapshot([
            .toolCall(ToolCall(id: "t1", callID: "t1", name: "search_web", arguments: #"{"query":"open webui"}"#, status: .completed)),
            .toolCall(ToolCall(id: "t2", callID: "t2", name: "fetch_url", arguments: #"{"url":"https://www.github.com/x"}"#, status: .completed)),
            .toolResult(ToolResult(id: "r1", callID: "t1", output: ["[results]"], status: .completed)),
            text("m", "Version 0.12.3."),
        ]))
        let parts = state.parts
        guard case .tools(_, let tools) = parts.first else { Issue.record("no tools in \(parts)"); return }
        #expect(tools.map(\.title) == ["Searched the web", "Reading github.com"])
        #expect(tools.first?.detail == "open webui")
        #expect(tools.first?.result == "[results]")
        #expect(parts.last == .text(id: "m", markdown: "Version 0.12.3.", isStreaming: true))

        state.apply(.completed(output: nil))
        guard case .tools(_, let finished) = state.parts.first else { Issue.record("no tools"); return }
        #expect(finished.map(\.title) == ["Searched the web", "Read github.com"])
    }

    @Test func toolTitlesCoverCommonBuiltins() {
        func title(_ name: String, running: Bool) -> String {
            ToolActivity(id: "x", name: name, arguments: "{}", isRunning: running).title
        }
        #expect(title("generate_image", running: true) == "Creating an image")
        #expect(title("execute_code", running: false) == "Ran code")
        #expect(title("search_memories", running: true) == "Checking memory")
        #expect(title("my_custom_tool", running: true) == "Using my custom tool")
    }

    @Test func pendingAskUserPausesAndAnsweredOneBecomesACard() throws {
        let arguments = #"{"questions":[{"id":"budget","header":"Budget","question":"What's your budget?","options":[{"label":"Low","description":"Cheap"},{"label":"High","description":"Fancy"}]}],"allow_other":true,"timeout_ms":120000}"#
        var state = ResponseState()
        state.apply(.snapshot([.toolCall(ToolCall(id: "c1", callID: "c1", name: "ask_user", arguments: arguments, status: .pending))]))
        #expect(state.phase == .awaitingAnswer)
        let questions = try #require(state.pendingQuestions)
        #expect(questions.callID == "c1")
        #expect(questions.questions.first?.options.map(\.label) == ["Low", "High"])
        #expect(questions.timeout == 120)
        #expect(state.parts.isEmpty)

        let result = #"{"status":"answered","answers":{"budget":{"type":"option","option_index":1,"label":"High","description":"Fancy"}}}"#
        state.apply(.snapshot([
            .toolCall(ToolCall(id: "c1", callID: "c1", name: "ask_user", arguments: arguments, status: .completed)),
            .toolResult(ToolResult(id: "fco_c1", callID: "c1", output: [result], status: .completed)),
            text("m", "Great, a fancy trip."),
        ]))
        #expect(state.pendingQuestions == nil)
        #expect(state.phase == .streaming)
        guard case .answers(_, let answers) = state.parts.first else { Issue.record("no answers in \(state.parts)"); return }
        #expect(answers.entries == [ClarifyingAnswers.Entry(question: "What's your budget?", answer: "High")])
    }
}

@Suite("Thinking tags")
struct ThinkingTagTests {
    @Test func splitsOnlyLeadingTags() {
        #expect(ThinkingTags.split("<thinking>a</thinking> b") == .init(reasoning: "a", reasoningIsOpen: false, text: "b"))
        #expect(ThinkingTags.split("Say <think> literally") == .init(reasoning: nil, reasoningIsOpen: false, text: "Say <think> literally"))
        #expect(ThinkingTags.split("<thi") == .init(reasoning: nil, reasoningIsOpen: false, text: ""))
        #expect(ThinkingTags.split("  <think>open") == .init(reasoning: "open", reasoningIsOpen: true, text: ""))
    }
}

@Suite("Clarifying questions")
struct ClarifyingQuestionTests {
    let questions = ClarifyingQuestions(callID: "c", questions: [
        .init(id: "a", header: "A", text: "Which?", options: [.init(label: "One", description: "1"), .init(label: "Two", description: "2")]),
        .init(id: "b", header: "B", text: "Why?", options: [.init(label: "X", description: "x"), .init(label: "Y", description: "y")]),
    ])

    @Test func completenessNeedsEveryQuestion() {
        #expect(!questions.isComplete(["a": .option(index: 0, .init(label: "One", description: "1"))]))
        #expect(!questions.isComplete(["a": .option(index: 0, .init(label: "One", description: "1")), "b": .other("  ")]))
        #expect(questions.isComplete(["a": .option(index: 0, .init(label: "One", description: "1")), "b": .other("because")]))
    }

    @Test func wireAnswersMatchTheServerShape() throws {
        let wire = questions.wireAnswers([
            "a": .option(index: 1, .init(label: "Two", description: "2")),
            "b": .other(" because "),
        ])
        let data = try JSONEncoder().encode(wire)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect(object["a"]?["type"] as? String == "option")
        #expect(object["a"]?["option_index"] as? Int == 1)
        #expect(object["a"]?["label"] as? String == "Two")
        #expect(object["b"]?["type"] as? String == "other")
        #expect(object["b"]?["text"] as? String == "because")
    }

    @Test func malformedArgumentsAreRejected() {
        #expect(ClarifyingQuestions(callID: "c", arguments: "{") == nil)
        #expect(ClarifyingQuestions(callID: "c", arguments: #"{"questions":[]}"#) == nil)
    }
}

@Suite("Output item coding")
struct OutputItemCodingTests {
    @Test func decodesEveryKnownItemTypeAndKeepsUnknownOnes() throws {
        let json = #"""
        [
          {"type":"message","id":"m","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi"}]},
          {"type":"reasoning","id":"r","status":"completed","content":[{"type":"output_text","text":"hmm"}],"summary":null,"started_at":10.5,"ended_at":12.0,"duration":1},
          {"type":"function_call","id":"t","call_id":"t","name":"search_web","arguments":"{}","status":"in_progress"},
          {"type":"function_call_output","id":"o","call_id":"t","output":[{"type":"input_text","text":"[]"}],"status":"completed"},
          {"type":"open_webui:code_interpreter","id":"c","code":"print(1)","output":{"stdout":"1"},"status":"completed"},
          {"type":"web_search_call","id":"w","status":"completed"}
        ]
        """#
        let items = try JSONDecoder().decode([OutputItem].self, from: Data(json.utf8))
        #expect(items.map(\.type) == ["message", "reasoning", "function_call", "function_call_output", "open_webui:code_interpreter", "web_search_call"])
        guard case .reasoning(let reasoning) = items[1], case .codeExecution(let code) = items[4] else {
            Issue.record("wrong cases"); return
        }
        #expect(reasoning.duration == 1)
        #expect(reasoning.startedAt == Date(timeIntervalSince1970: 10.5))
        #expect(code.stdout == "1")

        let roundTripped = try JSONDecoder().decode([OutputItem].self, from: JSONEncoder().encode(items))
        #expect(roundTripped == items)
    }
}

@Suite("Citations")
struct CitationTests {
    @Test func flattensAndDeduplicatesSources() throws {
        let json = #"""
        [
          {"source":{"id":"https://a.example/x","name":"https://a.example/x"},"document":["alpha  text\n\nmore"],"metadata":[{"source":"https://a.example/x","title":"Alpha"}]},
          {"source":{"id":"file-1","name":"report.pdf","type":"file"},"document":["p1","p2"],"metadata":[{"source":"file-1","name":"report.pdf","page":1},{"source":"file-1","name":"report.pdf","page":2}]},
          {"source":{"id":"https://a.example/x","name":"dup"},"document":["again"],"metadata":[{"source":"https://a.example/x"}]}
        ]
        """#
        let sources = try JSONDecoder().decode([Source].self, from: Data(json.utf8))
        let citations = Citation.list(from: sources)
        #expect(citations.map(\.number) == [1, 2])
        #expect(citations.map(\.title) == ["Alpha", "report.pdf"])
        #expect(citations.first?.host == "a.example")
        #expect(citations.first?.snippet == "alpha text more")
        #expect(citations.last?.link == nil)
    }
}
