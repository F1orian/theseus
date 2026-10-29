public import Foundation

/// The lifecycle of one output item (server strings: `in_progress`, `completed`, `incomplete`,
/// `pending`, `queued`, `requires_approval`, `rejected`, `failed`). Unknown values are kept.
public struct ItemStatus: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inProgress = ItemStatus(rawValue: "in_progress")
    public static let completed = ItemStatus(rawValue: "completed")
    /// Cut short (e.g. the user stopped the Response).
    public static let incomplete = ItemStatus(rawValue: "incomplete")
    /// A tool call waiting for the user (approval or an answer).
    public static let pending = ItemStatus(rawValue: "pending")
    public static let queued = ItemStatus(rawValue: "queued")
    public static let requiresApproval = ItemStatus(rawValue: "requires_approval")
    public static let rejected = ItemStatus(rawValue: "rejected")
    public static let failed = ItemStatus(rawValue: "failed")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Still changing: deltas may follow.
    public var isActive: Bool { self == .inProgress || self == .queued }
}

/// Assistant text (`type: "message"`). `parts` are the `output_text` content parts, by content index.
public struct TextOutput: Sendable, Hashable {
    public var id: String?
    public var status: ItemStatus?
    public var parts: [String]

    public init(id: String?, status: ItemStatus? = nil, parts: [String] = []) {
        self.id = id
        self.status = status
        self.parts = parts
    }

    public var text: String { parts.joined() }
}

/// Visible model reasoning (`type: "reasoning"`), shown as Thinking.
public struct ReasoningOutput: Sendable, Hashable {
    public var id: String?
    public var status: ItemStatus?
    /// The reasoning body, by content index.
    public var content: [String]
    /// Provider-written summaries of the reasoning, by summary index.
    public var summary: [String]
    public var startedAt: Date?
    public var endedAt: Date?
    /// Seconds the model spent thinking, as reported by the server.
    public var duration: TimeInterval?

    public init(
        id: String?,
        status: ItemStatus? = nil,
        content: [String] = [],
        summary: [String] = [],
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.status = status
        self.content = content
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
    }

