public import ArtifactsFeature
public import Auth
import ChatDomain
import AppIntentsFeature
public import ChatFeature
import ComposerFeature
public import ConnectorsFeature
public import Entitlements
import Foundation
public import LibraryFeature
public import MessageActionsFeature
public import Observation
public import OnboardingFeature
public import OpenWebUIKit
import Persistence
public import PersonalizationFeature
public import ProjectsFeature
public import SandboxFeature
public import SettingsFeature
public import VoiceFeature

/// The signed-in shell: the navigation drawer (CHATS-01) over the current `AppRoute`. It loads the
/// Account's models (with their resolved Capabilities) and owns the Account's `ChatLibrary`.
@MainActor
@Observable
public final class MainShellModel {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var account: Account
    public private(set) var models: [Model] = []
    public private(set) var defaultModelIDs: [String] = []
    public private(set) var state: LoadState = .idle
    /// The Account's Chats (drawer, Chats list, star / rename / delete), mirror-cache backed.
    public let library: ChatLibrary
    /// The Account's Projects (PROJ-*), available when the `projects` Capability resolves.
    public let projects: ProjectLibrary
    /// The Account's Connectors (CONN-02..05), shared by Settings and Add to Chat.
    public let connectors: ConnectorDirectory
    /// The Account's Styles (PERS-05): Add to Chat › Choose style and the system prompt.
    public let styles: StyleLibrary
    /// Whether the device's location goes with requests as `{{USER_LOCATION}}` (CONN-07).
    public let location: LocationSharing
    /// The Chat whose "Add to project" picker is showing (PROJ-06).
    var chatAddingToProject: ChatSummary?
    /// The Chat whose sandbox files are showing (OT-04).
    var chatBrowsingFiles: ChatSummary?
    /// Whether this Account may, or must, use Incognito chats (INCOG-02). Known after `refresh()`.
    public private(set) var incognitoPolicy: IncognitoPolicy = .unavailable
    /// Bumped whenever an Incognito chat starts, so a new one replaces the current one even
    /// though the route stays `.incognitoChat` (e.g. "New chat" while every Chat is Incognito).
    public private(set) var incognitoGeneration = 0
    /// The screen behind the drawer. Change it with `navigate(to:)`.
    public private(set) var route: AppRoute = .newChat() {
        didSet {
            guard !isPromoting else { return }
            // Leaving a promoted screen always builds a new one, even for the same route
            // (New chat from a just-created Chat).
            if isScreenPromoted { screenGeneration += 1 }
            isScreenPromoted = false
            screenRoute = route
        }
    }
    /// The route the current screen was built for. It equals `route`, except after a new Chat
    /// got its id (`promoteNewChat(to:)`): the screen stays the same view, so the first Message's
    /// animation and the stream carry on instead of the screen being rebuilt (ADR 0130).
    public private(set) var screenRoute: AppRoute = .newChat()
    /// Bumped when the screen after a promoted one would otherwise keep its identity.
    public private(set) var screenGeneration = 0
    @ObservationIgnored private var isPromoting = false
    @ObservationIgnored private var isScreenPromoted = false
    /// A new Chat a deep link prepared (prompt, Attachments, launch action; PLAT-01/03/04). The
    /// next new-chat screen shows it; any navigation drops it.
    public internal(set) var preparedConversation: ConversationModel?
    /// Bumped with each prepared Chat, so it replaces the new-chat screen already showing.
    public internal(set) var launchGeneration = 0
    /// A deep link that arrived before the Account's models loaded; opened after `refresh()`.
    @ObservationIgnored var pendingLink: DeepLink?
    /// Where the widgets' and Shortcuts' view of this Account goes (ADR 0100); set by `AppModel`.
    @ObservationIgnored public internal(set) var sharedState: SharedStateStore?
    public var isDrawerOpen = false
    public var isSettingsPresented = false
    /// On regular width the drawer is a persistent sidebar (PLAT-05); the header button hides it.
    public var isSidebarHidden = false
    /// ⌘K asked the Chats list to open with its search field active (PLAT-05).
    public internal(set) var isChatsSearchRequested = false
    /// The one-time welcome sheet (AUTH-08), while it shows.
    public var welcome: WelcomeSummary?
    @ObservationIgnored var welcomeRecord = WelcomeRecord()
    /// Chat screens' shared services (streaming, models, Capabilities); set after the first load.
    public private(set) var chat: ChatServices?
    /// The Message actions under Responses (MSG-*); set together with `chat`.
    public private(set) var messageActions: MessageActions?
    /// Dictation, Voice mode and Voice settings (VOICE-*); set together with `chat`.
    public private(set) var voice: Voice?
    /// The Server's Open Terminal sandbox: run cards, created files, the file browser (epic #139);
    /// set together with `chat`.
    public private(set) var sandbox: Sandbox?
    /// Whether Responses show Artifacts (ART-*): the Account's Capabilities default (SET-05).
    public private(set) var showsArtifacts = true
    /// The Account's Artifacts across Chats (ART-04), behind Drawer › Artifacts.
    public let artifactLibrary: ArtifactLibrary
    /// This Account's on-device preferences (appearance, haptics, notifications; SET-02/03/06).
    public let preferences: AccountPreferencesStore
    /// Posts "Response ready" notifications while Theseus is in the background (SET-06). The Chat
    /// screen calls `responseNotifier.responseFinished(…)` when a stream completes.
    public let responseNotifier: ResponseNotifier
    /// Whether the app is in the foreground; `MainShellView` keeps it current.
    public var isSceneActive: Bool {
        get { sceneActivity.isActive }
        set { sceneActivity.isActive = newValue }
    }
    @ObservationIgnored private let sceneActivity = SceneActivity()
    /// The Settings sheet's model while it is presented (SET-01).
    public private(set) var settings: SettingsModel?
    /// Theseus Pro, shared by every Account (ADR 0173).
    public let pro: ProStore
    /// The paywall over the shell: a widget, Shortcut, Share or link in the free tier.
    public var paywallRequest: PaywallRequest?
    /// The deep link that waits for Pro; it opens if the paywall unlocks it.
    @ObservationIgnored var linkAwaitingPro: DeepLink?
    /// Forgets the Account on this device (SET-10); set by `AppModel`.
    @ObservationIgnored var onRemoveAccount: (() async -> Void)?
    /// Persists a change to the Account's details (its name after a Profile rename); set by `AppModel`.
    @ObservationIgnored var onAccountChanged: ((Account) -> Void)?

