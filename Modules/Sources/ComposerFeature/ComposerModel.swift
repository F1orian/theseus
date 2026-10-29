public import ChatDomain
public import Entitlements
public import Foundation
public import Observation
public import OpenWebUIKit
import UniformTypeIdentifiers

/// Bytes the user picked, before they become an Attachment (ATT-01..03).
public struct PendingAttachment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case files
        case photos
        case camera
    }

    public var data: Data
    public var filename: String
    /// The MIME type, if known; otherwise derived from the file name.
    public var contentType: String?
    public var source: Source

    public init(data: Data, filename: String, contentType: String? = nil, source: Source) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
        self.source = source
    }

    /// Photos and camera captures are images; files are images when their type says so.
    var kind: Attachment.Kind {
        if source != .files { return .image }
        let type = contentType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        return type?.conforms(to: .image) == true ? .image : .document
    }

    var mimeType: String {
        if let contentType { return contentType }
        return UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// One Attachment in the composer, with its upload state (ATT-04: shown on the chip).
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case uploading
        /// A document the server is extracting text from.
        case processing
        case ready
        case failed(String)
    }

    public let id: UUID
    public var name: String
    public var kind: Attachment.Kind
    public var contentType: String?
    public var size: Int?
    public var phase: Phase
    public var file: FileReference?
    public var thumbnail: DecodedImage?
    /// A photo kept on the device as a `data:` URL instead of uploading (Incognito chats).
    public var inlineURL: String?

    public var isBusy: Bool {
        switch phase {
        case .preparing, .uploading, .processing: true
        case .ready, .failed: false
        }
    }

    /// The Attachment as the sent Message shows it.
    var messageAttachment: Attachment? {
        if let inlineURL {
            return Attachment(id: id.uuidString, name: name, kind: kind, contentType: contentType, size: size, url: inlineURL)
        }
        guard let file else { return nil }
        return Attachment(id: file.id, name: file.name, kind: kind, contentType: file.contentType, size: file.size)
    }

    var badge: String {
        Attachment(id: id.uuidString, name: name, kind: kind, contentType: contentType).typeBadge
    }
}

/// What a send hands to the conversation: the prompt, its Attachments and the request options.
public struct ComposerSubmission: Sendable, Equatable {
    public var text: String
    public var modelID: String
    public var files: [FileReference]
    public var attachments: [Attachment]
    public var params: [String: JSONValue]
    public var features: [String: Bool]
    /// Connectors enabled for this Message (`tool_ids`, CONN-02).
    public var toolIDs: [String] = []
}

/// The composer of one conversation (HOME-02): the draft, Attachments, the selected model and
/// its Effort, and the Add to Chat toggles. Views read it; `ConversationModel` sends what
/// `submission()` returns and then calls `reset()`.
@MainActor
@Observable
public final class ComposerModel {
    public var text = ""
    public private(set) var attachments: [ComposerAttachment] = []
    /// The model this composer sends to. Until one is chosen (or adopted from the Chat), a new
    /// Chat's composer follows the Account's preferred model as settings load (MODEL-04).
    public var selectedModelID: String? {
        explicitModelID ?? (followsPreferredModel ? services.preferredModelID : nil)
    }
    /// The Chat's model when the Server no longer offers it (MODEL-01 greyed row, HOME-04 notice).
    public private(set) var unavailableModelID: String?
    /// A transient problem to show on the composer (a rejected file, a placeholder action…).
    public var notice: String?
    /// Opened as soon as the composer is on screen (a widget's camera or mic, PLAT-01/03).
    public var launchAction: ComposerLaunchAction?
    public let services: ComposerServices

    private var explicitModelID: String?
    private let followsPreferredModel: Bool
    @ObservationIgnored private var featureOverrides: [FeatureToggle: Bool] = [:]
    /// Connectors the user switched on or off in this Chat (CONN-02), over the model's presets.
    private var toolOverrides: [String: Bool] = [:]
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    private var featureRevision = 0

    /// - Parameters:
    ///   - selectedModelID: A fixed model; `nil` with `followsPreferredModel` tracks the preferred one.
    ///   - followsPreferredModel: For new Chats: use the Account's preferred model until the user picks.
    public init(services: ComposerServices, selectedModelID: String? = nil, followsPreferredModel: Bool = false) {
        self.services = services
        explicitModelID = selectedModelID
        self.followsPreferredModel = followsPreferredModel
    }

