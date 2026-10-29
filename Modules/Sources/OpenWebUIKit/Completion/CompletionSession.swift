public import ChatDomain
public import Foundation
import Synchronization

/// What the user asked for in one Response. The server owns the Chat document (it inserts the
/// user Message and the assistant placeholder itself), so the request names the parent only.
/// Message ids are minted by the client, which is how events are matched to the Response before
/// the server has even answered the request.
public struct CompletionRequest: Sendable, Equatable {
    /// One earlier Message of the visible thread (SSE fallback only: the stateless endpoint has
    /// no server-side history).
    public struct HistoryEntry: Sendable, Equatable {
        public var role: Message.Role
        public var content: String
        /// Inline images (`data:` URLs) of a user Message in an Incognito chat.
        public var images: [String]

        public init(role: Message.Role, content: String, images: [String] = []) {
            self.role = role
            self.content = content
            self.images = images
        }
    }

    /// `nil` starts a new Chat.
    public var chatID: String?
    public var modelID: String
    public var prompt: String
    /// The Message the new user Message is a child of (`nil` for the first Message).
    public var parentMessageID: String?
    /// Incognito chat: never saved to the Server (server term: temporary chat).
    public var isIncognito: Bool
    public var userMessageID: String
    public var assistantMessageID: String
    /// Per-message feature toggles (`web_search`, `code_interpreter`, …).
    public var features: [String: Bool]
    /// Request title generation for new Chats (CHAT-11).
    public var generatesTitle: Bool
    public var history: [HistoryEntry]
    /// Attachments of this user Message (`user_message.files`).
    public var files: [FileReference] = []
    /// Documents attached earlier in the Chat; they stay in the retrieval context (top-level `files`).
    public var contextFiles: [FileReference] = []
    /// Request parameters (`params`): `reasoning_effort`, `model_controls`, … (MODEL-02).
    public var params: [String: JSONValue] = [:]
    /// Connectors enabled for this Message (`tool_ids`, CONN-02).
    public var toolIDs: [String] = []
    /// The terminal server whose sandbox the model may use (`terminal_id`, Open Terminal #132).
    /// `nil` sends none: the server never falls back to the model's default terminal on its own.
    public var terminalID: String?
    /// Skills picked for this Message (`skill_ids`, #140): the server adds their instructions.
    public var skillIDs: [String] = []
    /// Personal connectors (direct tool servers) for this Message (`tool_servers`, #186): their
    /// specs, never their keys. Empty uses the session's `DirectToolServers`, if any.
    public var toolServers: [JSONValue] = []
    /// Ask the server for follow-up suggestions after the Response (`follow_up_generation`, #141).
    /// Ignored for Incognito chats, which run no background tasks.
    public var generatesFollowUps = false
    /// Prompt variables beyond personalization, e.g. `{{USER_LOCATION}}` (CONN-07). They win over
    /// personalization's on a clash.
    public var variables: [String: String] = [:]
    /// Photos of this user Message as inline `data:` URLs (Incognito chats upload nothing).
    public var inlineImages: [String] = []
    /// The Project (server: folder) a new Chat is created in (`folder_id`). Ignored for follow-ups
    /// and Incognito chats.
    public var folderID: String?

    /// The request's top-level `files`: every document of the Chat so far, without images
    /// (those reach vision models through the Message itself).
    public var retrievalFiles: [FileReference] {
        var seen = Set<String>()
        // Sandbox files (OT-05) are read in the sandbox, never retrieved.
        return (contextFiles + files).filter { !$0.isImage && $0.sandbox == nil && seen.insert($0.id).inserted }
    }

    /// Profile Instructions, Memory and the `{{USER_NAME}}` variable (PERS-01..03), as the web
    /// client sends them. `nil` sends none.
    public var personalization: ChatPersonalization?

    public init(
        chatID: String?,
        modelID: String,
        prompt: String,
        parentMessageID: String? = nil,
        isIncognito: Bool = false,
        userMessageID: String = UUID().uuidString.lowercased(),
        assistantMessageID: String = UUID().uuidString.lowercased(),
        features: [String: Bool] = [:],
        generatesTitle: Bool = true,
        history: [HistoryEntry] = [],
        personalization: ChatPersonalization? = nil
    ) {
        self.chatID = chatID
        self.modelID = modelID
        self.prompt = prompt
        self.parentMessageID = parentMessageID
        self.isIncognito = isIncognito
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.features = features
        self.generatesTitle = generatesTitle
        self.history = history
        self.personalization = personalization
    }

