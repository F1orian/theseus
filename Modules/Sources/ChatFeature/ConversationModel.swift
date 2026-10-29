public import ChatDomain
public import ComposerFeature
public import Foundation
public import Observation
public import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#endif

/// One Chat on screen: its Message tree, the Responses streaming into it, the draft, and the
/// send / stop / retry / answer actions. Lives in `ChatServices` while a Response streams, so
/// leaving and reopening the Chat keeps the stream (CHAT-12).
@MainActor
@Observable
public final class ConversationModel: Identifiable {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A clarifying question the Response waits on (CHAT-09).
    public struct PendingQuestion: Equatable, Sendable {
        public let messageID: String
        public let questions: ClarifyingQuestions
        /// Set for live socket questions, answered through their acknowledgement.
        let ackID: Int?
    }

    public nonisolated let id = UUID()
    /// The saved Chat's id; `nil` until the Server creates it, and always for an Incognito chat.
    public private(set) var chatID: String?
    /// An Incognito chat (server term: temporary chat, INCOG-01): never saved, never listed or
    /// cached, without Memory; every turn sends the whole conversation.
    public let isIncognito: Bool
    public private(set) var title = ""
    /// The Project (server: folder) the Chat belongs to, or a new Chat is started in.
    public private(set) var projectID: String?
    /// The Project (folder) name, for the header chip.
    public private(set) var projectName: String?
    public private(set) var loadState: LoadState = .idle
    /// The visible thread: root → current leaf.
    public internal(set) var thread: [Message] = []
    /// Live Responses by assistant Message id; stored Messages fall back to `Message.response`.
    public private(set) var responses: [String: ResponseState] = [:]
    /// The assistant Message currently streaming, if any.
    public private(set) var streamingMessageID: String?
    /// A transient problem to show above the composer (stop failed, a tool notification…).
    public var notice: String?
    /// The composer: draft, Attachments, model and Effort (HOME-02, MODEL-*, ATT-*).
    public let composer: ComposerModel

