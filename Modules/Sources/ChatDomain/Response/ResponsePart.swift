public import Foundation

/// One tool step of a Response, for the compact status line (CHAT-08).
public struct ToolActivity: Sendable, Hashable, Identifiable {
    /// The builtin tool behind clarifying questions; rendered as a card, not a status line.
    public static let askUserName = "ask_user"
    /// Claude's Artifact tool, in Chats imported from Claude (`<details type="tool_calls">`
    /// blocks, #180): rendered as Artifact cards, not a status line.
    public static let artifactsName = "artifacts"
    /// The Server's code interpreter as a tool (`execute_code` under native function calling, and
    /// older names).
    public static let codeInterpreterNames: Set<String> = ["execute_code", "run_code", "code_interpreter"]

    public let id: String
    public let name: String
    public let arguments: String
    public let isRunning: Bool
    public let failed: Bool
    public let result: String?

    public init(id: String, name: String, arguments: String, isRunning: Bool, failed: Bool = false, result: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.isRunning = isRunning
        self.failed = failed
        self.result = result
    }

    /// A short, user-facing description of the step, e.g. "Searching the web" while it runs and
    /// "Searched the web" once it's done.
    public var title: String {
        switch name {
        case "search_web", "web_search":
            return isRunning ? "Searching the web" : "Searched the web"
        case "fetch_url":
            if let host = ServerDisplay.linkHost(Self.host(inArguments: arguments)) { return isRunning ? "Reading \(host)" : "Read \(host)" }
            return isRunning ? "Reading a page" : "Read a page"
        case "query_knowledge_files", "query_knowledge_bases", "search_knowledge_files", "view_knowledge_file", "list_knowledge_bases":
            return isRunning ? "Searching knowledge" : "Searched knowledge"
        case "generate_image", "edit_image":
            return isRunning ? "Creating an image" : "Created an image"
        case "execute_code", "run_code", "code_interpreter":
            return isRunning ? "Running code" : "Ran code"
        case "search_memories", "query_memory", "add_memory", "replace_memory_content", "delete_memory", "list_memories":
            return isRunning ? "Checking memory" : "Checked memory"
        case "search_chats", "view_chat":
            return isRunning ? "Searching past chats" : "Searched past chats"
        case "get_current_timestamp", "calculate_timestamp":
            return isRunning ? "Checking the time" : "Checked the time"
        // Skills and sub-agents (#140).
        case "view_skill", "read_skill_file":
            let skill = Self.stringArgument("id", in: arguments).map { "the \($0) skill" } ?? "a skill"
            return isRunning ? "Reading \(skill)" : "Read \(skill)"
        case "delegate_task":
            let task = Self.stringArgument("task", in: arguments)?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            return task.map { "Sub-agent: \($0)" } ?? (isRunning ? "Starting a sub-agent" : "Asked a sub-agent")
        default:
            let readable = Self.humanize(name)
            return isRunning ? "Using \(readable)" : "Used \(readable)"
        }
    }

    /// The host of the page a `fetch_url` call reads (`"url"` in its arguments), without `www.`.
    public static func host(inArguments arguments: String) -> String? {
        guard let url = primaryArgument(arguments).flatMap({ URL(string: $0) }), let host = url.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The query or URL the step worked on, shown under the title when expanded.
    public var detail: String? {
        Self.primaryArgument(arguments)
    }

    private static func stringArgument(_ key: String, in arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String, !value.isEmpty
        else { return nil }
        return value
    }

    private static func primaryArgument(_ arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["query", "url", "prompt", "queries", "code", "task", "command", "path"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let values = object[key] as? [String], !values.isEmpty { return values.joined(separator: " · ") }
        }
        return nil
    }

    private static func humanize(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.isEmpty ? "a tool" : words
    }
}

/// A renderable piece of a Response, in display order.
public enum ResponsePart: Sendable, Hashable, Identifiable {
    /// The model's Thinking, collapsed above the text (CHAT-06).
    case thinking(id: String, text: String, summary: String, isStreaming: Bool, duration: TimeInterval?)
    /// Markdown text (CHAT-03).
    case text(id: String, markdown: String, isStreaming: Bool)
    /// Consecutive tool steps, shown as one status line (CHAT-08).
    case tools(id: String, [ToolActivity])
    /// `status` progress lines from the server (CHAT-08).
    case status(id: String, StatusUpdate)
    /// Server-side code execution.
    case code(id: String, CodeExecutionOutput)
    /// A resolved clarifying question, shown as a Q/A card (CHAT-09).
    case answers(id: String, ClarifyingAnswers)

