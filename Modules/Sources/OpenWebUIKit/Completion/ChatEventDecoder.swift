public import ChatDomain
import Foundation

/// Turns Open WebUI's Socket.IO `events` envelopes into domain `ChatEvent`s.
///
/// Envelope: `{chat_id, message_id, data: {type, data}}` (docs/research/open-webui-api.md §6.3).
/// One envelope can carry several facts (e.g. `chat:completion {done, output, title}`), so the
/// decoder returns a list. Shared-chat copies (`shared: true`, for other viewers) are skipped:
/// the owner's own copy carries the same data at full rate.
public enum ChatEventDecoder {
    public static func decode(_ envelope: JSONValue, ackID: Int? = nil) -> [ChatEvent] {
        guard envelope[path: "shared"]?.boolValue != true,
              let type = envelope[path: "data.type"]?.stringValue
        else { return [] }
        let chatID = envelope[path: "chat_id"]?.stringValue
        let messageID = envelope[path: "message_id"]?.stringValue
        let data = envelope.objectValue?["data"]?.objectValue?["data"] ?? .null
        return kinds(type: type, data: data, ackID: ackID).map { ChatEvent(chatID: chatID, messageID: messageID, kind: $0) }
    }

    static func kinds(type: String, data: JSONValue, ackID: Int?) -> [ChatEvent.Kind] {
        switch type {
        case "response:completion":
            return responseCompletion(data).map(ChatEvent.Kind.response)
        case "chat:completion":
            return chatCompletion(data)
        case "status":
            return data.decoded(as: StatusUpdate.self).map { [.response(.status($0))] } ?? []
        case "source", "citation":
            // `type: code_execution` records are code-interpreter runs, not Sources.
            guard data[path: "type"] == nil || data[path: "type"] == .null else { return [] }
            return data.decoded(as: Source.self).map { [.response(.source($0))] } ?? []
        case "message", "chat:message:delta":
            return [.response(.legacyTextDelta(data[path: "content"]?.stringValue ?? ""))]
        case "replace", "chat:message":
            guard let content = data[path: "content"]?.stringValue else { return [] }
            return [.response(.legacyText(content))]
        case "chat:message:error":
            return [.response(.failed(errorMessage(data[path: "error"]) ?? "Something went wrong."))]
        case "chat:tasks:cancel":
            return [.response(.cancelled(output: data[path: "output"]?.decoded(as: [OutputItem].self)))]
        case "chat:message:follow_ups":
            let list = data[path: "follow_ups"]?.decoded(as: [String].self) ?? []
            return [.response(.followUps(list))]
        case "embeds", "chat:message:embeds":
            let list = data[path: "embeds"]?.decoded(as: [JSONValue].self)?.compactMap(\.stringValue) ?? []
            return [.response(.embeds(list, replace: data[path: "replace"]?.boolValue ?? false))]
        case "files", "chat:message:files":
            let list = data[path: "files"]?.arrayValue ?? []
            let files = list.enumerated().compactMap { index, file -> Attachment? in
                guard let attachment = MessageWire.attachment(from: file, index: index) else { return nil }
                // Images often carry no id; their URL tells separate events apart.
                guard file[path: "id"]?.stringValue == nil, let url = attachment.url else { return attachment }
                return Attachment(id: url, name: attachment.name, kind: attachment.kind, contentType: attachment.contentType, size: attachment.size, url: url)
            }
            return [.response(.files(files, replace: type == "chat:message:files"))]
        case "chat:title":
            guard let title = data.stringValue ?? data[path: "title"]?.stringValue, !title.isEmpty else { return [] }
            return [.title(title)]
        case "chat:active":
            return [.active(data[path: "active"]?.boolValue ?? false)]
        case "chat:messages":
            return [.messagesInserted]
        case "chat:list":
            return [.listChanged]
        case "request:user_input":
            guard let ackID,
                  let questions = questions(from: data)
            else { return ackID.map { [.unsupportedCall(type: type, ackID: $0)] } ?? [] }
            return [.questionsRequested(questions, ackID: ackID)]
        case "request:interaction:done":
            return [.interactionDone(id: data[path: "interaction_id"]?.stringValue)]
        case "notification":
            return [.notification(
                level: data[path: "type"]?.stringValue ?? "info",
                text: data[path: "content"]?.stringValue ?? ""
            )]
        default:
            // Calls that expect a browser (code execution, direct tools, prompts) must still be
            // answered, or the server waits for its timeout.
            if let ackID { return [.unsupportedCall(type: type, ackID: ackID)] }
            return [.ignored(type: type)]
        }
    }

    // MARK: response:completion

