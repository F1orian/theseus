import ChatDomain
import Foundation
import Testing

/// #173, #185: whether a Response is working without a visible stream, and what the scene and
/// plaque name.
@Suite("Response activity (the working mouse)")
struct ResponseActivityTests {
    private func call(_ id: String, _ name: String, arguments: String = "{}") -> OutputItem {
        .toolCall(ToolCall(id: id, callID: id, name: name, arguments: arguments, status: .completed))
    }

    private func result(_ id: String, _ text: String = "{}") -> OutputItem {
        .toolResult(ToolResult(id: "r-\(id)", callID: id, output: [text], status: .completed))
    }

    private func text(_ id: String, _ text: String, status: ItemStatus = .inProgress) -> OutputItem {
        .text(TextOutput(id: id, status: status, parts: [text]))
    }

    @Test func nothingArrivedYetIsThinkingAndAResumeIsStillWriting() {
        var state = ResponseState()
        #expect(ResponseActivity(state) == .working(.thinking))
        state.resume()
        #expect(ResponseActivity(state) == .working(.stillWriting))
    }

    @Test func aRunningCommandShowsTheMouseWithItsPlaque() {
        var state = ResponseState()
        state.apply(.snapshot([text("m1", "Let me look.", status: .completed), call("c1", "run_command", arguments: #"{"command":"ls"}"#)]))
        let activity = ResponseActivity(state)
        #expect(activity == .working(.runningCommand))
        #expect(activity.indicator(stalled: false) == .runningCommand)
        #expect(activity.indicator(stalled: false)?.plaque == "Running command…")
        #expect(activity.indicator(stalled: false)?.accessibilityLabel == "Running command")
    }

    /// #185's table, tool by tool: every builtin and all 16 Open Terminal operations.
    @Test(arguments: [
        ("search_web", ResponseActivity.Work.webSearch), ("web_search", .webSearch),
        ("fetch_url", .readingPage(host: nil)),
        ("query_knowledge_files", .knowledge), ("query_knowledge_bases", .knowledge), ("search_knowledge_files", .knowledge),
        ("view_knowledge_file", .knowledge), ("list_knowledge_bases", .knowledge),
        ("search_memories", .memory), ("query_memory", .memory), ("add_memory", .memory),
        ("replace_memory_content", .memory), ("delete_memory", .memory), ("list_memories", .memory),
        ("search_chats", .pastChats), ("view_chat", .pastChats),
        ("get_current_timestamp", .time), ("calculate_timestamp", .time),
        ("generate_image", .image), ("edit_image", .image),
        ("execute_code", .runningCode), ("run_code", .runningCode), ("code_interpreter", .runningCode),
        // Open Terminal (docs/research/open-terminal.md §2.1): processes and the user's terminal…
        ("run_command", .runningCommand), ("get_process_status", .runningCommand), ("send_process_input", .runningCommand),
        ("kill_process", .runningCommand), ("list_processes", .runningCommand),
        ("read_user_terminal", .runningCommand), ("send_user_terminal_input", .runningCommand),
        // … and files.
        ("read_file", .readingFiles), ("list_files", .readingFiles), ("display_file", .readingFiles),
        ("write_file", .writingFiles), ("replace_file_content", .writingFiles),
        ("grep_search", .searchingFiles), ("glob_search", .searchingFiles), ("match_files", .searchingFiles), ("search_files", .searchingFiles),
        ("view_skill", .skill), ("read_skill_file", .skill),
        ("delegate_task", .subAgent),
        ("ask_user", .waitingOnYou),
    ] as [(String, ResponseActivity.Work)])
    func everyToolMapsToItsRow(tool: String, work: ResponseActivity.Work) {
        #expect(ResponseActivity.work(forTool: tool) == work)
    }

    @Test func allSixteenOpenTerminalOperationsHaveAScene() {
        let operations = [
            "list_files", "read_file", "display_file", "write_file", "replace_file_content", "grep_search", "match_files",
            "search_files", "glob_search", "list_processes", "run_command", "get_process_status", "send_process_input",
            "kill_process", "read_user_terminal", "send_user_terminal_input",
        ]
        #expect(Set(operations).count == 16)
        let sandbox: Set<ResponseActivity.Work> = [.runningCommand, .readingFiles, .writingFiles, .searchingFiles]
        for operation in operations {
            #expect(sandbox.contains(ResponseActivity.work(forTool: operation)), "\(operation)")
        }
    }

    @Test func unknownToolsAreOtherByName() {
        #expect(ResponseActivity.work(forTool: "get_weather") == .tool(name: "get_weather"))
        #expect(ResponseActivity.work(forTool: "get_weather").plaque == "Using get weather…")
        #expect(ResponseActivity.work(forTool: "mcp-linear-create_issue").plaque == "Using mcp linear create issue…")
        #expect(ResponseActivity.work(forTool: "").plaque == "Working…")
        #expect(ResponseActivity.Work.tool(name: nil).plaque == "Working…")
        let long = ResponseActivity.work(forTool: "a_tool_server_operation_with_a_very_long_name").plaque
        #expect(long == "Using a tool server operation…")
        #expect(long.count <= "Using …".count + 24)
    }

    @Test func readingAPageNamesItsHost() {
        #expect(ResponseActivity.work(forTool: "fetch_url", arguments: #"{"url":"https://www.example.com/a?b=1"}"#) == .readingPage(host: "example.com"))
        #expect(ResponseActivity.Work.readingPage(host: "example.com").plaque == "Reading example.com…")
        #expect(ResponseActivity.work(forTool: "fetch_url", arguments: #"{"url":"not a url"}"#) == .readingPage(host: nil))
        #expect(ResponseActivity.work(forTool: "fetch_url", arguments: "{}").plaque == "Reading a page…")
    }

    @Test func plaquesFollowTheTable() {
        let plaques = ResponseActivity.Work.kinds.map(\.plaque)
        #expect(plaques == [
            "Thinking…", "Still writing…", "Searching the web…", "Reading a page…", "Searching knowledge…", "Checking memory…",
            "Searching past chats…", "Checking the time…", "Creating an image…", "Running code…", "Running command…",
            "Reading files…", "Writing files…", "Searching files…", "Reading a skill…", "Asking a sub-agent…", "Working…", "Your turn",
        ])
        #expect(ResponseActivity.Work.kinds.allSatisfy { !$0.accessibilityLabel.hasSuffix("…") && !$0.accessibilityLabel.isEmpty })
        #expect(ResponseActivity.Work.waitingOnYou.accessibilityLabel == "Your turn")
        #expect(ResponseActivity.Work.kinds.filter(\.isPausedOnYou) == [.waitingOnYou])
    }

    @Test func betweenPartsTheMouseThinks() {
        var state = ResponseState()
        state.apply(.snapshot([call("c1", "search_web"), result("c1")]))
        #expect(ResponseActivity(state) == .working(.thinking))
    }

    @Test func streamingTextHidesTheMouseUntilTheStreamStalls() {
        var state = ResponseState()
        state.apply(.delta(.text, itemID: "m1", outputIndex: 0, index: 0, text: "A maze"))
        let activity = ResponseActivity(state)
        #expect(activity == .streamingText)
        #expect(activity.indicator(stalled: false) == nil)
        #expect(activity.indicator(stalled: true) == .thinking)
        #expect(activity.isLive)
    }

    /// #190: streamed Thinking at the tail ponders in the tail indicator, the Response's one mouse.
    @Test func streamingThinkingPondersAtTheTail() {
        var state = ResponseState()
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Hmm"))
        let activity = ResponseActivity(state)
        #expect(activity == .working(.thinking))
        #expect(activity.indicator(stalled: false) == .thinking)
        #expect(activity.indicator(stalled: false)?.plaque == "Thinking…")
    }

    @Test func liveCodeAndStatusLinesNameTheirWork() {
        var state = ResponseState()
        state.apply(.snapshot([.codeExecution(CodeExecutionOutput(id: "x", status: .inProgress, code: "1+1"))]))
        #expect(ResponseActivity(state) == .working(.runningCode))

        var searching = ResponseState()
        searching.apply(.status(StatusUpdate(action: "web_search", description: "Searching the web")))
        searching.apply(.delta(.text, itemID: "m1", outputIndex: 0, index: 0, text: ""))
        #expect(ResponseActivity(searching) == .working(.webSearch))

        var retrieving = ResponseState()
        retrieving.apply(.status(StatusUpdate(action: "knowledge_search", description: "Searching knowledge")))
        retrieving.apply(.delta(.text, itemID: "m1", outputIndex: 0, index: 0, text: ""))
        #expect(ResponseActivity(retrieving) == .working(.knowledge))

        var other = ResponseState()
        other.apply(.status(StatusUpdate(action: "my_filter", description: "Polishing")))
        other.apply(.delta(.text, itemID: "m1", outputIndex: 0, index: 0, text: ""))
        #expect(ResponseActivity(other) == .working(.tool(name: nil)))
    }

    @Test func finishedResponsesShowNothing() {
        var done = ResponseState()
        done.apply(.delta(.text, itemID: "m1", outputIndex: 0, index: 0, text: "Done."))
        done.apply(.completed(output: nil))
        #expect(ResponseActivity(done) == .idle)
        #expect(ResponseActivity(done).indicator(stalled: true) == nil)
        #expect(!ResponseActivity(done).isLive)

        var stopped = ResponseState()
        stopped.apply(.snapshot([call("c1", "run_command")]))
        stopped.apply(.cancelled(output: nil))
        #expect(ResponseActivity(stopped) == .idle)

        var failed = ResponseState()
        failed.apply(.snapshot([call("c1", "run_command")]))
        failed.apply(.failed("Server error"))
        #expect(ResponseActivity(failed) == .idle)

        let stored = ResponseState(output: [text("m1", "Hi", status: .completed)], content: "", isDone: true)
        #expect(ResponseActivity(stored) == .idle)
    }

    private static let question = #"{"questions":[{"id":"q","header":"Q","question":"Which?","options":[{"label":"A","description":"a"}]}]}"#

    /// #185: paused on a clarifying question, the mouse peeks ("Your turn"); answering hands
    /// back to the working mouse; finishing, stopping or failing shows nothing.
    @Test func aClarifyingQuestionWaitsOnYouUntilItsAnswered() {
        var state = ResponseState()
        state.apply(.snapshot([.toolCall(ToolCall(id: "c1", callID: "c1", name: "ask_user", arguments: Self.question, status: .pending))]))
        #expect(state.phase == .awaitingAnswer)
        #expect(ResponseActivity(state) == .waitingOnYou)
        #expect(ResponseActivity(state).indicator(stalled: false) == .waitingOnYou)
        #expect(ResponseActivity(state).indicator(stalled: true) == .waitingOnYou)
        #expect(ResponseActivity(state).isLive)

        state.continueAfterAnswer(callID: "c1")
        #expect(ResponseActivity(state) != .waitingOnYou)
        #expect(ResponseActivity(state).indicator(stalled: false) == .thinking, "answered: the Server works again")

        var paused = ResponseState()
        paused.apply(.snapshot([.toolCall(ToolCall(id: "c1", callID: "c1", name: "ask_user", arguments: Self.question, status: .pending))]))
        paused.apply(.completed(output: nil))
        #expect(paused.phase == .awaitingAnswer, "a question can outlive the stream")
        #expect(ResponseActivity(paused) == .waitingOnYou)
        paused.apply(.cancelled(output: nil))
        #expect(ResponseActivity(paused) == .idle, "stopped: nothing")
    }

    /// A tool waiting to be allowed (OT-06) peeks too; allowing it runs the tool's own scene,
    /// denying it hands back to thinking.
    @Test func aToolToAllowWaitsOnYouUntilAllowedOrDenied() {
        let pending = OutputItem.toolCall(ToolCall(id: "c1", callID: "c1", name: "run_command", arguments: #"{"command":"ls"}"#, status: .pending))
        var allowed = ResponseState(output: [pending], content: "", isDone: false)
        #expect(allowed.phase == .awaitingAnswer)
        #expect(ResponseActivity(allowed) == .waitingOnYou)
        allowed.continueAfterAnswer(callID: "c1")
        allowed.apply(.snapshot([.toolCall(ToolCall(id: "c1", callID: "c1", name: "run_command", arguments: #"{"command":"ls"}"#, status: .inProgress))]))
        #expect(ResponseActivity(allowed) == .working(.runningCommand))

        var denied = ResponseState(output: [pending], content: "", isDone: false)
        denied.continueAfterAnswer(callID: "c1")
        denied.apply(.snapshot([pending, result("c1", "denied")]))
        #expect(ResponseActivity(denied) == .working(.thinking))

        var failed = ResponseState(output: [pending], content: "", isDone: false)
        failed.apply(.failed("Server error"))
        #expect(ResponseActivity(failed) == .idle)
    }
}