    public var id: String {
        switch self {
        case .thinking(let id, _, _, _, _), .text(let id, _, _), .tools(let id, _), .status(let id, _),
             .code(let id, _), .answers(let id, _):
            id
        }
    }

    /// The Response's parts in display order. Only the live tail can still be thinking (#190): a
    /// Thinking part with anything after it is finished, whatever the Server says. (It leaves a
    /// reasoning item `in_progress` until the Response ends when a tool call follows it directly.)
    static func build(from state: ResponseState) -> [ResponsePart] {
        var parts = buildParts(from: state)
        for index in parts.indices.dropLast() {
            if case .thinking(let id, let text, let summary, true, let duration) = parts[index] {
                parts[index] = .thinking(id: id, text: text, summary: summary, isStreaming: false, duration: duration)
            }
        }
        return parts
    }

    private static func buildParts(from state: ResponseState) -> [ResponsePart] {
        var parts: [ResponsePart] = []
        let live = !state.isFinished

        // Status lines come first: they describe retrieval that happens before the answer.
        let statuses = state.statusHistory.filter { !$0.isHidden && !$0.description.isEmpty }
        if let latest = statuses.last {
            parts.append(.status(id: "status", latest))
        }

        if state.output.isEmpty {
            let split = ThinkingTags.split(state.legacyText)
            let reasoning = [state.legacyReasoning, split.reasoning ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !reasoning.isEmpty {
                let thinking = live && (split.reasoningIsOpen || split.text.isEmpty)
                parts.append(.thinking(id: "legacy-thinking", text: reasoning, summary: "", isStreaming: thinking, duration: nil))
            }
            guard SerializedContent.mayContainBlocks(split.text) else {
                if !split.text.isEmpty {
                    parts.append(.text(id: "legacy-text", markdown: split.text, isStreaming: live))
                }
                return parts
            }
            // The web client's `<details>` serialization (imported Chats, #180): Thinking and
            // tool steps in place, never their raw markup.
            var pendingTools: [ToolActivity] = []
            func flushTools() {
                guard let first = pendingTools.first else { return }
                parts.append(.tools(id: "tools-\(first.id)", pendingTools))
                pendingTools = []
            }
            let segments = SerializedContent.segments(split.text)
            var counts = (text: 0, thinking: 0)
            for (index, segment) in segments.enumerated() {
                let isLast = index == segments.count - 1
                switch segment {
                case .text(let markdown):
                    flushTools()
                    parts.append(.text(id: counts.text == 0 ? "legacy-text" : "legacy-text-\(counts.text)", markdown: markdown, isStreaming: live && isLast))
                    counts.text += 1
                case .reasoning(let text, let duration, let isOpen):
                    flushTools()
                    parts.append(.thinking(id: "legacy-thinking-\(counts.thinking)", text: text, summary: "", isStreaming: live && isOpen, duration: duration))
                    counts.thinking += 1
                case .toolCall(let call):
                    pendingTools.append(live ? call : ToolActivity(id: call.id, name: call.name, arguments: call.arguments, isRunning: false, result: call.result))
                }
            }
            flushTools()
            return parts
        }

        let results = Dictionary(
            state.output.compactMap { item -> (String, ToolResult)? in
                if case .toolResult(let result) = item, let callID = result.callID { return (callID, result) }
                return nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        let lastIndex = state.output.indices.last
        // The last item that can show: a reasoning item before it is superseded (#190), even one
        // that renders nothing yet (a pending question's call).
        let lastShownIndex = state.output.indices.last { index in
            if case .other = state.output[index] { return false }
            return true
        }
        var pendingTools: [ToolActivity] = []
        func flushTools() {
            guard let first = pendingTools.first else { return }
            parts.append(.tools(id: "tools-\(first.id)", pendingTools))
            pendingTools = []
        }

        for (index, item) in state.output.enumerated() {
            let fallbackID = "item-\(index)"
            switch item {
            case .reasoning(let reasoning):
                flushTools()
                let text = reasoning.text
                guard !text.isEmpty || !reasoning.summaryText.isEmpty || (reasoning.status?.isActive ?? false) else { continue }
                parts.append(.thinking(
                    id: reasoning.id ?? fallbackID,
                    text: text,
                    summary: reasoning.summaryText,
                    isStreaming: live && index == lastShownIndex && (reasoning.status?.isActive ?? true),
                    duration: reasoning.duration ?? reasoning.endedAt.flatMap { end in
                        reasoning.startedAt.map { end.timeIntervalSince($0) }
                    }
                ))
            case .text(let text):
                flushTools()
                guard !text.text.isEmpty else { continue }
                parts.append(.text(id: text.id ?? fallbackID, markdown: text.text, isStreaming: live && index == lastIndex))
            case .toolCall(let call):
                let callID = call.resolvedCallID ?? fallbackID
                let result = results[callID]
                if call.name == ToolActivity.askUserName {
                    flushTools()
                    if let result, let questions = ClarifyingQuestions(callID: callID, arguments: call.arguments),
                       let answers = ClarifyingAnswers(questions: questions, resultText: result.text) {
                        parts.append(.answers(id: "answers-\(callID)", answers))
                    }
                    continue
                }
                // A call's own status only covers its arguments; the step runs until its result arrives.
                let stopped = call.status == .failed || call.status == .rejected || call.status == .incomplete
                let running = result == nil && live && !stopped
                pendingTools.append(ToolActivity(
                    id: callID,
                    name: call.name,
                    arguments: call.arguments,
                    isRunning: running,
                    failed: result?.status == .failed || call.status == .failed || call.status == .rejected,
                    result: result?.text
                ))
            case .toolResult:
                continue
            case .codeExecution(let execution):
                flushTools()
                parts.append(.code(id: execution.id ?? fallbackID, execution))
            case .other:
                continue
            }
        }
        flushTools()
        return parts
    }
}

/// Splits `<think>…</think>`-style Thinking out of plain text. The server does this for socket
/// streams; plain SSE responses still carry the raw tags (docs/research/open-webui-api.md §5.6).
public enum ThinkingTags {
    /// The tag pairs the server recognises by default.
    public static let pairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reason>", "</reason>"),
        ("<reasoning>", "</reasoning>"),
        ("<thought>", "</thought>"),
        ("<Thought>", "</Thought>"),
        ("<|begin_of_thought|>", "<|end_of_thought|>"),
        ("◁think▷", "◁/think▷"),
    ]

    public struct Split: Sendable, Hashable {
        public var reasoning: String?
        /// The closing tag hasn't arrived yet (still thinking).
        public var reasoningIsOpen: Bool
        public var text: String

        public init(reasoning: String?, reasoningIsOpen: Bool, text: String) {
            self.reasoning = reasoning
            self.reasoningIsOpen = reasoningIsOpen
            self.text = text
        }
    }

    /// Only a tag at the start of the text counts (after leading whitespace), like the server.
    public static func split(_ text: String) -> Split {
        let trimmed = text.drop(while: \.isWhitespace)
        for pair in pairs where trimmed.hasPrefix(pair.open) {
            let body = trimmed.dropFirst(pair.open.count)
            if let close = body.range(of: pair.close) {
                let reasoning = String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = String(body[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return Split(reasoning: reasoning, reasoningIsOpen: false, text: rest)
            }
            return Split(reasoning: String(body).trimmingCharacters(in: .whitespacesAndNewlines), reasoningIsOpen: true, text: "")
        }
        // A partially received opening tag shouldn't flash on screen.
        if pairs.contains(where: { $0.open.hasPrefix(trimmed) && !trimmed.isEmpty }) {
            return Split(reasoning: nil, reasoningIsOpen: false, text: "")
        }
        return Split(reasoning: nil, reasoningIsOpen: false, text: text)
    }
}
