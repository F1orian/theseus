/// Which field a streaming delta appends to (the middle segment of `response.<kind>.delta`).
public enum DeltaKind: Sendable, Hashable {
    /// `output_text` / `text`: assistant text.
    case text
    /// `reasoning_text`: the Thinking body.
    case reasoning
    /// `reasoning_summary_text`: a Thinking summary.
    case reasoningSummary
    /// `function_call_arguments`: tool-call arguments JSON.
    case toolArguments
}

/// One step of a streaming Response, independent of the transport (ADR 0003). Socket.IO
/// `response:completion` / `chat:completion` events and SSE chunks all reduce to these, and
/// `ResponseState.apply(_:)` folds them into the Response.
public enum ResponseEvent: Sendable, Hashable {
    // MARK: OpenResponses item events (`response:completion`)

    /// `response.output_item.added`.
    case itemAdded(outputIndex: Int?, item: OutputItem)
    /// `response.content_part.added` / `response.reasoning_summary_part.added`; adds an empty part.
    case partAdded(outputIndex: Int?, summary: Bool)
    /// `response.<kind>.delta`. `index` is the content (or summary) index.
    case delta(DeltaKind, itemID: String?, outputIndex: Int?, index: Int, text: String)
    /// `response.<kind>.done` carrying the final value of the field.
    case fieldDone(DeltaKind, itemID: String?, outputIndex: Int?, index: Int, text: String)
    /// `response.output_item.done`.
    case itemDone(outputIndex: Int?, item: OutputItem)

    // MARK: Snapshots and legacy text (`chat:completion`, `message`, `replace`, SSE chunks)

    /// The full `output` so far; replaces what the client accumulated.
    case snapshot([OutputItem])
    /// Plain text to append (OpenAI `choices[].delta.content`, function-emitted `message`).
    case legacyTextDelta(String)
    /// Plain reasoning to append (`choices[].delta.reasoning_content`). Empty strings mean the
    /// model is thinking without visible text.
    case legacyReasoningDelta(String)
    /// Replaces the plain text (`chat:completion {content}`, `replace`).
    case legacyText(String)

    // MARK: Side channels

    case status(StatusUpdate)
    case source(Source)
    case sources([Source])
    case followUps([String])
    /// `embeds` / `chat:message:embeds`: rich tool views (HTML or URLs), appended unless `replace`.
    case embeds([String], replace: Bool)
    /// `files` / `chat:message:files`: files the Response produced (generated images, tool
    /// results), appended unless `replace` (OT-03, #134).
    case files([Attachment], replace: Bool)

    // MARK: Endings

    /// `chat:completion {done: true}`, with the final output when the server sends it.
    case completed(output: [OutputItem]?)
    /// `chat:tasks:cancel`: the user stopped it; the partial output is kept.
    case cancelled(output: [OutputItem]?)
    /// `chat:message:error` (or a transport failure while streaming).
    case failed(String)
}

/// A server event about one Chat (or one of its Messages). Transports decode Socket.IO
/// `events` envelopes into these; `messageID` routes response events to the right Message.
public struct ChatEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Applies to the Response in `messageID`.
        case response(ResponseEvent)
        /// Auto-generated title (CHAT-11). May arrive before the client knows the chat id.
        case title(String)
        /// Generation started (`true`) or ended for the Chat.
        case active(Bool)
        /// The server inserted a turn (`chat:messages`); refetch to pick it up.
        case messagesInserted
        /// The Chat list changed (`chat:list`).
        case listChanged
        /// A live clarifying question that expects a Socket.IO acknowledgement.
        case questionsRequested(ClarifyingQuestions, ackID: Int)
        /// A live interaction finished or timed out on the server.
        case interactionDone(id: String?)
        /// A toast-style message from a tool or function.
        case notification(level: String, text: String)
        /// A browser-only request (code execution, direct tools) that needs a refusal ack.
        case unsupportedCall(type: String, ackID: Int)
        /// An event type this client doesn't use.
        case ignored(type: String)
    }

    public var chatID: String?
    public var messageID: String?
    public var kind: Kind

    public init(chatID: String?, messageID: String?, kind: Kind) {
        self.chatID = chatID
        self.messageID = messageID
        self.kind = kind
    }
}