    /// The feature toggles to send: `features` plus `memory` when Memory is on (PERS-03).
    /// Incognito chats never use Memory (INCOG-01).
    var wireFeatures: JSONValue {
        var all = features
        if isIncognito {
            all["memory"] = false
        } else if personalization?.usesMemory == true {
            all["memory"] = true
        }
        return .object(all.mapValues(JSONValue.bool))
    }

    /// `folder_id` for the request: only when it creates a saved Chat.
    var wireFolderID: String? {
        chatID == nil && !isIncognito ? folderID : nil
    }

    /// The visible thread plus the new prompt, for requests the Server has no history for (the
    /// SSE fallback and Incognito chats).
    var conversationMessages: [JSONValue] {
        (history + [.init(role: .user, content: prompt, images: inlineImages)]).map { entry in
            guard !entry.images.isEmpty else {
                return JSONValue.object(["role": .string(entry.role.rawValue), "content": .string(entry.content)])
            }
            // OpenAI multimodal parts, as the web client sends temporary chats' images.
            let parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(entry.content)])]
                + entry.images.map { url in
                    .object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])])
                }
            return JSONValue.object(["role": .string(entry.role.rawValue), "content": .array(parts)])
        }
    }

    /// Profile Instructions and the Style (PERS-02, PERS-05) as the leading system message; the
    /// server keeps it in front of the stored history. The web client composes it the same way.
    var systemMessages: [JSONValue] {
        if personalization?.hasStyle == true, let prompt = personalization?.systemPrompt {
            return [.object(["role": .string("system"), "content": .string(prompt)])]
        }
        guard let instructions = personalization?.instructions else { return [] }
        return [.object(["role": .string("system"), "content": .string(instructions)])]
    }

    /// `params`, plus the Chat's system prompt (`params.system`) when a Style shapes it, as the
    /// web client sends its chat-level system prompt next to the system message (ADR 0111).
    var wireParams: [String: JSONValue] {
        guard personalization?.hasStyle == true, let prompt = personalization?.systemPrompt else { return params }
        var all = params
        all["system"] = .string(prompt)
        return all
    }

    var wireVariables: JSONValue {
        let all = (personalization?.variables ?? [:]).merging(variables) { _, extra in extra }
        return .object(all.mapValues(JSONValue.string))
    }
}

/// The accepted request: where its events will be addressed.
public struct CompletionReceipt: Sendable, Equatable {
    /// `nil` until the Server has created the Chat (SSE: after the Response finished).
    public var chatID: String?
    public var userMessageID: String
    public var assistantMessageID: String
    public var transport: CompletionTransport
}

/// Which wire path carries a Response.
public enum CompletionTransport: Sendable, Equatable {
    /// Socket.IO `events` with a JWT (primary path; supports resume, titles, tool events).
    case socket
    /// OpenAI-compatible SSE (API-key Accounts, or no WebSocket available).
    case serverSentEvents
}

/// The credential an Account authenticates with; it decides which transports are possible.
public enum CredentialKind: Sendable, Equatable {
    case sessionToken
    case apiKey
}

/// Starts Responses and delivers every Chat event through **one** domain stream (ADR 0003).
///
/// - Socket mode: `send(_:)` posts the request with the joined socket's `session_id`; the
///   Response streams in as Socket.IO `events`, decoded into `ChatEvent`s.
/// - SSE fallback (no socket, or the socket can't join in time): the request runs stateless,
///   its chunks are decoded into the same `ChatEvent`s, and the finished turn is saved to the
///   Server afterwards.
///
/// Features subscribe with `events()` and never see the transport.
public final class CompletionSession: Sendable {
    public let client: OpenWebUIClient
    public let socket: SocketIOClient?
    private let hub = ChatEventHub()
    private let pump = Pump()
    private let joinTimeout: Duration
    private let directTools = Mutex<(any DirectToolServers)?>(nil)
    private let directToolTimeout: Duration

