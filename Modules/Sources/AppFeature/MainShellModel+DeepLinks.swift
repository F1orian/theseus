import ChatDomain
public import AppIntentsFeature
import ChatFeature
import ComposerFeature
import Entitlements
import Foundation
import OpenWebUIKit
public import Persistence
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The App Group state the app keeps for its extensions (ADR 0100): the snapshot the widgets and
/// Shortcuts read, and the Share extension's inbox.
public struct SharedStateStore: Sendable {
    public let snapshots: SharedSnapshotStore
    public let inbox: ShareInbox

    public init(container: SharedContainer) {
        snapshots = SharedSnapshotStore(container: container)
        inbox = ShareInbox(container: container)
    }

    /// Writes `snapshot` if it changed and asks the widgets to redraw.
    func publish(_ snapshot: SharedSnapshot) {
        guard snapshots.read() != snapshot else { return }
        try? snapshots.write(snapshot)
        reloadWidgets()
    }

    /// Signed out: the widgets show the signed-out state, Shortcuts find no Chats.
    func clear() {
        snapshots.clear()
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: Deep links (PLAT-01, PLAT-03, PLAT-04)

extension MainShellModel {
    /// Opens `link` in this Account: a new Chat (with a prompt, an Attachment picker, Dictation or
    /// Voice mode), an Incognito chat, a saved Chat, the Chats list, or shared content. Links that
    /// arrive before the Account's models load wait for them.
    public func open(_ link: DeepLink) {
        if link == .pro {
            presentPaywall(PaywallRequest())
            return
        }
        guard chat != nil else {
            pendingLink = link
            return
        }
        // ADR 0173: widgets, Shortcuts, the Share sheet and links are Pro. A cold launch from a
        // widget arrives before the entitlement is known, so look first.
        switch pro.status {
        case .unknown:
            Task { [weak self] in
                await self?.pro.refreshEntitlement()
                self?.open(link)
            }
        case .free:
            guard linkAwaitingPro == nil, paywallRequest == nil else { return }
            linkAwaitingPro = link
            presentPaywall(PaywallRequest(.platform))
        case .pro:
            show(link)
        }
    }

    /// Opens `link` without the Pro gate: the app's own keyboard shortcuts and menu commands
    /// (PLAT-05, free like the iPad layout), and links Pro already let through.
    func show(_ link: DeepLink) {
        guard let services = chat else {
            pendingLink = link
            return
        }
        isSettingsPresented = false
        accountSwitcher = nil
        chatAddingToProject = nil
        // A link leaves Voice mode (a Voice mode link starts a fresh one in the new Chat).
        if voice?.session != nil { voice?.endVoiceMode() }
        switch link {
        case .newChat(let options):
            startChat(services, prompt: options.prompt, sends: options.sendsImmediately, launch: options.start.map(Self.launchAction))
        case .incognitoChat(let prompt):
            // Without Incognito chats on this Server, a regular new Chat (ADR 0006).
            startChat(services, prompt: prompt, incognito: incognitoPolicy != .unavailable)
        case .chat(let id):
            navigate(to: .chat(id: id))
        case .chatsList:
            navigate(to: incognitoPolicy.savesChats ? .chatsList : .newChat())
        case .sharedItems(let id):
            openShare(id, services: services)
        case .pro:
            presentPaywall(PaywallRequest())
        }
    }

    /// The paywall over the shell closed: open the link it held if Pro is unlocked now, else drop
    /// it (and what the Share extension stored for it, so the paywall doesn't come back each time
    /// Theseus becomes active).
    func paywallDismissed() {
        guard let link = linkAwaitingPro else { return }
        linkAwaitingPro = nil
        if pro.isPro {
            show(link)
        } else if case .sharedItems(let id) = link {
            sharedState?.inbox.remove(id: id)
        }
    }

    /// Shows the paywall over the shell, once any sheet on top has gone.
    func presentPaywall(_ request: PaywallRequest) {
        let covered = isSettingsPresented || accountSwitcher != nil || chatAddingToProject != nil || chatBrowsingFiles != nil
        isSettingsPresented = false
        accountSwitcher = nil
        chatAddingToProject = nil
        chatBrowsingFiles = nil
        guard covered else {
            paywallRequest = request
            return
        }
        Task { [weak self] in
            // A sheet can only appear once the one before it has finished dismissing.
            try? await Task.sleep(for: .milliseconds(500))
            self?.paywallRequest = request
        }
    }

    /// Once the Account's models are known: the link that waited for them, or else a share the
    /// extension left in the inbox.
    func openPendingLink() {
        guard let link = pendingLink else {
            openWaitingShare()
            return
        }
        pendingLink = nil
        open(link)
    }

    /// Opens the oldest share the extension left in the inbox, if any (e.g. when it couldn't
    /// open Theseus itself). Call when the app becomes active.
    public func openWaitingShare() {
        guard chat != nil, linkAwaitingPro == nil, let inbox = sharedState?.inbox else { return }
        inbox.removeExpired()
        if let entry = inbox.pending().first {
            open(.sharedItems(entry.id))
        }
    }

    /// What the widgets and Shortcuts show for this Account (ADR 0100). Incognito chats are never
    /// in the library, and with enforced Incognito there's no history at all.
    public var sharedSnapshot: SharedSnapshot? {
        guard state == .loaded else { return nil }
        let preferred = chat?.model(id: chat?.preferredModelID)
        let capabilities = chat?.capabilities(for: preferred) ?? Capabilities(enabled: [])
        return SharedSnapshot(
            accountID: account.id,
            accountName: account.name,
            serverHost: ServerDisplay.host(account.server.url, fallback: account.server.name),
            actions: .init(
                voiceMode: capabilities.contains(.voiceMode),
                dictation: capabilities.contains(.dictation),
                photos: capabilities.contains(.imageInput),
                incognitoChat: incognitoPolicy != .unavailable
            ),
            chats: library.chats,
            savesChats: incognitoPolicy.savesChats,
            // ADR 0173: unknown counts as unlocked, so the widgets don't flash a lock at launch.
            isProUnlocked: pro.status != .free
        )
    }

    /// Writes the current `sharedSnapshot` for the extensions.
    func publishSharedSnapshot() {
        guard let sharedState, let snapshot = sharedSnapshot else { return }
        sharedState.publish(snapshot)
    }

    // MARK: Private

    private static func launchAction(_ start: DeepLink.NewChat.Start) -> ComposerLaunchAction {
        switch start {
        case .camera: .camera
        case .photos: .photos
        case .dictation: .dictation
        case .voiceMode: .voiceMode
        }
    }

    /// Shows a fresh new Chat (Incognito when asked, or when the Server enforces it) prepared with
    /// `prompt` and `launch`, and sends it right away when `sends`.
    @discardableResult
    private func startChat(
        _ services: ChatServices,
        prompt: String?,
        sends: Bool = false,
        launch: ComposerLaunchAction? = nil,
        incognito: Bool = false
    ) -> ConversationModel {
        let isIncognito = incognito || incognitoPolicy == .enforced
        navigate(to: isIncognito ? .incognitoChat : .newChat())
        let conversation = isIncognito ? services.newIncognitoConversation() : services.newConversation()
        if let prompt { conversation.composer.text = prompt }
        conversation.composer.launchAction = launch
        preparedConversation = conversation
        launchGeneration += 1
        if sends {
            Task { [weak self] in
                guard await Self.waitUntil({ conversation.composer.isReady }) else { return }
                await conversation.send()
                self?.followSentChat(conversation)
            }
        }
        return conversation
    }

    /// Fills a new Chat with a `ShareInbox` entry (PLAT-04) and removes it from the inbox.
    private func openShare(_ id: UUID, services: ChatServices) {
        // Already opened (the URL and the app becoming active can both deliver it): nothing to do.
        guard let inbox = sharedState?.inbox, let entry = inbox.entry(id: id) else { return }
        let conversation = startChat(services, prompt: entry.prompt.isEmpty ? nil : entry.prompt)
        let files: [PendingAttachment] = entry.files.compactMap { item in
            guard let data = inbox.data(for: item, in: entry) else { return nil }
            return PendingAttachment(
                data: data,
                filename: item.filename ?? "Shared file",
                contentType: item.contentType,
                source: item.kind == .image ? .photos : .files
            )
        }
        inbox.remove(id: id)
        guard !files.isEmpty else { return }
        // Attachments are checked against the selected model, so wait until there is one.
        Task {
            guard await Self.waitUntil({ conversation.composer.selectedModel != nil }) else {
                conversation.composer.notice = "The shared files couldn't be attached. Try sharing them again."
                return
            }
            conversation.composer.attach(files)
        }
    }

    /// A deep-linked Chat that was sent before its screen noticed: show it as that Chat.
    private func followSentChat(_ conversation: ConversationModel) {
        guard let chatID = conversation.chatID, preparedConversation === conversation else { return }
        navigate(to: .chat(id: chatID))
    }

    private static func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