    @ObservationIgnored private var features = ServerFeatures(raw: [:])
    /// The terminal servers (Open Terminal sandboxes) the Account may use; `nil` until loaded (#132).
    @ObservationIgnored public private(set) var terminals: [TerminalServer]?
    @ObservationIgnored private var user: SessionUser?
    /// The user settings behind Instructions, Memory and the nickname in Chats (PERS-01..03).
    @ObservationIgnored private var userSettings = UserSettings(raw: [:])
    @ObservationIgnored let client: OpenWebUIClient
    @ObservationIgnored private let database: AccountDatabase?
    @ObservationIgnored private let onSignOut: () async -> Void
    @ObservationIgnored private let composerStore: ComposerLocalStore
    /// Builds the Account switcher (AUTH-07) that Settings offers; set by `AppModel`.
    @ObservationIgnored public internal(set) var makeAccountSwitcher: (() -> AccountSwitcherModel?)?
    /// The Account switcher, while open over Settings.
    public var accountSwitcher: AccountSwitcherModel?

    init(
        account: Account,
        client: OpenWebUIClient,
        database: AccountDatabase?,
        preferences: AccountPreferencesStore? = nil,
        composerStore: ComposerLocalStore? = nil,
        notificationCenter: (any NotificationScheduling)? = nil,
        locationProvider: (any LocationProviding)? = nil,
        pro: ProStore = .unlocked(),
        onSignOut: @escaping () async -> Void
    ) {
        self.account = account
        self.pro = pro
        self.composerStore = composerStore ?? ComposerLocalStore(accountKey: account.id)
        self.client = client
        self.database = database
        self.onSignOut = onSignOut
        let preferences = preferences ?? AccountPreferencesStore(accountID: account.id)
        self.preferences = preferences
        library = ChatLibrary(client: client, database: database)
        // BRAND-04: Project covers are chosen on this device, per Account (never on the Server).
        projects = ProjectLibrary(client: client, covers: ProjectCovers(accountKey: account.id, defaults: .standard))
        // #189: personal connectors' keys live in the user settings, like the web client's; keys #186
        // kept in this device's Keychain move there on the first load (ADR 0095, amended).
        connectors = ConnectorDirectory(client: client, legacyKeys: KeychainConnectorKeyStore(accountKey: account.id))
        styles = StyleLibrary(client: client)
        location = LocationSharing(accountKey: account.id, provider: locationProvider ?? SystemLocationProvider())
        artifactLibrary = ArtifactLibrary(client: client, accountID: account.id)
        responseNotifier = ResponseNotifier(
            center: notificationCenter ?? InertNotificationCenter(),
            preferences: preferences,
            isAppActive: { [sceneActivity] in sceneActivity.isActive }
        )
        projects.onChatsChanged = { [library] in await library.refresh() }
    }

