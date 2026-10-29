public import ChatDomain
public import ComposerFeature
import Foundation
public import Observation
public import OpenWebUIKit
#if canImport(Network)
import Network
#endif

/// Whether Responses can be sent right now (CHAT-13).
public enum ConnectionStatus: Sendable, Equatable {
    case online
    /// The socket is (re)connecting; sending still works (it waits or falls back to SSE).
    case reconnecting
    /// The device has no network.
    case offline
    /// The network is up but the Server doesn't answer `/health`.
    case serverUnreachable
    /// The Server rejected the Session token for streaming.
    case unauthorized

    /// Sending is disabled when the Server can't possibly be reached.
    public var allowsSending: Bool {
        switch self {
        case .online, .reconnecting: true
        case .offline, .serverUnreachable, .unauthorized: false
        }
    }
}

/// Everything the Chat screens share for one signed-in Account: the API client, the streaming
/// session, the Account's models and Capabilities, connectivity, and the live Conversations
/// (so a Response keeps streaming while the user is elsewhere, CHAT-12).
///
/// Create one per Account session, call `start()`, and inject it with `.environment(services)`.
@MainActor
@Observable
public final class ChatServices {
    public let client: OpenWebUIClient
    public let session: CompletionSession
    public private(set) var models: [Model]
    public private(set) var defaultModelID: String?
    public private(set) var connection: ConnectionStatus = .online
    /// The composer's shared state: model choice, Effort, Attachments, greeting (HOME/MODEL/ATT).
    public let composer: ComposerServices
    /// Called when the Chat list changed (new Chat, new title), e.g. to refresh a sidebar.
    @ObservationIgnored public var onChatListChanged: (@MainActor () -> Void)?
    /// Called with `(chatID, title)` when a Chat gets its generated title (CHAT-11).
    @ObservationIgnored public var onChatTitleChanged: (@MainActor (String, String) -> Void)?
    /// Called with `(chatID, chat title, Response text)` when a Response completes, e.g. to post
    /// a "Response ready" notification while backgrounded (SET-06).
    @ObservationIgnored public var onResponseFinished: (@MainActor (String, String, String) -> Void)?
    /// Profile Instructions, Memory and the user's name for a request with `model` (PERS-01..03).
    /// The app provides it from the user settings; `nil` sends none.
    @ObservationIgnored public var personalization: (@MainActor (Model?) -> ChatPersonalization?)?
    /// Prompt variables the app adds to every request, e.g. `{{USER_LOCATION}}` once the user
    /// allowed sharing their location (CONN-07). `nil` adds none.
    @ObservationIgnored public var requestVariables: (@MainActor () -> [String: String])?
    /// Called when a Response that was sent with Code execution ends (the sandbox attached, or
    /// `features.code_interpreter` on; ADR 0173), so the app can count it against the free
    /// allowance when it really ran code.
    @ObservationIgnored public var onSandboxResponseFinished: (@MainActor (ResponseState) -> Void)?

    @ObservationIgnored private var resolveCapabilities: @MainActor (Model?) -> Capabilities
    @ObservationIgnored private var conversations: [String: ConversationModel] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var networkUp = true
    @ObservationIgnored private var socketState: SocketIOClient.State = .idle
    @ObservationIgnored private var healthCheck: Task<Void, Never>?
    #if canImport(Network)
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    #endif

    public init(
        client: OpenWebUIClient,
        session: CompletionSession,
        models: [Model],
        defaultModelID: String?,
        composerStore: ComposerLocalStore? = nil,
        capabilities: @escaping @MainActor (Model?) -> Capabilities
    ) {
        self.client = client
        self.session = session
        self.models = models
        self.defaultModelID = defaultModelID
        self.resolveCapabilities = capabilities
        composer = ComposerServices(
            client: client,
            models: models,
            defaultModelIDs: defaultModelID.map { [$0] } ?? [],
            store: composerStore,
            capabilities: capabilities
        )
    }