    public init(
        client: OpenWebUIClient,
        socket: SocketIOClient?,
        joinTimeout: Duration = .seconds(6),
        directToolTimeout: Duration = .seconds(60)
    ) {
        self.client = client
        self.socket = socket
        self.joinTimeout = joinTimeout
        self.directToolTimeout = directToolTimeout
    }

    /// Plugs in the user's personal connectors (#186, ADR 0095): socket completions list their
    /// tools in `tool_servers`, and `execute:tool` calls run on the device instead of being
    /// refused. `nil` turns them off.
    public func useDirectToolServers(_ servers: (any DirectToolServers)?) {
        directTools.withLock { $0 = servers }
    }

    private func currentDirectTools() -> (any DirectToolServers)? {
        directTools.withLock { $0 }
    }

    /// A session with a real WebSocket when the Server enables it and the credential is a
    /// Session token (the socket handshake rejects API keys).
    public static func live(client: OpenWebUIClient, credential: CredentialKind, serverSupportsWebSocket: Bool) -> CompletionSession {
        let socket: SocketIOClient? = selectTransport(credential: credential, serverSupportsWebSocket: serverSupportsWebSocket) == .socket
            ? SocketIOClient(server: client.server, connector: URLSessionWebSocketConnector()) { await client.sessionToken() }
            : nil
        return CompletionSession(client: client, socket: socket)
    }

    /// The socket handshake only accepts JWTs, so API keys always fall back to SSE (ADR 0003).
    public static func selectTransport(credential: CredentialKind, serverSupportsWebSocket: Bool) -> CompletionTransport {
        credential == .sessionToken && serverSupportsWebSocket ? .socket : .serverSentEvents
    }

    // MARK: Lifecycle

    /// Connects the socket (if any) and starts decoding its events. Idempotent.
    public func start() async {
        guard let socket else { return }
        let events = await socket.events()
        let started = pump.start { [hub, weak self, directToolTimeout] in
            for await event in events where event.name == "events" {
                guard let envelope = event.arguments.first else { continue }
                let decoded = ChatEventDecoder.decode(envelope, ackID: event.ackID)
                await hub.publish(decoded, connection: event.connection)
                // A personal connector's tool (#186): call it from the device, off the event pump
                // so the Response keeps streaming, and always answer (a timeout is a tool error).
                if let ackID = event.ackID, let call = DirectToolCall(envelope: envelope),
                   let servers = self?.currentDirectTools() {
                    let connection = event.connection
                    Task {
                        let result = await DirectToolTimeout.run(limit: directToolTimeout) { await servers.execute(call) }
                        await socket.acknowledge(ackID, connection: connection, with: result)
                    }
                    continue
                }
                for item in decoded {
                    if case .unsupportedCall(let type, let ackID) = item.kind {
                        // Browser-only calls (code execution, direct tools, prompts): refuse
                        // right away so the server doesn't wait for its timeout.
                        await socket.acknowledge(ackID, connection: event.connection, with: Self.refusal(for: type))
                    }
                }
            }
        }
        if started { await socket.start() }
    }

    /// The acknowledgement for a server call only a browser can answer (open-webui-api.md §12.3).
    static func refusal(for type: String) -> JSONValue {
        switch type {
        case "confirmation":
            return .bool(false)
        case "request:terminal:state":
            // No interactive shell is open in this app (OT-07), so the server drops the user-shell
            // tools instead of waiting out its 2 s timeout (B/utils/middleware.py).
            return .object(["connected": .bool(false)])
        case "request:terminal":
            // Personal (direct) terminals are reached through the browser with keys Theseus never holds.
            return .object(["error": .string("Personal terminals aren't supported in this app. Use a terminal the Server provides.")])
        case "execute:tool":
            // A personal connector without `DirectToolServers` plugged in (#186).
            return .object(["error": .string("Personal connectors aren't available in this session. Open Settings › Connectors in Theseus to check them.")])
        case "execute:python":
            // Pyodide code interpreter (CONN-08): the server turns `error` into the run's stderr,
            // so the model sees why nothing ran (B/utils/middleware.py).
            return .object(["error": .string("Code execution isn't available in this app: the Server runs code in the web browser (Pyodide). An admin can switch the code interpreter to Jupyter.")])
        default:
            return .object(["error": .string("This request isn't supported by this app.")])
        }
    }

    public func shutdown() async {
        pump.cancel()
        await socket?.stop()
    }

