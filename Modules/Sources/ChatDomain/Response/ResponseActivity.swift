import Foundation

/// What a live Response is doing at its tail, for the working mouse (#173, #185, brand.md §3):
/// a scene and a plaque stay at the Response's tail whenever it isn't finished and isn't
/// streaming visible text right now (tool calls, Open Terminal runs, code execution, web search,
/// reasoning, between parts, the model going quiet mid-answer), and while it's paused on the user.
/// It's the Response's **only** mouse (#190): streamed Thinking shows here too, not in its block.
///
/// ```swift
/// let activity = ResponseActivity(state)
/// if let work = activity.indicator(stalled: quietFor >= ResponseActivity.stallDelay) { … }
/// ```
public enum ResponseActivity: Sendable, Hashable {
    /// Finished (completed, stopped or failed): no indicator.
    case idle
    /// Visible text streams at the tail: the indicator stays hidden unless the stream stalls
    /// for `stallDelay`.
    case streamingText
    /// Working without a visible stream (or reasoning at the tail, `.thinking`): the indicator
    /// shows at once with `work`'s plaque.
    case working(Work)
    /// Paused on the user, a clarifying question (`ask_user`) or a tool to allow (OT-06): the
    /// mouse peeks with a blinking `?` above the card (#185). It goes as soon as the user answers,
    /// allows or denies.
    case waitingOnYou

    /// The kind of work the plaque and the scene name (#185's table; the plaque shows uppercase
    /// in Departure Mono).
    public enum Work: Sendable, Hashable {
        /// Nothing visible yet, between parts, the stream went quiet, or reasoning.
        case thinking
        /// The stream resumed after a reconnect and nothing arrived yet (CHAT-12).
        case stillWriting
        /// `search_web`, `web_search`.
        case webSearch
        /// `fetch_url`, with the page's host when the call names one.
        case readingPage(host: String?)
        /// The Knowledge tools (`query_knowledge_files`, `view_knowledge_file`, …).
        case knowledge
        /// The Memory tools (`search_memories`, `add_memory`, …).
        case memory
        /// `search_chats`, `view_chat`.
        case pastChats
        /// `get_current_timestamp`, `calculate_timestamp`.
        case time
        /// `generate_image`, `edit_image`.
        case image
        /// Server-side code execution (CONN-08): `execute_code`, `run_code`, `code_interpreter`.
        case runningCode
        /// An Open Terminal command (OT-02) runs, or the model polls, lists or types into it.
        case runningCommand
        /// `read_file`, `list_files`, `display_file` in the Sandbox.
        case readingFiles
        /// `write_file`, `replace_file_content` in the Sandbox.
        case writingFiles
        /// `grep_search`, `glob_search`, `match_files`, `search_files` in the Sandbox.
        case searchingFiles
        /// `view_skill`, `read_skill_file` (#140).
        case skill
        /// `delegate_task`.
        case subAgent
        /// Any other tool (Connectors, tool servers, Functions), by its name when known.
        case tool(name: String?)
        /// Paused on the user: a clarifying question or a tool to allow.
        case waitingOnYou

        /// One of each kind, in #185's order (the associated values empty).
        public static let kinds: [Work] = [
            .thinking, .stillWriting, .webSearch, .readingPage(host: nil), .knowledge, .memory, .pastChats, .time,
            .image, .runningCode, .runningCommand, .readingFiles, .writingFiles, .searchingFiles, .skill, .subAgent,
            .tool(name: nil), .waitingOnYou,
        ]

        /// The plaque's text, e.g. "Searching the web…", "Reading example.com…", "Your turn".
        public var plaque: String {
            switch self {
            case .thinking: "Thinking…"
            case .stillWriting: "Still writing…"
            case .webSearch: "Searching the web…"
            case .readingPage(let host): host.map { "Reading \($0)…" } ?? "Reading a page…"
            case .knowledge: "Searching knowledge…"
            case .memory: "Checking memory…"
            case .pastChats: "Searching past chats…"
            case .time: "Checking the time…"
            case .image: "Creating an image…"
            case .runningCode: "Running code…"
            case .runningCommand: "Running command…"
            case .readingFiles: "Reading files…"
            case .writingFiles: "Writing files…"
            case .searchingFiles: "Searching files…"
            case .skill: "Reading a skill…"
            case .subAgent: "Asking a sub-agent…"
            case .tool(let name): name.flatMap(Self.readable).map { "Using \($0)…" } ?? "Working…"
            case .waitingOnYou: "Your turn"
            }
        }

        /// What VoiceOver reads: the plaque without its ellipsis.
        public var accessibilityLabel: String {
            plaque.hasSuffix("…") ? String(plaque.dropLast()) : plaque
        }