    /// Shows `route` and closes the drawer. `.settings` opens the Settings sheet on top.
    public func navigate(to route: AppRoute) {
        isDrawerOpen = false
        isChatsSearchRequested = false
        preparedConversation = nil
        if route == .settings {
            settings = makeSettings()
            isSettingsPresented = true
        } else if case .newChat = route, incognitoPolicy == .enforced {
            // Every Chat is Incognito: a new Chat is an Incognito chat (INCOG-02).
            incognitoGeneration += 1
            self.route = .incognitoChat
        } else {
            if route == .incognitoChat { incognitoGeneration += 1 }
            self.route = route
        }
    }

    /// The new Chat on screen got its Server id: show it as that Chat (drawer highlight, menus)
    /// without rebuilding the screen, whose live Conversation keeps streaming.
    public func promoteNewChat(to chatID: String) {
        isPromoting = true
        defer { isPromoting = false }
        route = .chat(id: chatID)
        isScreenPromoted = true
    }

    /// Capabilities for `model` on this Server and Account (ADR 0006).
    public func capabilities(for model: Model) -> Capabilities {
        guard let user else { return Capabilities(enabled: []) }
        return Capabilities.resolve(features: features, user: user, model: model, terminals: terminals)
    }

    /// What this Server offers of Theseus Pro (ADR 0173): its sandbox or Jupyter code interpreter,
    /// and Skills. The paywalls under the shell promise only that; `.unknown` until loaded.
    public var serverSupport: ServerSupport {
        guard state == .loaded else { return .unknown }
        let capabilities = library.capabilities
        let codeExecution: ServerSupport.CodeExecution = if capabilities.contains(.sandbox) {
            .sandbox
        } else if capabilities.contains(.codeInterpreter) {
            .interpreter
        } else {
            .none
        }
        return ServerSupport(codeExecution: codeExecution, skills: chat?.composer.skillsAvailable, connectors: connectorsAvailable)
    }

    /// Whether the Account has Connectors to turn on: the Server's (`GET /api/v1/tools/`) or its
    /// own personal ones; `nil` until known.
    private var connectorsAvailable: Bool? {
        guard library.capabilities.contains(.connectors) else { return false }
        if connectors.access.canUsePersonal || !connectors.connectors.isEmpty { return true }
        return connectors.state == .loaded && connectors.access != .unknown ? false : nil
    }

    public func isDefault(_ model: Model) -> Bool {
        defaultModelIDs.contains(model.id)
    }