    /// Retries the socket immediately (foreground, network back, or after re-sign-in).
    public func reconnect() async {
        await socket?.reconnectNow()
    }

    /// Every Chat event, from whichever transport carries it.
    public func events() async -> AsyncStream<ChatEvent> {
        await hub.subscribe()
    }

    /// The socket's connection state; `nil` without a socket.
    public func connectionStates() async -> AsyncStream<SocketIOClient.State>? {
        await socket?.states()
    }

    // MARK: Requests

    /// Starts a Response. Returns as soon as the Server accepted it; the Response itself
    /// arrives through `events()`, addressed to `request.assistantMessageID`.
    public func send(_ request: CompletionRequest) async throws(OpenWebUIError) -> CompletionReceipt {
        if let socket, let sessionID = try? await socket.joinedSessionID(timeout: joinTimeout) {
            var request = request
            if request.toolServers.isEmpty, let servers = currentDirectTools() {
                request.toolServers = await servers.toolServersPayload()
            }
            let body = Self.socketBody(request, sessionID: sessionID)
            let accepted = try await client.send(.startCompletion(body: body))
            return CompletionReceipt(
                // Incognito chats live under their temporary id (stop and answers address it).
                chatID: request.isIncognito ? "temporary:\(sessionID)" : accepted.chatID ?? request.chatID,
                userMessageID: request.userMessageID,
                assistantMessageID: request.assistantMessageID,
                transport: .socket
            )
        }
        return try await sendOverSSE(request)
    }

    /// Stops generation for the Chat (CHAT-02). The partial Response is kept server-side and
    /// arrives as a `cancelled` event.
    public func stop(chatID: String) async throws(OpenWebUIError) {
        _ = try await client.send(.stopChat(id: chatID))
    }

    /// Answers (or, with `nil`, dismisses) a clarifying question (CHAT-09). Saved Chats resolve
    /// the paused tool call over HTTP; live socket questions are answered through their ack.
    public func answer(
        _ questions: ClarifyingQuestions,
        with answers: [String: ClarifyingQuestions.Answer]?,
        chatID: String,
        messageID: String,
        ackID: Int? = nil
    ) async throws(OpenWebUIError) {
        let wire = answers.map { questions.wireAnswers($0) }
        if let ackID, let socket, let connection = await hub.connection(forCall: ackID) {
            let payload: JSONValue = wire.map { answers in
                .object(["status": .string("answered"), "answers": Self.json(answers)])
            } ?? .object(["status": .string("cancelled"), "answers": .object([:])])
            await socket.acknowledge(ackID, connection: connection, with: payload)
            return
        }
        var body: [String: JSONValue] = [
            "call_id": .string(questions.callID),
            "action": .string(wire == nil ? "reject" : "answer"),
        ]
        if let wire { body["answers"] = Self.json(wire) }
        let encoded = (try? WireCoding.encoder.encode(JSONValue.object(body))) ?? Data()
        // The server runs the continuation inside this request, so it can take a while; the
        // Response streams to the socket meanwhile.
        _ = try await client.send(.resolveToolCall(chatID: chatID, messageID: messageID, body: encoded))
    }

    /// Allows or denies a tool call the Response paused on (OT-06, `tool_approval_mode: "ask"`).
    /// The server runs the tools (or the model) inside this request; the Response streams on.
    public func resolveApproval(callID: String, approve: Bool, chatID: String, messageID: String) async throws(OpenWebUIError) {
        let body: JSONValue = .object(["call_id": .string(callID), "action": .string(approve ? "approve" : "reject")])
        let encoded = (try? WireCoding.encoder.encode(body)) ?? Data()
        _ = try await client.send(.resolveToolCall(chatID: chatID, messageID: messageID, body: encoded))
    }

    // MARK: Socket mode