        /// Paused on the user, not working: the scene holds still but for its `?`.
        public var isPausedOnYou: Bool { self == .waitingOnYou }

        /// The longest tool name the plaque spells out, so a long one doesn't wrap the tail.
        static let longestToolName = 24

        /// A tool's name as the plaque shows it: words instead of `snake_case`, cut at `longestToolName`.
        private static func readable(_ name: String) -> String? {
            let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return nil }
            // The plaque's own ellipsis ends a shortened name too.
            return String(words.prefix(longestToolName)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// How long a streaming Response may stay quiet before the mouse comes back: long enough
    /// not to flicker between tokens (a chunk lands every ~40 ms), short enough to notice.
    public static let stallDelay: Duration = .milliseconds(600)

    public init(_ state: ResponseState) {
        if state.isFinished {
            self = .idle
            return
        }
        if state.phase == .awaitingAnswer {
            self = .waitingOnYou
            return
        }
        if state.phase == .waiting {
            self = .working(state.revision > 0 ? .stillWriting : .thinking)
            return
        }
        let parts = state.parts
        if let work = Self.runningWork(in: parts) {
            self = .working(work)
            return
        }
        switch parts.last {
        case .text(_, _, let isStreaming) where isStreaming:
            self = .streamingText
        default:
            // Reasoning at the tail (its block shows no mouse of its own, #190), or between
            // parts: a tool finished, the next item hasn't started.
            self = .working(.thinking)
        }
    }

    /// The plaque to show now, or `nil` for none; `stalled` is whether the stream has been quiet
    /// for `stallDelay`.
    public func indicator(stalled: Bool) -> Work? {
        switch self {
        case .idle: nil
        case .streamingText: stalled ? .thinking : nil
        case .working(let work): work
        case .waitingOnYou: .waitingOnYou
        }
    }

    /// Whether the Response is still live, so its tail keeps the indicator's room.
    public var isLive: Bool { self != .idle }

    /// The work behind the latest running step: a tool call, a code run or a server status line.
    private static func runningWork(in parts: [ResponsePart]) -> Work? {
        for part in parts.reversed() {
            switch part {
            case .tools(_, let tools):
                if let running = tools.last(where: \.isRunning) {
                    // An answered question or an allowed tool waits on the Server now, not on the user.
                    let work = work(forTool: running.name, arguments: running.arguments)
                    return work.isPausedOnYou ? .thinking : work
                }
            case .code(_, let execution):
                let hasOutput = [execution.stdout, execution.result, execution.stderr].contains { !($0 ?? "").isEmpty }
                if execution.status?.isActive ?? !hasOutput { return .runningCode }
            case .status(_, let update):
                if !update.isDone { return work(forStatus: update) }
            case .thinking, .text, .answers:
                continue
            }
        }
        return nil
    }

    /// The scene and plaque for a tool by its name (#185's table: the builtins and Open Terminal's
    /// 16 operations, ADR 0120); `arguments` (the call's JSON) names the page `fetch_url` reads.
    /// Anything unknown is `.tool(name:)`.
    public static func work(forTool name: String, arguments: String = "") -> Work {
        switch name {
        case "search_web", "web_search":
            return .webSearch
        case "fetch_url":
            return .readingPage(host: ToolActivity.host(inArguments: arguments))
        case "search_chats", "view_chat":
            return .pastChats
        case "generate_image", "edit_image":
            return .image
        case "execute_code", "run_code", "code_interpreter":
            return .runningCode
        // Open Terminal: processes and the user's terminal.
        case "run_command", "get_process_status", "send_process_input", "kill_process", "list_processes",
             "read_user_terminal", "send_user_terminal_input":
            return .runningCommand
        // Open Terminal: files.
        case "read_file", "list_files", "display_file":
            return .readingFiles
        case "write_file", "replace_file_content":
            return .writingFiles
        case "grep_search", "glob_search", "match_files", "search_files":
            return .searchingFiles
        case "view_skill", "read_skill_file":
            return .skill
        case "delegate_task":
            return .subAgent
        case ToolActivity.askUserName:
            return .waitingOnYou
        default:
            if name.hasSuffix("_timestamp") { return .time }
            if name.contains("knowledge") { return .knowledge }
            if name.contains("memories") || name.contains("memory") { return .memory }
            return .tool(name: name)
        }
    }

    private static func work(forStatus update: StatusUpdate) -> Work {
        let action = (update.action ?? "").lowercased()
        if action.contains("knowledge") { return .knowledge }
        if action.contains("memor") { return .memory }
        if action.contains("search") || action.contains("queries") { return .webSearch }
        if action.contains("code") { return .runningCode }
        if action.contains("image") { return .image }
        return .tool(name: nil)
    }
}