    public func refresh() async {
        state = .loading
        await library.loadCached()
        do {
            async let config = client.send(.config)
            async let user = client.send(.sessionUser)
            async let models = client.send(.models)
            // The sandbox (ADR 0120): optional, so a Server without terminals still loads.
            async let terminals = try? client.send(.terminals)
            let (loadedConfig, loadedUser, loadedModels) = try await (config, user, models)
            self.terminals = await terminals ?? []
            features = loadedConfig.features
            self.user = loadedUser
            incognitoPolicy = IncognitoPolicy(user: loadedUser)
            if incognitoPolicy == .enforced, case .newChat = route { route = .incognitoChat }
            library.capabilities = Capabilities.resolve(features: loadedConfig.features, user: loadedUser, model: nil, terminals: self.terminals)
            projects.capabilities = library.capabilities
            projects.maxKnowledgeFiles = ProjectLibrary.maxFileCount(from: loadedConfig.features)
            defaultModelIDs = loadedConfig.defaultModelIDs
            self.models = loadedModels.filter { !$0.isHidden }
            state = .loaded
            prepareChat(supportsWebSocket: loadedConfig.features.supportsWebSocket)
            openPendingLink()
            await refreshPersonalization()
            await prepareWelcome(features: loadedConfig.features)
            // CONN-07: a fresh position for the first message, if the user shares it.
            Task { [location] in await location.refresh() }
            // #186: personal connectors run on this device; load them so chats can offer their tools.
            // The Connector list also tells the paywall whether there are any (ADR 0173).
            Task { [connectors] in
                await connectors.loadAccess()
                await connectors.loadIfNeeded()
            }
            // The composer's limits, pins, greeting name, model defaults and banners (HOME/MODEL/ATT).
            if let composer = chat?.composer {
                composer.configure(config: loadedConfig, accountName: loadedUser.name)
                composer.setTerminals(self.terminals ?? [])
                Task { await composer.refresh() }
            }
        } catch {
            // A 401 that couldn't be renewed has already routed back to sign-in.
            state = .failed((error as? OpenWebUIError)?.message ?? "Something went wrong.")
            return
        }
        await library.refresh()
    }

    /// The Account's full name changed on the Server (PERS-01): refresh the Settings Account card,
    /// the drawer's avatar and the device's Account list (#128).
    func accountRenamed(to name: String) {
        guard name != account.name else { return }
        account.name = name
        settings?.accountRenamed(to: name)
        onAccountChanged?(account)
    }

    /// Reloads the user settings Chats are personalized with (e.g. after Settings closes).
    public func refreshPersonalization() async {
        if let settings = try? await client.send(.userSettings) {
            userSettings = settings
            showsArtifacts = settings.capabilityDefaults.artifacts
            styles.apply(settings)
        }
        // Capability defaults, Skills and follow-ups (SET-05, #140, #141) may have changed too.
        await chat?.composer.refresh()
    }

    public func signOut() async {
        messageActions?.readAloud.stop()
        voice?.tearDown()
        sandbox?.tearDown()
        await chat?.stop()
        chat = nil
        await onSignOut()
    }

    /// Ends this shell's live connections (the Socket.IO session, health checks) when the app
    /// leaves it for good: session expiry, an Account switch or removal (AUTH-06, AUTH-07).
    public func tearDown() async {
        voice?.tearDown()
        await chat?.stop()
        chat = nil
    }

    /// The Session token was renewed silently: reconnect the socket with the new token.
    func sessionTokenDidChange() async {
        await chat?.session.reconnect()
    }