    /// The body the web client sends (docs/research/open-webui-api.md §5.2).
    static func socketBody(_ request: CompletionRequest, sessionID: String) -> Data {
        var userMessage: [String: JSONValue] = [
            "id": .string(request.userMessageID),
            "parentId": request.parentMessageID.map(JSONValue.string) ?? .null,
            "childrenIds": .array([]),
            "role": .string("user"),
            "content": .string(request.prompt),
            "timestamp": .number(Date().timeIntervalSince1970.rounded(.down)),
            "models": .array([.string(request.modelID)]),
        ]
        userMessage["files"] = .array(request.files.map(\.jsonValue))
        var body: [String: JSONValue] = [
            "stream": .bool(true),
            "model": .string(request.modelID),
            // Saved Chats: the Server loads the history itself. Incognito chats aren't stored, so
            // every turn carries the whole conversation.
            "messages": .array(request.systemMessages + (request.isIncognito ? request.conversationMessages : [])),
            "params": .object(request.wireParams),
            "tool_servers": .array(request.toolServers),
            "features": request.wireFeatures,
            "variables": request.wireVariables,
            "model_item": .object(["id": .string(request.modelID)]),
            "session_id": .string(sessionID),
            "parent_id": request.parentMessageID.map(JSONValue.string) ?? .null,
            "user_message": .object(userMessage),
            "message_ids": .array([.object([
                "model_id": .string(request.modelID),
                "message_id": .string(request.assistantMessageID),
                "modelIdx": .number(0),
            ])]),
            "background_tasks": .object([
                "title_generation": .bool(request.generatesTitle && request.chatID == nil && !request.isIncognito),
                "tags_generation": .bool(false),
                "follow_up_generation": .bool(request.generatesFollowUps && !request.isIncognito),
            ]),
        ]
        let retrieval = request.retrievalFiles
        if !retrieval.isEmpty {
            body["files"] = .array(retrieval.map(\.jsonValue))
        }
        if !request.toolIDs.isEmpty {
            body["tool_ids"] = .array(request.toolIDs.map(JSONValue.string))
        }
        if let terminalID = request.terminalID {
            body["terminal_id"] = .string(terminalID)
        }
        if !request.skillIDs.isEmpty {
            body["skill_ids"] = .array(request.skillIDs.map(JSONValue.string))
        }
        if request.isIncognito {
            body["chat_id"] = .string("temporary:\(sessionID)")
        } else if let chatID = request.chatID {
            body["chat_id"] = .string(chatID)
        }
        if let folderID = request.wireFolderID {
            body["folder_id"] = .string(folderID)
        }
        return (try? WireCoding.encoder.encode(JSONValue.object(body))) ?? Data()
    }

    // MARK: SSE fallback

    /// The stateless OpenAI-compatible body: the visible thread, led by profile Instructions.
    static func sseBody(_ request: CompletionRequest) -> Data {
        var body: [String: JSONValue] = [
            "stream": .bool(true),
            "model": .string(request.modelID),
            "messages": .array(request.systemMessages + request.conversationMessages),
            "features": request.wireFeatures,
        ]
        if request.personalization != nil || !request.variables.isEmpty { body["variables"] = request.wireVariables }
        if !request.toolIDs.isEmpty { body["tool_ids"] = .array(request.toolIDs.map(JSONValue.string)) }
        if let terminalID = request.terminalID { body["terminal_id"] = .string(terminalID) }
        if !request.skillIDs.isEmpty { body["skill_ids"] = .array(request.skillIDs.map(JSONValue.string)) }
        if !request.wireParams.isEmpty { body["params"] = .object(request.wireParams) }
        if !request.retrievalFiles.isEmpty { body["files"] = .array(request.retrievalFiles.map(\.jsonValue)) }
        return (try? WireCoding.encoder.encode(JSONValue.object(body))) ?? Data()
    }