    public var text: String { content.joined() }
    public var summaryText: String { summary.filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

/// A tool (Connector, builtin or web search) the model called (`type: "function_call"`).
public struct ToolCall: Sendable, Hashable {
    public var id: String?
    public var callID: String?
    public var name: String
    /// JSON-encoded arguments; partial while streaming.
    public var arguments: String
    public var status: ItemStatus?

    public init(id: String?, callID: String?, name: String, arguments: String = "", status: ItemStatus? = nil) {
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.status = status
    }

    /// The id results and resolutions refer to.
    public var resolvedCallID: String? { callID ?? id }
}

/// The result of a `ToolCall` (`type: "function_call_output"`).
public struct ToolResult: Sendable, Hashable {
    public var id: String?
    public var callID: String?
    /// The text parts of the result.
    public var output: [String]
    public var status: ItemStatus?

    public init(id: String?, callID: String?, output: [String] = [], status: ItemStatus? = nil) {
        self.id = id
        self.callID = callID
        self.output = output
        self.status = status
    }

    public var text: String { output.joined() }
}

/// Server-side code execution (`type: "open_webui:code_interpreter"`).
public struct CodeExecutionOutput: Sendable, Hashable {
    public var id: String?
    public var status: ItemStatus?
    public var code: String
    public var stdout: String?
    public var stderr: String?
    public var result: String?

    public init(
        id: String?,
        status: ItemStatus? = nil,
        code: String = "",
        stdout: String? = nil,
        stderr: String? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.status = status
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
        self.result = result
    }
}

/// One item of an assistant Message's structured `output` (OpenResponses-aligned; see
/// docs/research/open-webui-api.md §5.6). Unknown item types are kept as `.other`.
public enum OutputItem: Sendable, Hashable {
    case text(TextOutput)
    case reasoning(ReasoningOutput)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case codeExecution(CodeExecutionOutput)
    case other(type: String, id: String?, status: ItemStatus?)

    /// The wire `type`.
    public var type: String {
        switch self {
        case .text: "message"
        case .reasoning: "reasoning"
        case .toolCall: "function_call"
        case .toolResult: "function_call_output"
        case .codeExecution: "open_webui:code_interpreter"
        case .other(let type, _, _): type
        }
    }

    public var id: String? {
        switch self {
        case .text(let item): item.id
        case .reasoning(let item): item.id
        case .toolCall(let item): item.id
        case .toolResult(let item): item.id
        case .codeExecution(let item): item.id
        case .other(_, let id, _): id
        }
    }

    /// `call_id` for tool calls and results (they're matched by call id, not item id).
    public var callID: String? {
        switch self {
        case .toolCall(let item): item.callID
        case .toolResult(let item): item.callID
        default: nil
        }
    }

    public var status: ItemStatus? {
        get {
            switch self {
            case .text(let item): item.status
            case .reasoning(let item): item.status
            case .toolCall(let item): item.status
            case .toolResult(let item): item.status
            case .codeExecution(let item): item.status
            case .other(_, _, let status): status
            }
        }
        set {
            switch self {
            case .text(var item): item.status = newValue; self = .text(item)
            case .reasoning(var item): item.status = newValue; self = .reasoning(item)
            case .toolCall(var item): item.status = newValue; self = .toolCall(item)
            case .toolResult(var item): item.status = newValue; self = .toolResult(item)
            case .codeExecution(var item): item.status = newValue; self = .codeExecution(item)
            case .other(let type, let id, _): self = .other(type: type, id: id, status: newValue)
            }
        }
    }
}

// MARK: - Wire coding

extension OutputItem: Codable {
    private enum Keys: String, CodingKey {
        case type, id, status, role, content, summary, name, arguments, output, code
        case callID = "call_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case duration
    }

    /// `{type, text}` content and summary parts.
    private struct Part: Codable {
        var type: String?
        var text: String?
    }

    private struct ExecutionResult: Codable {
        var stdout: String?
        var stderr: String?
        var result: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "message"
        let id = Self.string(container, .id)
        let status = (try? container.decodeIfPresent(ItemStatus.self, forKey: .status)) ?? nil

        switch type {
        case "message":
            self = .text(TextOutput(id: id, status: status, parts: Self.parts(container, .content)))
        case "reasoning":
            self = .reasoning(ReasoningOutput(
                id: id,
                status: status,
                content: Self.parts(container, .content),
                summary: Self.parts(container, .summary),
                startedAt: Self.double(container, .startedAt).map(Date.init(timeIntervalSince1970:)),
                endedAt: Self.double(container, .endedAt).map(Date.init(timeIntervalSince1970:)),
                duration: Self.double(container, .duration)
            ))
        case "function_call":
            self = .toolCall(ToolCall(
                id: id,
                callID: Self.string(container, .callID),
                name: Self.string(container, .name) ?? "",
                arguments: Self.string(container, .arguments) ?? "",
                status: status
            ))
        case "function_call_output":
            self = .toolResult(ToolResult(
                id: id,
                callID: Self.string(container, .callID),
                output: Self.parts(container, .output),
                status: status
            ))
        case "open_webui:code_interpreter":
            let result = (try? container.decodeIfPresent(ExecutionResult.self, forKey: .output)) ?? nil
            self = .codeExecution(CodeExecutionOutput(
                id: id,
                status: status,
                code: Self.string(container, .code) ?? "",
                stdout: result?.stdout,
                stderr: result?.stderr,
                result: result?.result
            ))
        default:
            self = .other(type: type, id: id, status: status)
        }
    }

    private static func string(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    private static func double(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> Double? {
        (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil
    }

    /// `content`/`summary`/`output` part lists; a bare string (legacy servers) becomes one part.
    private static func parts(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> [String] {
        if let list = (try? container.decodeIfPresent([Part].self, forKey: key)) ?? nil {
            return list.map { $0.text ?? "" }
        }
        if let text = string(container, key) {
            return [text]
        }
        return []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(status, forKey: .status)
        switch self {
        case .text(let item):
            try container.encode("assistant", forKey: .role)
            try container.encode(item.parts.map { Part(type: "output_text", text: $0) }, forKey: .content)
        case .reasoning(let item):
            try container.encode(item.content.map { Part(type: "output_text", text: $0) }, forKey: .content)
            try container.encode(item.summary.map { Part(type: "summary_text", text: $0) }, forKey: .summary)
            try container.encodeIfPresent(item.startedAt?.timeIntervalSince1970, forKey: .startedAt)
            try container.encodeIfPresent(item.endedAt?.timeIntervalSince1970, forKey: .endedAt)
            try container.encodeIfPresent(item.duration, forKey: .duration)
        case .toolCall(let item):
            try container.encodeIfPresent(item.callID, forKey: .callID)
            try container.encode(item.name, forKey: .name)
            try container.encode(item.arguments, forKey: .arguments)
        case .toolResult(let item):
            try container.encodeIfPresent(item.callID, forKey: .callID)
            try container.encode(item.output.map { Part(type: "input_text", text: $0) }, forKey: .output)
        case .codeExecution(let item):
            try container.encode(item.code, forKey: .code)
            try container.encode(ExecutionResult(stdout: item.stdout, stderr: item.stderr, result: item.result), forKey: .output)
        case .other:
            break
        }
    }
}