    /// Creates (or refreshes) the Chat services once models and Capabilities are known.
    private func prepareChat(supportsWebSocket: Bool) {
        let resolve: @MainActor (Model?) -> Capabilities = { [weak self] model in
            guard let self, let user = self.user else { return Capabilities(enabled: []) }
            return Capabilities.resolve(features: self.features, user: user, model: model, terminals: self.terminals)
        }
        if let chat {
            chat.update(models: models, defaultModelID: defaultModelIDs.first, capabilities: resolve)
            return
        }
        let services = ChatServices(
            client: client,
            session: .live(client: client, credential: .sessionToken, serverSupportsWebSocket: supportsWebSocket),
            models: models,
            defaultModelID: defaultModelIDs.first,
            composerStore: composerStore,
            capabilities: resolve
        )
        // ADR 0173: Pro gates in the composer, and the free code execution runs counted when a
        // Response really ran code (in the sandbox or through the Jupyter code interpreter).
        services.composer.pro = pro
        services.onSandboxResponseFinished = { [pro] state in
            Sandbox.recordRun(of: state, in: pro)
        }
        // New Chats and generated titles (CHAT-11) show up in the drawer right away.
        services.onChatTitleChanged = { [weak self] chatID, title in
            guard let self else { return }
            let now = Date()
            let existing = self.library.chat(id: chatID)
            var summary = existing ?? ChatSummary(id: chatID, title: title, createdAt: now, updatedAt: now)
            summary.title = title
            summary.updatedAt = now
            self.library.upsert(summary)
        }
        services.onChatListChanged = { [weak self] in
            Task { await self?.library.refresh() }
        }
        services.onResponseFinished = { [weak self] chatID, title, text in
            guard let notifier = self?.responseNotifier else { return }
            Task { await notifier.responseFinished(chatID: chatID, chatTitle: title, excerpt: text) }
        }
        services.personalization = { [weak self] model in
            guard let self, let user = self.user else { return nil }
            let capabilities = resolve(model)
            var personalization = ChatPersonalization(settings: self.userSettings, user: user, capabilities: capabilities)
            // PERS-05: the chosen Style after the Instructions (ADR 0111). The server keeps the
            // system prompt for Accounts allowed to set one, like Instructions.
            if capabilities.contains(.instructions) {
                personalization.styleInstructions = self.styles.selectedInstructions
            }
            return personalization
        }
        // CONN-07: `{{USER_LOCATION}}` when the user allowed sharing their location.
        services.requestVariables = { [location] in location.requestVariables() }
        // #186: personal connectors (direct tool servers) answer `execute:tool` on this device;
        // chats send them only with Theseus Pro (ADR 0173).
        services.session.useDirectToolServers(ProGatedDirectTools(base: connectors.personal.runtime, pro: pro))
        services.start()
        let actions = MessageActions(client: client)
        messageActions = actions
        // VOICE-06 → MSG-07: Read aloud uses the voice chosen in Voice settings.
        let voice = Voice(client: client, accountKey: account.id)
        actions.onDeviceVoiceIdentifier = { [weak voice] in voice?.readAloudVoiceIdentifier }
        // VOICE-03/07: thumbs in Voice mode and on its ended banner open the Feedback sheet (MSG-06).
        voice.onRate = { [weak actions] conversation, messageID, rating in
            guard let conversation = conversation as? ConversationModel, let message = conversation.message(id: messageID) else { return }
            actions?.rate(message, rating, in: conversation)
        }
        self.voice = voice
        Task { await voice.settings.load() }
        sandbox = Sandbox(client: client, accountKey: account.id, pro: pro)
        chat = services
    }
    private func makeSettings() -> SettingsModel {
        let settings = SettingsModel(
            account: account,
            client: client,
            preferences: preferences,
            capabilities: library.capabilities,
            notifier: responseNotifier,
            actions: SettingsActions(
                signOut: { [weak self] in await self?.signOut() },
                removeAccountFromDevice: { [weak self] in
                    self?.location.removeAll()
                    self?.connectors.personal.forgetKeys()
                    await self?.onRemoveAccount?()
                },
                clearCache: { [weak self] in
                    try await self?.database?.eraseAll()
                    await self?.library.refresh()
                },
                cacheSize: { [weak self] in self?.database?.diskUsage() }
            )
        )
        settings.pro = pro
        // MODEL-04: "Start new chats with" lives with the composer.
        if let composer = chat?.composer, !composer.models.isEmpty {
            settings.extensions.register(.models) { DefaultModelSettingsView(services: composer) }
        }
        // Voice settings (VOICE-06).
        if let voice {
            VoiceSettingsPage.register(in: &settings.extensions, voice: voice, capabilities: library.capabilities)
        }
        // Memory & personalization pages (PERS-01..04).
        PersonalizationSettings.register(
            in: &settings.extensions,
            client: client,
            capabilities: { [weak settings] in settings?.capabilities ?? Capabilities(enabled: []) },
            onNameChange: { [weak self] name in self?.accountRenamed(to: name) }
        )
        // Connectors and Permissions (CONN-02..07).
        ConnectorsRegistration.register(
            in: &settings.extensions,
            directory: connectors,
            location: location,
            capabilities: library.capabilities
        )
        if makeAccountSwitcher != nil {
            settings.switchAccount = { [weak self] in
                self?.accountSwitcher = self?.makeAccountSwitcher?()
            }
        }
        return settings
    }
}

/// Foreground state shared with the `ResponseNotifier` (SET-06).
@MainActor
private final class SceneActivity {
    var isActive = true
}
