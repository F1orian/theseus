import Foundation

/// A Response as it streams in: the reducer behind every transport (ADR 0003).
///
/// `apply(_:)` folds `ResponseEvent`s into the OpenResponses `output` item list the same way the
/// server does (`handle_responses_streaming_event`), so the client's view and the stored Message
/// converge. Snapshots (`chat:completion {output}`) replace the accumulated state outright.
public struct ResponseState: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Sent; nothing visible has arrived yet (the pulsing mark).
        case waiting
        case streaming
        /// Paused on a clarifying question (CHAT-09).
        case awaitingAnswer
        case completed
        /// Stopped by the user (CHAT-02); the partial output stays.
        case stopped
        case failed
    }

    public private(set) var output: [OutputItem]
    /// Text that arrived outside output items (older servers, SSE, function `message` events).
    public private(set) var legacyText: String
    public private(set) var legacyReasoning: String
    public private(set) var statusHistory: [StatusUpdate]
    public private(set) var sources: [Source]
    public private(set) var followUps: [String]
    /// Rich views tools attached (`embeds` events / `message.embeds`): HTML documents or URLs.
    public private(set) var embeds: [String]
    /// Files the Response produced (`files` events / assistant `message.files`, #134).
    public private(set) var files: [Attachment]
    public private(set) var error: String?
    public private(set) var phase: Phase
    /// The model is reasoning without visible text (empty `reasoning_content` deltas).
    public private(set) var isThinkingSilently: Bool
    /// Increases with every change, so renderers can skip identical frames cheaply.
    public private(set) var revision: Int

    public init() {
        output = []
        legacyText = ""
        legacyReasoning = ""
        statusHistory = []
        sources = []
        followUps = []
        embeds = []
        files = []
        error = nil
        phase = .waiting
        isThinkingSilently = false
        revision = 0
    }

    /// A stored (or overlaid in-progress) assistant Message.
    public init(
        output: [OutputItem],
        content: String,
        sources: [Source] = [],
        statusHistory: [StatusUpdate] = [],
        followUps: [String] = [],
        error: String? = nil,
        isDone: Bool,
        embeds: [String] = [],
        files: [Attachment] = []
    ) {
        self.init()
        self.output = output
        legacyText = output.isEmpty ? content : ""
        self.sources = sources
        self.statusHistory = statusHistory
        self.followUps = followUps
        self.embeds = embeds
        self.files = files
        self.error = error
        if error != nil {
            phase = .failed
        } else if isDone {
            phase = output.contains(where: { $0.status == .incomplete }) ? .stopped : .completed
        } else if Self.awaitsUser(in: output) {
            phase = .awaitingAnswer
        } else {
            phase = output.isEmpty && content.isEmpty ? .waiting : .streaming
        }
    }

    // MARK: Reducer

    public mutating func apply(_ event: ResponseEvent) {
        revision += 1
        switch event {
        case .itemAdded(let outputIndex, let item):
            insertOrReplace(item, at: outputIndex)
            markStreaming()
        case .partAdded(let outputIndex, let summary):
            guard let index = resolve(itemID: nil, outputIndex: outputIndex) else { return }
            switch output[index] {
            case .text(var item) where !summary:
                item.parts.append("")
                output[index] = .text(item)
            case .reasoning(var item) where summary:
                item.summary.append("")
                output[index] = .reasoning(item)
            default:
                break
            }
        case .delta(let kind, let itemID, let outputIndex, let partIndex, let text):
            applyDelta(kind, itemID: itemID, outputIndex: outputIndex, partIndex: partIndex, text: text, replace: false)
            markStreaming()
        case .fieldDone(let kind, let itemID, let outputIndex, let partIndex, let text):
            applyDelta(kind, itemID: itemID, outputIndex: outputIndex, partIndex: partIndex, text: text, replace: true)
        case .itemDone(let outputIndex, let item):
            if let existing = matchingIndex(for: item) {
                output[existing] = item
            } else if let outputIndex, output.indices.contains(outputIndex) {
                output[outputIndex] = item
            } else {
                output.append(item)
            }
        case .snapshot(let items):
            output = items
            if !items.isEmpty { markStreaming() }
            if Self.awaitsUser(in: items) {
                phase = .awaitingAnswer
            }
        case .legacyTextDelta(let text):
            legacyText += text
            if !text.isEmpty { markStreaming() }
        case .legacyReasoningDelta(let text):
            if text.isEmpty {
                if phase == .waiting { isThinkingSilently = true }
            } else {
                legacyReasoning += text
                markStreaming()
            }
        case .legacyText(let text):
            legacyText = text
            markStreaming()
        case .status(let update):
            if let last = statusHistory.last, last.action == update.action, last.description == update.description {
                statusHistory[statusHistory.count - 1] = update
            } else {
                statusHistory.append(update)
            }
        case .source(let source):
            sources.append(source)
        case .sources(let list):
            sources = list
        case .followUps(let list):
            followUps = list
        case .embeds(let list, let replace):
            embeds = replace ? list : embeds + list
        case .files(let list, let replace):
            let base = replace ? [] : files
            files = base + list.filter { new in !base.contains { $0.id == new.id } }
        case .completed(let items):
            if let items, !items.isEmpty { output = items }
            finishActiveItems(as: .completed)
            if phase != .failed {
                phase = Self.awaitsUser(in: output) ? .awaitingAnswer : .completed
            }
            isThinkingSilently = false
        case .cancelled(let items):
            if let items, !items.isEmpty { output = items }
            finishActiveItems(as: .incomplete)
            phase = .stopped
            isThinkingSilently = false
        case .failed(let message):
            error = message
            finishActiveItems(as: .incomplete)
            phase = .failed
            isThinkingSilently = false
        }
    }

    /// Marks a Response that resumes from a server snapshot (CHAT-12) as live again.
    public mutating func resume() {
        guard phase != .awaitingAnswer else { return }
        phase = output.isEmpty && legacyText.isEmpty ? .waiting : .streaming
        revision += 1
    }

    /// Re-arms the state for an answered clarifying question; the continuation streams in.
    /// The question's tool call counts as answered right away, so the card goes away.
    public mutating func continueAfterAnswer(callID: String? = nil) {
        if let callID {
            for index in output.indices {
                if case .toolCall(var call) = output[index], call.resolvedCallID == callID {
                    call.status = .queued
                    output[index] = .toolCall(call)
                }
            }
        }
        phase = .streaming
        revision += 1
    }

    private mutating func markStreaming() {
        if phase == .waiting || phase == .awaitingAnswer { phase = .streaming }
        isThinkingSilently = false
    }

    private mutating func finishActiveItems(as status: ItemStatus) {
        for index in output.indices where output[index].status?.isActive ?? false {
            output[index].status = status
        }
    }

    /// Item identity follows the server: same `id`, or same `type` + `call_id`.
    private func matchingIndex(for item: OutputItem) -> Int? {
        output.firstIndex { existing in
            if let id = item.id, existing.id == id { return true }
            if let callID = item.callID, existing.type == item.type, existing.callID == callID { return true }
            return false
        }
    }

    private mutating func insertOrReplace(_ item: OutputItem, at outputIndex: Int?) {
        if let existing = matchingIndex(for: item) {
            output[existing] = item
        } else if let outputIndex, outputIndex >= 0, outputIndex < output.count {
            output.insert(item, at: outputIndex)
        } else {
            output.append(item)
        }
    }

    /// Finds the item a delta targets: by `item_id` when it matches, else by `output_index`.
    /// Like the server, a delta past the end creates the item (Chat Completions providers start
    /// items with a delta, without an `added` event).
    private mutating func resolve(itemID: String?, outputIndex: Int?, creating kind: DeltaKind? = nil) -> Int? {
        if let itemID, let index = output.firstIndex(where: { $0.id == itemID }) {
            return index
        }
        let index = outputIndex ?? max(output.count - 1, 0)
        if index >= output.count, let kind {
            while output.count <= index {
                output.append(Self.placeholder(for: kind, id: output.count == index ? itemID : nil))
            }
        }
        return output.indices.contains(index) ? index : nil
    }

    private static func placeholder(for kind: DeltaKind, id: String?) -> OutputItem {
        switch kind {
        case .text: .text(TextOutput(id: id, status: .inProgress))
        case .reasoning, .reasoningSummary: .reasoning(ReasoningOutput(id: id, status: .inProgress))
        case .toolArguments: .toolCall(ToolCall(id: id, callID: id, name: "", status: .inProgress))
        }
    }

    private mutating func applyDelta(
        _ kind: DeltaKind,
        itemID: String?,
        outputIndex: Int?,
        partIndex: Int,
        text: String,
        replace: Bool
    ) {
        guard let index = resolve(itemID: itemID, outputIndex: outputIndex, creating: replace ? nil : kind) else { return }
        func merge(_ parts: inout [String]) {
            let slot = max(partIndex, 0)
            while parts.count <= slot { parts.append("") }
            parts[slot] = replace ? text : parts[slot] + text
        }
        switch (kind, output[index]) {
        case (.text, .text(var item)):
            merge(&item.parts)
            output[index] = .text(item)
        case (.reasoning, .reasoning(var item)):
            merge(&item.content)
            if replace { item.status = .completed }
            output[index] = .reasoning(item)
        case (.reasoningSummary, .reasoning(var item)):
            merge(&item.summary)
            output[index] = .reasoning(item)
        case (.toolArguments, .toolCall(var item)):
            item.arguments = replace ? text : item.arguments + text
            output[index] = .toolCall(item)
        default:
            // Text deltas never land on reasoning items and vice versa (server behaviour).
            break
        }
    }

    // MARK: Derived views

    public var isFinished: Bool {
        switch phase {
        case .completed, .stopped, .failed: true
        case .waiting, .streaming, .awaitingAnswer: false
        }
    }

    /// The Response's plain text (assistant text items, or legacy text with Thinking tags removed).
    public var text: String {
        let items = output.compactMap { item -> String? in
            if case .text(let text) = item { return text.text }
            return nil
        }
        if !items.isEmpty { return items.joined(separator: "\n\n") }
        return SerializedContent.plainText(ThinkingTags.split(legacyText).text)
    }

    /// The clarifying question this Response waits on, if any.
    public var pendingQuestions: ClarifyingQuestions? {
        Self.pendingQuestion(in: output)
    }

    static func pendingQuestion(in output: [OutputItem]) -> ClarifyingQuestions? {
        let answered = Set(output.compactMap { item -> String? in
            if case .toolResult(let result) = item { return result.callID }
            return nil
        })
        for item in output.reversed() {
            guard case .toolCall(let call) = item,
                  call.name == ToolActivity.askUserName,
                  call.status == .pending || call.status == .requiresApproval,
                  let callID = call.resolvedCallID,
                  !answered.contains(callID)
            else { continue }
            return ClarifyingQuestions(callID: callID, arguments: call.arguments)
        }
        return nil
    }

    /// The tool call this Response waits for the user to allow (`params.tool_approval_mode: "ask"`,
    /// OT-06): the paused call the server marked `pending`, else the first awaiting approval.
    public var pendingApproval: ToolCall? {
        Self.pendingApproval(in: output)
    }

    static func pendingApproval(in output: [OutputItem]) -> ToolCall? {
        let answered = Set(output.compactMap { item -> String? in
            if case .toolResult(let result) = item { return result.callID }
            return nil
        })
        let waiting = output.compactMap { item -> ToolCall? in
            guard case .toolCall(let call) = item, call.name != ToolActivity.askUserName,
                  call.status == .pending || call.status == .requiresApproval,
                  let callID = call.resolvedCallID, !answered.contains(callID)
            else { return nil }
            return call
        }
        return waiting.first { $0.status == .pending } ?? waiting.first
    }

    /// Paused on the user: a clarifying question or a tool call to allow.
    static func awaitsUser(in output: [OutputItem]) -> Bool {
        pendingQuestion(in: output) != nil || pendingApproval(in: output) != nil
    }

    /// The Response's tool steps named `name`, in order. Cheap when there are none (it only
    /// builds `parts` when the name occurs).
    public func toolSteps(named name: String) -> [ToolActivity] {
        let mayHold = output.isEmpty
            ? legacyText.contains("name=\"\(name)\"")
            : output.contains { item in
                if case .toolCall(let call) = item { return call.name == name }
                return false
            }
        guard mayHold else { return [] }
        return parts.flatMap { part -> [ToolActivity] in
            if case .tools(_, let steps) = part { return steps.filter { $0.name == name } }
            return []
        }
    }

    /// Whether the Server's code interpreter ran code for this Response (CONN-08, ADR 0173): an
    /// `open_webui:code_interpreter` item with code (legacy function calling), a builtin
    /// `execute_code` call the Server answered (native function calling), or a serialized
    /// `code_interpreter` block. A call that never got a result ran nothing.
    public var ranCodeInterpreter: Bool {
        if output.isEmpty {
            guard SerializedContent.mayContainBlocks(legacyText) else { return false }
            if legacyText.contains(#"<details type="code_interpreter""#) { return true }
            return parts.contains { part in
                guard case .tools(_, let steps) = part else { return false }
                return steps.contains { ToolActivity.codeInterpreterNames.contains($0.name) && $0.result != nil }
            }
        }
        let answered = Set(output.compactMap { item -> String? in
            if case .toolResult(let result) = item { return result.callID }
            return nil
        })
        return output.contains { item in
            switch item {
            case .codeExecution(let run):
                return !run.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolCall(let call):
                guard ToolActivity.codeInterpreterNames.contains(call.name), let callID = call.resolvedCallID else { return false }
                return answered.contains(callID)
            default:
                return false
            }
        }
    }

    /// The Response as an ordered list of renderable parts (Thinking, text, tool activity, …).
    public var parts: [ResponsePart] {
        ResponsePart.build(from: self)
    }
}