    /// Connects the stream and starts watching connectivity. Idempotent.
    public func start() {
        guard tasks.isEmpty else { return }
        let session = session
        tasks.append(Task { [weak self] in
            await session.start()
            guard let states = await session.connectionStates() else { return }
            for await state in states {
                self?.socketStateChanged(state)
            }
        })
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "theseus.chat.network"))
        pathMonitor = monitor
        #endif
    }

    public func stop() async {
        for task in tasks { task.cancel() }
        tasks = []
        cancelHealthCheck()
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
        await session.shutdown()
    }

    /// Refreshes models and Capabilities (e.g. after the shell reloaded them).
    public func update(models: [Model], defaultModelID: String?, capabilities: @escaping @MainActor (Model?) -> Capabilities) {
        self.models = models
        self.defaultModelID = defaultModelID
        resolveCapabilities = capabilities
        composer.update(models: models, defaultModelIDs: defaultModelID.map { [$0] } ?? [], capabilities: capabilities)
    }

    public func capabilities(for model: Model?) -> Capabilities {
        resolveCapabilities(model)
    }

    public func model(id: String?) -> Model? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// The model new Chats start with (MODEL-04): the Settings default, else the last model
    /// used, else the web client's and then the admin's default, else the first model.
    public var preferredModelID: String? {
        composer.preferredModelID
    }

    // MARK: Conversations

    /// The live Conversation for `chatID` (reused while it streams), or a new one.
    public func conversation(chatID: String) -> ConversationModel {
        if let live = conversations[chatID] { return live }
        let model = ConversationModel(services: self, chatID: chatID)
        conversations[chatID] = model
        return model
    }

    /// The live Conversation for `chatID`, if one exists (doesn't create one).
    public func liveConversation(chatID: String) -> ConversationModel? {
        conversations[chatID]
    }

    /// A fresh, unsaved Conversation (the new-chat screen), optionally inside a Project: its
    /// first send creates the Chat in that Project (server: folder).
    public func newConversation(projectID: String? = nil) -> ConversationModel {
        ConversationModel(services: self, chatID: nil, projectID: projectID)
    }

    /// A fresh Incognito chat (INCOG-01). It's never registered here: once its screen goes away,
    /// so does the Chat.
    public func newIncognitoConversation() -> ConversationModel {
        ConversationModel(services: self, chatID: nil, isIncognito: true)
    }

    /// Called by a Conversation once the Server has minted its id.
    func register(_ conversation: ConversationModel, chatID: String) {
        conversations[chatID] = conversation
    }

    /// Drops idle Conversations nobody shows; streaming ones stay alive.
    func release(chatID: String) {
        if let model = conversations[chatID], !model.isStreaming {
            conversations[chatID] = nil
        }
    }

    func chatListChanged() {
        onChatListChanged?()
    }

    func chatTitleChanged(chatID: String, title: String) {
        onChatTitleChanged?(chatID, title)
    }

    func responseFinished(chatID: String, title: String, text: String) {
        onResponseFinished?(chatID, title, text)
    }

    func sandboxResponseFinished(_ state: ResponseState) {
        onSandboxResponseFinished?(state)
    }

    /// The app came back to the foreground: reconnect now and catch up on missed events.
    public func resume() {
        let session = session
        Task { await session.reconnect() }
        for conversation in conversations.values where conversation.isStreaming {
            Task { await conversation.resync() }
        }
    }

    // MARK: Connectivity

    private func networkChanged(_ up: Bool) {
        guard up != networkUp else { return }
        networkUp = up
        if up {
            let session = session
            Task { await session.reconnect() }
        }
        recomputeConnection()
    }

    private func socketStateChanged(_ state: SocketIOClient.State) {
        let wasJoined = socketState.sessionID != nil
        socketState = state
        if state.sessionID != nil, !wasJoined {
            // Back online after a drop: Responses may have moved on while we were away.
            for conversation in conversations.values where conversation.isStreaming {
                Task { await conversation.resync() }
            }
        }
        recomputeConnection()
    }

    private func recomputeConnection() {
        guard networkUp else {
            cancelHealthCheck()
            connection = .offline
            return
        }
        switch socketState {
        case .joined, .idle:
            cancelHealthCheck()
            connection = .online
        case .unauthorized:
            connection = .unauthorized
        case .connecting, .disconnected:
            if connection == .online || connection == .offline { connection = .reconnecting }
            scheduleHealthCheck()
        }
    }

    /// While the socket is down, ask `/health` whether the Server is there at all.
    private func scheduleHealthCheck() {
        guard healthCheck == nil else { return }
        let client = client
        healthCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                let healthy = (try? await client.send(.health)) ?? false
                guard let self, !Task.isCancelled else { return }
                if self.socketState.sessionID != nil { break }
                self.connection = healthy ? .reconnecting : .serverUnreachable
                try? await Task.sleep(for: .seconds(healthy ? 10 : 5))
            }
            self?.healthCheck = nil
        }
    }

    private func cancelHealthCheck() {
        healthCheck?.cancel()
        healthCheck = nil
    }

    /// For tests and previews: forces a connection state.
    func setConnectionForTesting(_ status: ConnectionStatus) {
        connection = status
    }
}