    /// The composer's text.
    public var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }

    public var selectedModelID: String? {
        get { composer.selectedModelID }
        set { if let newValue { composer.select(newValue) } }
    }

    @ObservationIgnored let services: ChatServices
    @ObservationIgnored var tree = MessageTree()
    @ObservationIgnored private var buffer: [String: ResponseState] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var sendFailures: Set<String> = []
    /// Responses sent with Code execution (the sandbox or the code interpreter), until they end (ADR 0173).
    @ObservationIgnored private var sandboxResponseIDs: Set<String> = []
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var liveQuestion: PendingQuestion?
    /// An Incognito chat's `temporary:<socket sid>` id, once its first turn was accepted.
    @ObservationIgnored private var temporaryChatID: String?
    @ObservationIgnored private let backgroundTask = BackgroundStreamTask()
    /// How often streamed text reaches the UI (coalescing, ADR 0010).
    @ObservationIgnored var coalescingInterval: Duration = .milliseconds(40)
    /// Mints client-side Message ids (tests replay recorded ones).
    @ObservationIgnored var idGenerator: @Sendable () -> String = { UUID().uuidString.lowercased() }

    init(services: ChatServices, chatID: String?, projectID: String? = nil, isIncognito: Bool = false) {
        self.services = services
        self.isIncognito = chatID == nil && isIncognito
        self.chatID = chatID
        self.projectID = chatID == nil && !isIncognito ? projectID : nil
        composer = ComposerModel(services: services.composer, followsPreferredModel: chatID == nil)
        composer.chatID = chatID
        // Uploads would be stored on the Server, which an Incognito chat must not do.
        composer.isIncognito = self.isIncognito
        if chatID == nil {
            loadState = .loaded
        }
        let session = services.session
        subscription = Task { [weak self] in
            let events = await session.events()
            for await event in events {
                self?.handle(event)
            }
        }
    }

    isolated deinit {
        subscription?.cancel()
        flushTask?.cancel()
    }

    // MARK: Derived state

    public var isStreaming: Bool { streamingMessageID != nil }
    public var isNewChat: Bool { chatID == nil && thread.isEmpty }

    public var selectedModel: Model? { services.model(id: selectedModelID) }

    public var capabilities: Capabilities { services.capabilities(for: selectedModel) }

    public func response(for message: Message) -> ResponseState {
        responses[message.id] ?? message.response
    }

    /// The question the latest Response waits on, if any.
    public var pendingQuestion: PendingQuestion? {
        if let liveQuestion { return liveQuestion }
        guard let last = thread.last, last.role == .assistant,
              let questions = response(for: last).pendingQuestions
        else { return nil }
        return PendingQuestion(messageID: last.id, questions: questions, ackID: nil)
    }

    /// The tool call the latest Response waits for the user to allow (OT-06), if any.
    public var pendingApproval: (messageID: String, call: ToolCall)? {
        guard pendingQuestion == nil, let last = thread.last, last.role == .assistant,
              let call = response(for: last).pendingApproval
        else { return nil }
        return (last.id, call)
    }

    public var canSend: Bool {
        composer.isReady
            && !isStreaming
            && services.connection.allowsSending
            && pendingQuestion == nil
            && pendingApproval == nil
            && loadState == .loaded
    }

    // MARK: Loading and resuming

    /// Loads the Chat. Responses still generating on the Server resume streaming (CHAT-12).
    public func load() async {
        guard let chatID else {
            // A new Chat in a Project shows the Project before the first send (#127).
            if let projectID, projectName == nil { await loadProjectName(projectID) }
            return
        }
        guard loadState != .loading else { return }
        if loadState == .loaded, !thread.isEmpty { return }
        loadState = .loading
        do {
            let document = try await services.client.send(.chat(id: chatID))
            apply(document.chat)
            loadState = .loaded
            await loadProjectName(document.chat.projectID)
            if let streaming = streamingMessageID {
                await confirmStillRunning(streaming)
            }
        } catch {
            loadState = .failed(error.message)
        }
    }

    private func apply(_ chat: Chat) {
        tree = chat.tree
        title = chat.title
        if composer.selectedModelID == nil {
            // The Chat's last model; one the Server dropped falls back and shows a notice (HOME-04).
            let used = chat.tree.activePath.last { $0.role == .assistant }?.modelID
            composer.adoptChatModel((used.map { [$0] } ?? []) + chat.modelIDs)
        }
        thread = tree.activePath
        for message in thread where message.role == .assistant && !message.isDone {
            var state = responses[message.id] ?? message.response
            state.resume()
            responses[message.id] = state
            streamingMessageID = message.id
            backgroundTask.begin()
        }
    }

    private func loadProjectName(_ projectID: String?) async {
        guard let projectID, capabilities.contains(.projects) else {
            self.projectID = nil
            projectName = nil
            return
        }
        self.projectID = projectID
        projectName = try? await services.client.send(.project(id: projectID)).name
    }

    /// The overlay says "not done", but is a generation actually running?
    private func confirmStillRunning(_ messageID: String) async {
        guard let chatID else { return }
        let running = (try? await services.client.send(.chatTasks(id: chatID))) ?? ["unknown"]
        guard running.isEmpty, streamingMessageID == messageID else { return }
        // Nothing runs any more: the final save may just be landing. Look once more.
        try? await Task.sleep(for: .seconds(1))
        await resync()
        if streamingMessageID == messageID {
            apply(.completed(output: nil), to: messageID)
        }
    }

    /// Re-fetches the Chat to catch up after a disconnect or a return from the background.
    public func resync() async {
        guard let chatID, let messageID = streamingMessageID,
              let document = try? await services.client.send(.chat(id: chatID)),
              let stored = document.chat.tree[messageID]
        else { return }
        if !document.chat.title.isEmpty { title = document.chat.title }
        let server = stored.response
        if stored.isDone {
            if let error = stored.error {
                apply(.failed(error), to: messageID)
            } else {
                apply(.completed(output: stored.output.isEmpty ? nil : stored.output), to: messageID)
            }
        } else if server.text.count > (buffer[messageID] ?? responses[messageID])?.text.count ?? 0 {
            var resumed = server
            resumed.resume()
            buffer[messageID] = nil
            responses[messageID] = resumed
        }
    }

    // MARK: Sending

    /// Sends the draft and its Attachments as a new user Message and streams the Response (CHAT-01).
    public func send() async {
        guard canSend, let submission = composer.submission() else { return }
        composer.reset()
        notice = nil
        services.composer.recordUse(of: submission.modelID)
        await submit(
            prompt: submission.text,
            modelID: submission.modelID,
            parentID: tree.currentID,
            existingUserID: nil,
            attachments: submission.attachments,
            files: submission.files,
            options: (submission.params, submission.features),
            toolIDs: submission.toolIDs
        )
    }

    func submit(
        prompt: String,
        modelID: String,
        parentID: String?,
        existingUserID: String?,
        attachments: [Attachment] = [],
        files: [FileReference] = [],
        options: (params: [String: JSONValue], features: [String: Bool])? = nil,
        assistantID: String? = nil,
        toolIDs: [String]? = nil
    ) async {
        let options = options ?? self.options(for: modelID)
        let toolIDs = toolIDs ?? self.toolIDs(for: modelID)
        let userID = existingUserID ?? idGenerator()
        let assistantID = assistantID ?? idGenerator()
        let now = Date()
        // Documents sent earlier stay in the retrieval context (top-level `files`).
        let contextFiles = thread.filter { $0.role == .user && $0.id != userID }.flatMap(\.attachments).compactMap(\.fileReference)
        if existingUserID == nil {
            var message = Message(id: userID, parentID: parentID, role: .user, content: prompt, createdAt: now)
            message.attachments = attachments
            try? tree.append(message)
        }
        try? tree.append(Message(id: assistantID, parentID: userID, role: .assistant, content: "", modelID: modelID, createdAt: now, isDone: false))
        // Everything above the new user Message (a retry or edit branches off mid-thread).
        let history = tree.path(to: parentID).map { message in
            CompletionRequest.HistoryEntry(
                role: message.role,
                content: message.role == .assistant ? response(for: message).text : message.content,
                images: message.role == .user ? message.attachments.compactMap(\.inlineURL) : []
            )
        }
        thread = tree.activePath
        responses[assistantID] = ResponseState()
        streamingMessageID = assistantID
        stopRequested = false
        backgroundTask.begin()

        var request = CompletionRequest(
            chatID: chatID,
            modelID: modelID,
            prompt: prompt,
            parentMessageID: parentID,
            isIncognito: isIncognito,
            userMessageID: userID,
            assistantMessageID: assistantID,
            features: options.features,
            history: history,
            personalization: services.personalization?(services.model(id: modelID))
        )
        request.files = files
        request.contextFiles = contextFiles
        request.params = options.params
        request.toolIDs = toolIDs
        request.terminalID = terminalID(for: modelID)
        // ADR 0173: a Response that may run code (the sandbox, or the code interpreter) is checked
        // against the free allowance when it ends.
        if request.terminalID != nil || options.features[FeatureToggle.codeInterpreter.rawValue] == true {
            sandboxResponseIDs.insert(assistantID)
        }
        request.skillIDs = composer.selectedSkillIDs
        request.generatesFollowUps = services.composer.followUpsEnabled
        // OT-06: pause before tools run, when the Server allows it and the user asked for it.
        if services.capabilities(for: services.model(id: modelID)).contains(.toolApprovals),
           services.composer.settings?.capabilityDefaults.askBeforeTools == true {
            request.params["tool_approval_mode"] = .string("ask")
        }
        request.variables = services.requestVariables?() ?? [:]
        request.folderID = projectID
        request.inlineImages = attachments.compactMap(\.inlineURL)
        do {
            let receipt = try await services.session.send(request)
            if isIncognito {
                temporaryChatID = receipt.chatID ?? temporaryChatID
            } else if chatID == nil, let minted = receipt.chatID {
                adopt(minted)
                services.chatListChanged()
            }
            if stopRequested { await stop() }
        } catch {
            sendFailures.insert(assistantID)
            apply(.failed(error.message), to: assistantID)
        }
    }

    /// Request options for a retry: the composer's toggles and Effort for that model.
    func options(for modelID: String) -> (params: [String: JSONValue], features: [String: Bool]) {
        let model = services.composer.model(id: modelID)
        let capabilities = services.capabilities(for: model)
        // ADR 0173: with Pro, or while free code execution runs remain today.
        let features = FeatureToggle.requestFeatures(capabilities: capabilities, canRunCode: services.composer.pro.canUseSandbox) { feature in
            modelID == composer.selectedModelID
                ? composer.isOn(feature)
                : model.map { services.composer.startsEnabled(feature, for: $0) } ?? false
        }
        let params = services.composer.effortConfiguration(for: model)?
            .params(for: services.composer.effortSelection(for: modelID), modelID: modelID) ?? [:]
        return (params, features)
    }

    /// The sandbox for a request with `modelID` (ADR 0120): the model's terminal while Code execution
    /// is on, by this Chat's switch for its own model, else by the default.
    func terminalID(for modelID: String) -> String? {
        guard let model = services.composer.model(id: modelID), let terminalID = model.terminalID,
              services.capabilities(for: model).contains(.sandbox),
              // ADR 0173: with Pro, or while free sandbox runs remain today.
              services.composer.pro.canUseSandbox
        else { return nil }
        let on = modelID == composer.selectedModelID
            ? composer.isOn(.codeInterpreter)
            : services.composer.startsEnabled(.codeInterpreter, for: model)
        return on ? terminalID : nil
    }

    /// Connectors for a retry (CONN-02): this Chat's switches, or the model preset's for another model.
    private func toolIDs(for modelID: String) -> [String] {
        let model = services.composer.model(id: modelID)
        guard services.capabilities(for: model).contains(.connectors) else { return [] }
        return modelID == composer.selectedModelID ? composer.enabledToolIDs : (model?.toolIDs ?? [])
    }

    /// Stops the streaming Response; the partial text stays (CHAT-02).
    public func stop() async {
        guard streamingMessageID != nil else { return }
        guard let chatID = chatID ?? temporaryChatID else {
            // The Server hasn't named the Chat yet; stop as soon as it does.
            stopRequested = true
            return
        }
        do {
            try await services.session.stop(chatID: chatID)
        } catch {
            notice = "Couldn't stop the response. \(error.message)"
        }
    }

    /// Retries a failed Response (CHAT-13): resends a request that never reached the Server, or
    /// regenerates a Response the Server failed (a new Branch under the same user Message).
    public func retry(_ messageID: String) async {
        guard !isStreaming, let assistant = tree[messageID], let userID = assistant.parentID, let user = tree[userID] else { return }
        let modelID = assistant.modelID ?? selectedModelID ?? services.preferredModelID
        guard let modelID else { return }
        notice = nil
        if sendFailures.remove(messageID) != nil {
            // Nothing was stored: drop the failed turn locally and send it again.
            var messages = tree.messages.values.filter { $0.id != messageID && $0.id != userID }
            messages.sort { $0.createdAt < $1.createdAt }
            tree = MessageTree(messages: messages, currentID: user.parentID)
            responses[messageID] = nil
            thread = tree.activePath
            await submit(
                prompt: user.content, modelID: modelID, parentID: user.parentID, existingUserID: nil,
                attachments: user.attachments, files: user.attachments.compactMap(\.fileReference), options: options(for: modelID)
            )
        } else {
            await submit(
                prompt: user.content, modelID: modelID, parentID: user.parentID, existingUserID: userID,
                attachments: user.attachments, files: user.attachments.compactMap(\.fileReference), options: options(for: modelID)
            )
        }
    }

    // MARK: Clarifying questions

    /// Answers the pending question, or dismisses it with `nil` (CHAT-09).
    public func answer(_ answers: [String: ClarifyingQuestions.Answer]?) {
        guard let pending = pendingQuestion, let chatID = chatID ?? temporaryChatID else { return }
        liveQuestion = nil
        var state = buffer[pending.messageID] ?? responses[pending.messageID] ?? tree[pending.messageID]?.response ?? ResponseState()
        state.continueAfterAnswer(callID: pending.ackID == nil ? pending.questions.callID : nil)
        responses[pending.messageID] = state
        streamingMessageID = pending.messageID
        let session = services.session
        Task { [weak self] in
            do {
                try await session.answer(pending.questions, with: answers, chatID: chatID, messageID: pending.messageID, ackID: pending.ackID)
            } catch {
                self?.notice = "Couldn’t send your answer. \((error as? OpenWebUIError)?.message ?? "")"
            }
        }
    }

    // MARK: Tool approvals (OT-06)

    /// Allows or denies the paused tool call; the Response continues on the Server.
    public func resolveApproval(allow: Bool) {
        guard let pending = pendingApproval, let callID = pending.call.resolvedCallID, let chatID = chatID ?? temporaryChatID else { return }
        var state = buffer[pending.messageID] ?? responses[pending.messageID] ?? tree[pending.messageID]?.response ?? ResponseState()
        state.continueAfterAnswer(callID: callID)
        responses[pending.messageID] = state
        streamingMessageID = pending.messageID
        backgroundTask.begin()
        let session = services.session
        let messageID = pending.messageID
        Task { [weak self] in
            do {
                try await session.resolveApproval(callID: callID, approve: allow, chatID: chatID, messageID: messageID)
            } catch {
                self?.notice = "Couldn’t send your choice. \((error as? OpenWebUIError)?.message ?? "")"
                await self?.resync()
            }
        }
    }

    // MARK: Events

    func handle(_ event: ChatEvent) {
        let isOurs: Bool
        if let chatID = chatID ?? temporaryChatID, event.chatID == chatID {
            isOurs = true
        } else if let messageID = event.messageID, tree[messageID] != nil {
            isOurs = true
            if chatID == nil, let minted = event.chatID, !minted.hasPrefix("temporary:") { adopt(minted) }
        } else {
            isOurs = false
        }
        guard isOurs else { return }

        switch event.kind {
        case .response(let response):
            guard let messageID = event.messageID, tree[messageID]?.role == .assistant else { return }
            apply(response, to: messageID)
        case .title(let title):
            guard !isIncognito else { return }
            self.title = title
            if let chatID { services.chatTitleChanged(chatID: chatID, title: title) }
        case .listChanged:
            if !isIncognito { services.chatListChanged() }
        case .active(true):
            if streamingMessageID == nil, chatID != nil {
                // A generation started elsewhere (another device, or an answered question).
                Task { await self.reloadForExternalActivity() }
            }
        case .questionsRequested(let questions, let ackID):
            guard let messageID = event.messageID else { return }
            liveQuestion = PendingQuestion(messageID: messageID, questions: questions, ackID: ackID)
        case .interactionDone:
            liveQuestion = nil
        case .notification(let level, let text):
            if level == "error" || level == "warning", !text.isEmpty { notice = text }
        case .active(false), .messagesInserted, .unsupportedCall, .ignored:
            break
        }
    }

    private func reloadForExternalActivity() async {
        guard let chatID, let document = try? await services.client.send(.chat(id: chatID)) else { return }
        apply(document.chat)
    }

    private func adopt(_ minted: String) {
        guard chatID == nil, !isIncognito else { return }
        chatID = minted
        composer.chatID = minted
        services.register(self, chatID: minted)
    }

    /// Folds one event into the Response, publishing at most every `coalescingInterval`.
    private func apply(_ event: ResponseEvent, to messageID: String) {
        var state = buffer[messageID] ?? responses[messageID] ?? tree[messageID]?.response ?? ResponseState()
        state.apply(event)
        buffer[messageID] = state
        if state.isFinished || state.phase == .awaitingAnswer {
            flush()
            finish(messageID, state)
        } else if flushTask == nil {
            let interval = coalescingInterval
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: interval)
                self?.flush()
            }
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        for (messageID, state) in buffer { responses[messageID] = state }
        buffer.removeAll()
    }

    private func finish(_ messageID: String, _ state: ResponseState) {
        try? tree.update(messageID) { message in
            message.output = state.output
            message.content = state.text
            message.sources = state.sources
            message.error = state.error
            message.isDone = state.isFinished
        }
        if let index = thread.firstIndex(where: { $0.id == messageID }), let updated = tree[messageID] {
            thread[index] = updated
        }
        if state.isFinished, sandboxResponseIDs.remove(messageID) != nil {
            services.sandboxResponseFinished(state)
        }
        if streamingMessageID == messageID {
            streamingMessageID = nil
            if state.phase == .completed, let chatID {
                services.responseFinished(chatID: chatID, title: title, text: state.text)
            }
            backgroundTask.end()
        }
    }

}

/// Keeps the app running briefly after it's backgrounded mid-Response, so the socket can
/// deliver the rest; afterwards the Chat catches up on reopen (CHAT-12).
@MainActor
final class BackgroundStreamTask {
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    func begin() {
        #if canImport(UIKit)
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Theseus.response") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }

    isolated deinit {
        end()
    }
}

extension Attachment {
    /// An inline photo's `data:` URL (Incognito chats), sent as an image part.
    var inlineURL: String? {
        guard kind == .image, let url, url.hasPrefix("data:") else { return nil }
        return url
    }

    /// The file reference to resend for a Server file (inline images have none).
    var fileReference: FileReference? {
        guard isServerFile else { return nil }
        return FileReference(id: id, name: name, contentType: contentType ?? (kind == .image ? "image/*" : nil), size: size)
    }
}