    isolated deinit {
        for task in uploads.values { task.cancel() }
    }

    // MARK: Model and Effort

    public var selectedModel: Model? { services.model(id: selectedModelID) }

    public var capabilities: Capabilities { services.capabilities(for: selectedModel) }

    public func select(_ modelID: String) {
        explicitModelID = modelID
        unavailableModelID = nil
    }

    /// Selects the Chat's model, or falls back to an available one and remembers the missing id.
    public func adoptChatModel(_ modelIDs: [String]) {
        if let available = modelIDs.first(where: { services.model(id: $0) != nil }) {
            explicitModelID = available
            unavailableModelID = nil
        } else {
            unavailableModelID = modelIDs.first
            explicitModelID = services.preferredModelID
        }
    }

    public var effort: EffortConfiguration? { services.effortConfiguration(for: selectedModel) }

    public var effortSelection: EffortSelection {
        guard let selectedModelID else { return EffortSelection() }
        return services.effortSelection(for: selectedModelID)
    }

    public func setEffort(_ optionID: String, for key: String) {
        guard let selectedModelID else { return }
        services.setEffort(optionID, for: key, modelID: selectedModelID)
    }

    /// Bumped to move the keyboard focus into the text field (`ComposerView` watches it).
    public private(set) var focusRequest = 0