    static func responseCompletion(_ data: JSONValue) -> [ResponseEvent] {
        guard let type = data[path: "type"]?.stringValue else {
            return chatCompletionChunk(data)
        }
        let outputIndex = data[path: "output_index"]?.intValue
        let itemID = data[path: "item_id"]?.stringValue
        switch type {
        case "response.output_item.added":
            guard let item = data[path: "item"]?.decoded(as: OutputItem.self) else { return [] }
            return [.itemAdded(outputIndex: outputIndex, item: item)]
        case "response.output_item.done":
            guard let item = data[path: "item"]?.decoded(as: OutputItem.self) else { return [] }
            return [.itemDone(outputIndex: outputIndex, item: item)]
        case "response.content_part.added":
            return [.partAdded(outputIndex: outputIndex, summary: false)]
        case "response.reasoning_summary_part.added":
            return [.partAdded(outputIndex: outputIndex, summary: true)]
        default:
            let segments = type.split(separator: ".")
            guard segments.count >= 3, segments.first == "response", let kind = deltaKind(String(segments[1])) else { return [] }
            let index = (kind == .reasoningSummary ? data[path: "summary_index"] : data[path: "content_index"])?.intValue ?? 0
            switch segments.last {
            case "delta":
                guard let delta = data[path: "delta"]?.stringValue else { return [] }
                return [.delta(kind, itemID: itemID, outputIndex: outputIndex, index: index, text: delta)]
            case "done":
                let key = kind == .toolArguments ? "arguments" : "text"
                guard let value = data[path: key]?.stringValue else { return [] }
                return [.fieldDone(kind, itemID: itemID, outputIndex: outputIndex, index: index, text: value)]
            default:
                return []
            }
        }
    }

    private static func deltaKind(_ name: String) -> DeltaKind? {
        switch name {
        case "output_text", "text": .text
        case "reasoning_text": .reasoning
        case "reasoning_summary_text": .reasoningSummary
        case "function_call_arguments": .toolArguments
        default: nil
        }
    }

    /// An OpenAI `chat.completion.chunk` (older servers, pipes, and the role/reasoning preamble).
    static func chatCompletionChunk(_ data: JSONValue) -> [ResponseEvent] {
        guard case .array(let choices)? = data[path: "choices"], let delta = choices.first?[path: "delta"] else { return [] }
        var events: [ResponseEvent] = []
        for key in ["reasoning_content", "reasoning"] {
            if let reasoning = delta[path: key]?.stringValue {
                events.append(.legacyReasoningDelta(reasoning))
            }
        }
        if let content = delta[path: "content"]?.stringValue, !content.isEmpty {
            events.append(.legacyTextDelta(content))
        }
        return events
    }

    // MARK: chat:completion

    static func chatCompletion(_ data: JSONValue) -> [ChatEvent.Kind] {
        var kinds: [ChatEvent.Kind] = []
        if let error = data[path: "error"], error != .null {
            kinds.append(.response(.failed(errorMessage(error) ?? "Something went wrong.")))
        }
        if data[path: "choices"] != nil {
            kinds += chatCompletionChunk(data).map(ChatEvent.Kind.response)
        }
        if let sources = data[path: "sources"]?.decoded(as: [Source].self) {
            kinds.append(.response(.sources(sources)))
        }
        let output = data[path: "output"]?.decoded(as: [OutputItem].self)
        if data[path: "done"]?.boolValue == true {
            kinds.append(.response(.completed(output: output)))
        } else if let output {
            kinds.append(.response(.snapshot(output)))
        } else if let content = data[path: "content"]?.stringValue {
            kinds.append(.response(.legacyText(content)))
        }
        if let title = data[path: "title"]?.stringValue, !title.isEmpty {
            kinds.append(.title(title))
        }
        return kinds
    }

    // MARK: Helpers

    private static func errorMessage(_ error: JSONValue?) -> String? {
        guard let error else { return nil }
        if let text = error.stringValue { return text }
        return error[path: "content"]?.stringValue ?? error[path: "message"]?.stringValue ?? error[path: "detail"]?.stringValue
    }

    /// `request:user_input` carries the same questions as `ask_user` arguments, plus an
    /// `interaction_id` that stands in for the call id.
    private static func questions(from data: JSONValue) -> ClarifyingQuestions? {
        guard let encoded = try? JSONEncoder().encode(data) else { return nil }
        let id = data[path: "interaction_id"]?.stringValue ?? "interaction"
        return ClarifyingQuestions(callID: id, arguments: String(decoding: encoded, as: UTF8.self))
    }
}

extension JSONValue {
    /// Whole numbers as `Int`.
    public var intValue: Int? {
        if case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 { return Int(value) }
        return nil
    }

    /// Re-decodes this value as `type` (`nil` when it doesn't match).
    public func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