    private func sendOverSSE(_ request: CompletionRequest) async throws(OpenWebUIError) -> CompletionReceipt {
        let encoded = Self.sseBody(request)
        let endpoint = Endpoint<JSONValue>(method: .post, path: "api/chat/completions", body: encoded, authentication: .required)
        let lines = try await client.streamLines(endpoint)
        let assistantID = request.assistantMessageID
        let chatID = request.chatID
        let hub = hub
        let client = client
        Task {
            var state = ResponseState()
            do {
                for try await event in SSEDecoder.events(lines) {
                    state.apply(event)
                    await hub.publish([ChatEvent(chatID: chatID, messageID: assistantID, kind: .response(event))], connection: nil)
                }
            } catch {
                let message = (error as? OpenWebUIError)?.message ?? OpenWebUIError.transport(.networkConnectionLost).message
                state.apply(.failed(message))
                await hub.publish([ChatEvent(chatID: chatID, messageID: assistantID, kind: .response(.failed(message)))], connection: nil)
            }
            if !state.isFinished {
                state.apply(.completed(output: nil))
                await hub.publish([ChatEvent(chatID: chatID, messageID: assistantID, kind: .response(.completed(output: nil)))], connection: nil)
            }
            guard !request.isIncognito, state.phase == .completed else { return }
            // Save the turn: the stateless endpoint persists nothing.
            if let saved = try? await client.send(Self.persist(request, responseText: state.text)) {
                let title = saved.chat.title
                await hub.publish([
                    ChatEvent(chatID: saved.chat.id, messageID: assistantID, kind: .title(title)),
                    ChatEvent(chatID: saved.chat.id, messageID: assistantID, kind: .listChanged),
                ], connection: nil)
            }
        }
        return CompletionReceipt(
            chatID: request.chatID,
            userMessageID: request.userMessageID,
            assistantMessageID: request.assistantMessageID,
            transport: .serverSentEvents
        )
    }

    static func persist(_ request: CompletionRequest, responseText: String) -> Endpoint<ChatDocument> {
        let now = Date().timeIntervalSince1970.rounded(.down)
        let user: JSONValue = .object([
            "id": .string(request.userMessageID),
            "parentId": request.parentMessageID.map(JSONValue.string) ?? .null,
            "childrenIds": .array([.string(request.assistantMessageID)]),
            "role": .string("user"),
            "content": .string(request.prompt),
            "timestamp": .number(now),
            "models": .array([.string(request.modelID)]),
            "files": .array(request.files.map(\.jsonValue)),
        ])
        let assistant: JSONValue = .object([
            "id": .string(request.assistantMessageID),
            "parentId": .string(request.userMessageID),
            "childrenIds": .array([]),
            "role": .string("assistant"),
            "content": .string(responseText),
            "model": .string(request.modelID),
            "done": .bool(true),
            "timestamp": .number(now),
        ])
        let history: JSONValue = .object([
            "currentId": .string(request.assistantMessageID),
            "messages": .object([request.userMessageID: user, request.assistantMessageID: assistant]),
        ])
        if let chatID = request.chatID {
            let body = JSONValue.object(["chat": .object(["history": history])])
            return .updateChat(id: chatID, body: (try? WireCoding.encoder.encode(body)) ?? Data())
        }
        let title = String(request.prompt.split(whereSeparator: \.isNewline).first?.prefix(60) ?? "New Chat")
        var form: [String: JSONValue] = ["chat": .object([
            "title": .string(title),
            "models": .array([.string(request.modelID)]),
            "history": history,
            "messages": .array([]),
            "timestamp": .number(now * 1000),
        ])]
        if let folderID = request.wireFolderID { form["folder_id"] = .string(folderID) }
        let body = JSONValue.object(form)
        return .createChat(body: (try? WireCoding.encoder.encode(body)) ?? Data())
    }

    private static func json(_ answers: [String: [String: ClarifyingQuestions.WireValue]]) -> JSONValue {
        .object(answers.mapValues { fields in
            .object(fields.mapValues { value in
                switch value {
                case .string(let text): .string(text)
                case .int(let number): .number(Double(number))
                }
            })
        })
    }
}

/// Fans `ChatEvent`s out to every subscriber and remembers which socket connection a pending
/// server call (ack) arrived on.
actor ChatEventHub {
    private var subscribers: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]
    private var callConnections: [Int: Int] = [:]

    func subscribe() -> AsyncStream<ChatEvent> {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    func publish(_ events: [ChatEvent], connection: Int?) {
        for event in events {
            if case .questionsRequested(_, let ackID) = event.kind, let connection {
                callConnections[ackID] = connection
            }
            for subscriber in subscribers.values { subscriber.yield(event) }
        }
    }

    func connection(forCall ackID: Int) -> Int? {
        callConnections.removeValue(forKey: ackID)
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}

/// Owns the single task that pumps socket events into the hub.
private final class Pump: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// Starts `work` unless already running. Returns whether it started.
    func start(_ work: @escaping @Sendable () async -> Void) -> Bool {
        task.withLock { current in
            guard current == nil else { return false }
            current = Task { await work() }
            return true
        }
    }

    func cancel() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