    /// Puts `prompt` in the draft and focuses the field ("Ask about it ›" on the home): it
    /// replaces an empty draft and goes after one the user already typed, so nothing is lost.
    public func prefill(_ prompt: String) {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            text = prompt
        } else if !draft.hasSuffix(prompt) {
            text = draft + " " + prompt
        }
        focusRequest += 1
    }

    /// The model chip: the model's name, then its Effort ("Sonnet 5.5", "Low").
    public var chipTitle: String { selectedModel?.name ?? "Choose a model" }

    public var chipDetail: String? { effort?.chipLabel(for: effortSelection) }

    /// "Chat with …" on a new Chat, "Reply to …" in one.
    public func placeholder(isNewChat: Bool) -> String {
        let name = selectedModel?.name ?? "the model"
        return isNewChat ? "Chat with \(name)" : "Reply to \(name)"
    }

    // MARK: Add to Chat toggles

    /// The switches the selected model and the Server allow (web search, image creation, code
    /// execution; CONN-01, CONN-08).
    public var availableToggles: [FeatureToggle] {
        [.webSearch, .imageGeneration, .codeInterpreter].filter { $0.isAvailable(in: capabilities) }
    }

    /// Code execution runs in the Server's sandbox for this model (ADR 0120): its switch reads
    /// "Code execution and file creation".
    public var codeExecutionUsesSandbox: Bool { capabilities.contains(.sandbox) }

    /// The saved Chat this composer belongs to (`nil` for a new or Incognito chat): the sandbox
    /// session uploads go to (OT-05).
    public var chatID: String?

    /// The terminal the next Attachments go to, when the sandbox takes uploads (OT-05).
    public var sandboxUploadTerminal: TerminalServer? {
        guard !isIncognito, terminalID != nil else { return nil }
        return services.filesystemUploadTerminal(for: selectedModel)
    }

    /// The terminal the next Message sends as `terminal_id`: the model's, while Code execution is on
    /// and the sandbox is unlocked (Pro, or free runs left today; ADR 0173).
    public var terminalID: String? {
        guard codeExecutionUsesSandbox, isOn(.codeInterpreter), services.pro.canUseSandbox else { return nil }
        return selectedModel?.terminalID
    }

    // MARK: Theseus Pro (ADR 0173)

    /// The paywall the composer shows (the `/` menu's Skills, Voice mode, the sandbox notice).
    public var paywallRequest: PaywallRequest?

    /// Whether this model has Code execution at all: in the Server's sandbox, or through its
    /// Jupyter code interpreter (ADR 0092, 0120). Both count against the same free runs (ADR 0173).
    public var hasCodeExecution: Bool { FeatureToggle.codeInterpreter.isAvailable(in: capabilities) }

    /// Whether the free code execution runs are used up while Code execution is on for this model:
    /// the composer says so, and requests go without the sandbox or the code interpreter until
    /// tomorrow.
    public var sandboxAllowanceExhausted: Bool {
        hasCodeExecution && isOn(.codeInterpreter) && !services.pro.canUseSandbox
    }

    /// The free tier's line for Add to Chat ("4 of 5 free runs left today"), or `nil` with Pro or
    /// without Code execution.
    public var sandboxAllowanceSummary: String? {
        guard hasCodeExecution, !services.pro.isPro else { return nil }
        return services.pro.allowance.summary
    }

    /// The "used up" notice was dismissed in this composer. Every send brings it back while the
    /// runs stay used up, since that message went without Code execution (`reset()`).
    public var isSandboxNoticeDismissed = false

    /// Starts Voice mode through `start`, or asks for Pro (Dictation stays free).
    public func startVoiceMode(_ start: () -> Void) {
        if services.pro.allows(.voiceMode) {
            start()
        } else {
            paywallRequest = PaywallRequest(.voiceMode)
        }
    }

    public func isOn(_ feature: FeatureToggle) -> Bool {
        _ = featureRevision
        guard let model = selectedModel, feature.isAvailable(in: capabilities) else { return false }
        return featureOverrides[feature] ?? services.startsEnabled(feature, for: model)
    }

    public func set(_ feature: FeatureToggle, on: Bool) {
        featureOverrides[feature] = on
        featureRevision += 1
    }

    // MARK: Connectors (CONN-02)

    /// Whether the Connector `toolID` is on for this Chat: the user's choice, else the model
    /// preset's (`info.meta.toolIds`). In the free tier only the preset's can be on (ADR 0173).
    public func isToolOn(_ toolID: String) -> Bool {
        let on = toolOverrides[toolID] ?? isPresetTool(toolID)
        return on && !toolNeedsPro(toolID)
    }

    /// Whether turning `toolID` on needs Theseus Pro (ADR 0173): in the free tier, every Connector
    /// except the ones the selected model comes with.
    public func toolNeedsPro(_ toolID: String) -> Bool {
        !services.pro.allows(.connectors) && !isPresetTool(toolID)
    }

    /// Switches a Connector for this Chat. Turning one on that needs Pro asks for it instead
    /// (`paywallRequest`); turning one off never does.
    public func setTool(_ toolID: String, on: Bool) {
        if on, toolNeedsPro(toolID) {
            paywallRequest = PaywallRequest(.connectors)
            return
        }
        toolOverrides[toolID] = on
    }

    private func isPresetTool(_ toolID: String) -> Bool {
        selectedModel?.toolIDs.contains(toolID) ?? false
    }

    /// The Connectors the next Message sends as `tool_ids`, sorted for a stable request.
    public var enabledToolIDs: [String] {
        let preset = Set(selectedModel?.toolIDs ?? [])
        let ids = preset.union(toolOverrides.keys).filter(isToolOn)
        return ids.sorted()
    }

    // MARK: Skills (#140)

    /// Skills picked for this Chat; every Message sends them as `skill_ids` until removed.
    public private(set) var selectedSkillIDs: [String] = []

    /// The picked Skills, in the order they were picked (unknown ids are skipped).
    public var selectedSkills: [Skill] {
        selectedSkillIDs.compactMap { id in services.skills.first { $0.id == id } }
    }

    public func isSkillSelected(_ id: String) -> Bool {
        selectedSkillIDs.contains(id)
    }

    public func setSkill(_ id: String, selected: Bool) {
        // ADR 0173: picking a Skill is Pro; removing one never is.
        if selected, !services.pro.allows(.skills) {
            paywallRequest = PaywallRequest(.skills)
            return
        }
        selectedSkillIDs.removeAll { $0 == id }
        if selected { selectedSkillIDs.append(id) }
    }

    // MARK: Attachments

    /// The composer of an Incognito chat (INCOG-01): nothing may be stored on the Server, so photos
    /// travel inline as `data:` URLs, files can't be attached, and there's no Project to add to.
    public var isIncognito = false

    public var canAttachFiles: Bool { !isIncognito && capabilities.contains(.fileUpload) }
    /// Whether "Add to project" is offered (never for an Incognito chat).
    public var canAddToProject: Bool { !isIncognito && capabilities.contains(.projects) }
    public var canAttachPhotos: Bool { capabilities.contains(.imageInput) }

    /// How many more Attachments fit (`config.file.max_count`), `nil` when unlimited.
    public var remainingSlots: Int? {
        services.fileLimits.maxCount.map { max(0, $0 - attachments.count) }
    }

    /// Validates and starts uploading `items`. Rejections become the composer's `notice`.
    public func attach(_ items: [PendingAttachment]) {
        for item in items {
            if let remaining = remainingSlots, remaining == 0 {
                notice = "You can attach up to \(services.fileLimits.maxCount ?? 0) files to a message."
                return
            }
            let kind = item.kind
            if kind == .image, !canAttachPhotos {
                notice = "\(selectedModel?.name ?? "This model") can't see images."
                continue
            }
            if kind == .document, isIncognito {
                notice = "Incognito chats can't take files, because they'd be stored on the server."
                continue
            }
            if kind == .document, !canAttachFiles {
                notice = "\(selectedModel?.name ?? "This model") can't read files."
                continue
            }
            if let limit = services.fileLimits.maxSizeMB, Double(item.data.count) > limit * 1_000_000 {
                notice = "\(item.filename) is larger than \(Self.format(megabytes: limit)), the limit on this Server."
                continue
            }
            let attachment = ComposerAttachment(
                id: UUID(),
                name: item.filename,
                kind: kind,
                contentType: item.mimeType,
                size: item.data.count,
                phase: .preparing,
                file: nil,
                thumbnail: nil
            )
            attachments.append(attachment)
            uploads[attachment.id] = Task { [weak self] in
                await self?.upload(item, id: attachment.id)
            }
        }
    }

    /// Removes an Attachment; an upload already on the Server is deleted there too.
    public func remove(_ id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        // Sandbox files (OT-05) stay in the sandbox; the Server's file store has nothing to delete.
        if let file = removed.file, file.sandbox == nil {
            let fileID = file.id
            let client = services.client
            Task { _ = try? await client.send(.deleteFile(id: fileID)) }
        }
    }

    private func upload(_ item: PendingAttachment, id: UUID) async {
        let limits = services.fileLimits
        var upload = FileUpload(data: item.data, filename: item.filename, contentType: item.mimeType)
        let kind = item.kind
        if kind == .image {
            let data = item.data
            let filename = item.filename
            let prepared = await Task.detached(priority: .userInitiated) {
                ImageProcessing.prepare(data, filename: filename, limits: limits)
            }.value
            guard let prepared else {
                update(id) { $0.phase = .failed("This image couldn't be read.") }
                return
            }
            upload = prepared.upload
            let bytes = prepared.upload.data
            let thumbnail = await Task.detached(priority: .userInitiated) {
                ImageProcessing.thumbnail(bytes, maxPixelSize: 480)
            }.value
            update(id) {
                $0.name = prepared.upload.filename
                $0.contentType = prepared.upload.contentType
                $0.size = prepared.upload.data.count
                $0.thumbnail = thumbnail
            }
            if isIncognito {
                // Incognito: nothing reaches the Server's file list; the photo rides in the request.
                guard !Task.isCancelled else { return }
                services.images.store(bytes, for: id.uuidString)
                let url = "data:\(prepared.upload.contentType);base64,\(bytes.base64EncodedString())"
                update(id) {
                    $0.inlineURL = url
                    $0.phase = .ready
                }
                return
            }
        }
        guard !Task.isCancelled else { return }
        update(id) { $0.phase = .uploading }
        if let terminal = sandboxUploadTerminal {
            await uploadToSandbox(upload, terminal: terminal, attachment: id)
            return
        }
        let file: UploadedFile
        do {
            file = try await services.client.send(.uploadFile(
                filename: upload.filename,
                contentType: upload.contentType,
                data: upload.data,
                process: kind == .document
            ))
        } catch {
            update(id) { $0.phase = .failed(error.message) }
            return
        }
        guard !Task.isCancelled, attachments.contains(where: { $0.id == id }) else {
            let client = services.client
            Task { _ = try? await client.send(.deleteFile(id: file.id)) }
            return
        }
        var reference = file.reference
        if reference.contentType == nil { reference.contentType = upload.contentType }
        if kind == .image, let thumbnail = attachments.first(where: { $0.id == id })?.thumbnail {
            services.images.store(thumbnail: thumbnail, for: file.id)
        }
        update(id) { $0.file = reference }
        guard kind == .document else {
            update(id) { $0.phase = .ready }
            return
        }
        update(id) { $0.phase = .processing }
        await waitForProcessing(file.id, attachment: id)
    }

    /// OT-05: the file goes into the Chat's sandbox (its working directory), and the Message refers
    /// to it by path (`type: "filesystem"`); nothing reaches the Server's file store.
    private func uploadToSandbox(_ upload: FileUpload, terminal: TerminalServer, attachment id: UUID) async {
        let chatID = chatID
        do {
            let location = try await services.client.send(.sandboxLocation(terminalID: terminal.id, chatID: chatID))
            let stored = try await services.client.send(.sandboxUpload(
                terminalID: terminal.id, chatID: chatID, directory: location.cwd,
                filename: upload.filename, contentType: upload.contentType, data: upload.data
            ))
            guard !Task.isCancelled, attachments.contains(where: { $0.id == id }) else { return }
            let reference = FileReference(
                id: stored.path,
                name: (stored.path as NSString).lastPathComponent,
                contentType: upload.contentType,
                size: stored.size ?? upload.data.count,
                sandbox: SandboxPlacement(terminalID: terminal.id, path: stored.path, sessionID: chatID)
            )
            update(id) {
                $0.file = reference
                $0.phase = .ready
            }
        } catch {
            update(id) { $0.phase = .failed(error.message) }
        }
    }

    private func waitForProcessing(_ fileID: String, attachment id: UUID) async {
        let deadline = ContinuousClock.now + services.processingTimeout
        while !Task.isCancelled {
            let status = try? await services.client.send(.fileProcessingStatus(id: fileID))
            switch status {
            case .completed?:
                update(id) { $0.phase = .ready }
                return
            case .failed(let reason)?:
                update(id) { $0.phase = .failed(reason ?? "The Server couldn't read this file.") }
                return
            case .pending?, nil:
                if ContinuousClock.now >= deadline {
                    update(id) { $0.phase = .failed("The Server is taking too long to read this file.") }
                    return
                }
                try? await Task.sleep(for: services.processingPollInterval)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout ComposerAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
    }

    // MARK: Sending

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    public var isUploading: Bool { attachments.contains(where: \.isBusy) }

    /// Why the content can't go to the selected model, if it can't.
    public var blockingIssue: String? {
        let name = selectedModel?.name ?? "This model"
        if attachments.contains(where: { $0.kind == .image }), !canAttachPhotos {
            return "\(name) can't see images. Remove them or choose another model."
        }
        if attachments.contains(where: { $0.kind == .document }), !canAttachFiles {
            return "\(name) can't read files. Remove them or choose another model."
        }
        if attachments.contains(where: { if case .failed = $0.phase { true } else { false } }) {
            return "Remove the attachments that failed to upload."
        }
        return nil
    }

    /// Content, a model, every upload finished and nothing blocking.
    public var isReady: Bool {
        hasContent && !isUploading && blockingIssue == nil && selectedModel != nil
    }

    /// The send payload, or `nil` when not ready.
    public func submission() -> ComposerSubmission? {
        guard isReady, let modelID = selectedModelID else { return nil }
        let files = attachments.compactMap(\.file)
        let features = FeatureToggle.requestFeatures(capabilities: capabilities, canRunCode: services.pro.canUseSandbox, isOn: isOn)
        return ComposerSubmission(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: modelID,
            files: files,
            attachments: attachments.compactMap(\.messageAttachment),
            params: effort?.params(for: effortSelection, modelID: modelID) ?? [:],
            features: features,
            toolIDs: capabilities.contains(.connectors) ? enabledToolIDs : []
        )
    }

    /// Clears the draft after a send (uploaded files now belong to the Message). A dismissed
    /// "used up" notice comes back: the message just sent went without Code execution.
    public func reset() {
        text = ""
        uploads.removeAll()
        attachments.removeAll()
        notice = nil
        isSandboxNoticeDismissed = false
    }

    static func format(megabytes: Double) -> String {
        megabytes.rounded() == megabytes ? "\(Int(megabytes)) MB" : String(format: "%.1f MB", megabytes)
    }
}
