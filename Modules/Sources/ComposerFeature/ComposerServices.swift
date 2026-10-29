import ChatDomain
public import Entitlements
public import Foundation
public import Observation
public import OpenWebUIKit

/// On-device composer state of one Account: the last model used, Effort picks per model, the
/// last visit (for the greeting) and dismissed banners. Nothing here needs to roam (ADR 0041).
@MainActor
public final class ComposerLocalStore {
    private let defaults: UserDefaults
    private let prefix: String

    /// - Parameters:
    ///   - accountKey: Scopes the keys to one Account.
    ///   - defaults: `nil` uses a throwaway suite (tests, previews).
    public init(accountKey: String, defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: "theseus.composer.ephemeral.\(UUID().uuidString)") ?? .standard
        prefix = "theseus.composer.\(accountKey)."
    }

    public var lastUsedModelID: String? {
        get { defaults.string(forKey: prefix + "lastModel") }
        set { defaults.set(newValue, forKey: prefix + "lastModel") }
    }

    public var lastVisit: Date? {
        get { defaults.object(forKey: prefix + "lastVisit") as? Date }
        set { defaults.set(newValue, forKey: prefix + "lastVisit") }
    }

    public var dismissedBannerIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: prefix + "dismissedBanners") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: prefix + "dismissedBanners") }
    }

    public func effortSelection(for modelID: String) -> EffortSelection {
        guard let data = defaults.data(forKey: prefix + "effort." + modelID),
              let selection = try? JSONDecoder().decode(EffortSelection.self, from: data)
        else { return EffortSelection() }
        return selection
    }

    public func setEffortSelection(_ selection: EffortSelection, for modelID: String) {
        defaults.set(try? JSONEncoder().encode(selection), forKey: prefix + "effort." + modelID)
    }

    /// Forgets everything (the Account was removed from the device).
    public func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Everything composers of one signed-in Account share: the models and their Capabilities,
/// Attachment limits, the model for new Chats (MODEL-04), Effort picks (MODEL-02), the
/// greeting's name (HOME-01), server banners (HOME-04) and the thumbnail cache (ATT-04).
///
/// `ChatServices` owns one; the shell feeds it with `update(…)`, `configure(…)` and `refresh()`.
@MainActor
@Observable
public final class ComposerServices {
    public let client: OpenWebUIClient
    public private(set) var models: [Model]
    /// The admin's default model(s) for new chats (`default_models`).
    public private(set) var adminDefaultModelIDs: [String]
    public private(set) var fileLimits = FileLimits()
    /// The admin's pins (`default_pinned_models`), used when the user has none.
    public private(set) var adminPinnedModelIDs: [String] = []
    /// The Account's stored user settings (nil until loaded).
    public private(set) var settings: UserSettings?
    /// The Account's full name (`user.name`).
    public private(set) var accountName: String?
    public private(set) var banners: [ServerBanner] = []
    /// The terminal servers the Account may use (Open Terminal, OT-05): their upload mode decides
    /// whether Attachments go into the sandbox.
    public private(set) var terminals: [TerminalServer] = []
    /// The Server's active Skills (#140), A–Z: the Account's own and those shared with it (#187).
    /// Empty until loaded, or when the Server has none.
    public private(set) var skills: [Skill] = []
    /// Whether the Account can use Skills on this Server (ADR 0173: the paywall promises them only
    /// then): `true` once some are listed, `false` when there are none or the Server refuses the
    /// list, `nil` until it loaded.
    public private(set) var skillsAvailable: Bool?
    /// The signed-in Account's id and role, to tell its own Skills from shared ones (#187).
    public private(set) var skillsAccountID: String?
    @ObservationIgnored private var skillsAccountIsAdmin = false
    /// Whether the user asked for follow-up suggestions (`ui.autoFollowUps`, #141). Off until set.
    public var followUpsEnabled: Bool { settings?.followUpsPreference ?? false }
    /// The consent text to confirm before turning on web search, when the admin requires it (CONN-01).
    public private(set) var webSearchConfirmation: String?
    public private(set) var dismissedBannerIDs: Set<String>
    /// Bumped when an Effort pick changes, so chips refresh.
    public private(set) var effortRevision = 0
    /// Thumbnails of uploaded and sent images, by server file id.
    public let images: AttachmentImageCache
    /// Theseus Pro (ADR 0173): the sandbox allowance, Skills and Voice mode gates. The app hands
    /// over its store; without one everything is unlocked (tests, previews).
    @ObservationIgnored public var pro: ProStore = .unlocked()
    /// How often a processing document's status is polled.
    @ObservationIgnored public var processingPollInterval: Duration = .seconds(1)
    /// Gives up waiting for document processing after this long.
    @ObservationIgnored public var processingTimeout: Duration = .seconds(180)

    @ObservationIgnored private var resolveCapabilities: @MainActor (Model?) -> Capabilities
    @ObservationIgnored public let store: ComposerLocalStore

    public init(
        client: OpenWebUIClient,
        models: [Model],
        defaultModelIDs: [String],
        store: ComposerLocalStore? = nil,
        capabilities: @escaping @MainActor (Model?) -> Capabilities
    ) {
        self.client = client
        self.models = models
        adminDefaultModelIDs = defaultModelIDs
        resolveCapabilities = capabilities
        let store = store ?? ComposerLocalStore(accountKey: "ephemeral")
        self.store = store
        dismissedBannerIDs = store.dismissedBannerIDs
        images = AttachmentImageCache(client: client)
    }

    // MARK: Inputs

    public func update(models: [Model], defaultModelIDs: [String], capabilities: @escaping @MainActor (Model?) -> Capabilities) {
        self.models = models
        adminDefaultModelIDs = defaultModelIDs
        resolveCapabilities = capabilities
    }

    /// Takes the Server's limits and pins and the Account's name from `/api/config` and the session user.
    public func configure(config: ServerConfig, accountName: String?) {
        fileLimits = config.fileLimits
        adminPinnedModelIDs = config.defaultPinnedModelIDs
        webSearchConfirmation = config.features.webSearchConfirmation
        self.accountName = accountName
    }

    /// Loads the Account's user settings (nickname, pins, model defaults) and the Server's banners.
    public func refresh() async {
        async let settings = try? client.send(.userSettings)
        async let banners = try? client.send(.banners)
        async let skills = Self.loadSkills(client)
        async let account = try? client.send(.sessionUser)
        if let loaded = await settings { self.settings = loaded }
        if let loaded = await banners { self.banners = loaded }
        if let user = await account {
            skillsAccountID = user.id
            skillsAccountIsAdmin = user.role == .admin
        }
        switch await skills {
        case .success(let loaded):
            // Admins list every Skill on the Server; others' private ones stay out of Chats (#187).
            self.skills = loaded
                .filter { $0.isActive && SkillScope($0, userID: skillsAccountID, isAdmin: skillsAccountIsAdmin) != .othersPrivate }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            skillsAvailable = !self.skills.isEmpty
        case .failure(.forbidden), .failure(.unauthorized), .failure(.notOpenWebUI), .failure(.server(404, _)):
            // Refused or missing: no Skills here.
            skillsAvailable = false
        case .failure:
            // A network failure says nothing yet.
            break
        }
    }

    private static func loadSkills(_ client: OpenWebUIClient) async -> Result<[Skill], OpenWebUIError> {
        do {
            return .success(try await client.send(.skills))
        } catch {
            return .failure(error)
        }
    }

    /// The Account's own Skills (#187), A–Z.
    public var yourSkills: [Skill] {
        skills.filter { $0.isOwned(by: skillsAccountID) }
    }

    /// Skills others shared with the Account (#187), A–Z.
    public var sharedSkills: [Skill] {
        skills.filter { !$0.isOwned(by: skillsAccountID) }
    }

    public func setTerminals(_ terminals: [TerminalServer]) {
        self.terminals = terminals
    }

    /// The terminal that takes `model`'s Attachments into its sandbox (`chat_uploads: "filesystem"`),
    /// when the model has a sandbox.
    public func filesystemUploadTerminal(for model: Model?) -> TerminalServer? {
        guard let model, capabilities(for: model).contains(.sandbox),
              let terminal = terminals.first(where: { $0.id == model.terminalID }),
              terminal.uploadMode == .filesystem
        else { return nil }
        return terminal
    }

    public func capabilities(for model: Model?) -> Capabilities {
        resolveCapabilities(model)
    }

    public func model(id: String?) -> Model? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    // MARK: Models (MODEL-01, 03, 04)

    /// The user's pins, else the admin's.
    public var pinnedModelIDs: [String] {
        let user = settings?.pinnedModelIDs ?? []
        return user.isEmpty ? adminPinnedModelIDs : user
    }

    public var catalog: ModelCatalog {
        ModelCatalog(models: models, pinnedIDs: pinnedModelIDs)
    }

    /// The fixed default chosen in Settings (`theseus.models.defaultModelID`), if any.
    public var defaultModelSetting: String? {
        settings?.modelPreferences.defaultModelID
    }

    /// The model new Chats start with: the Settings choice, else the last model used, else the
    /// web client's default, else the admin's, else the first model (ADR 0041).
    public var preferredModelID: String? {
        let candidates = [defaultModelSetting, store.lastUsedModelID]
            + (settings?.webClientDefaultModelIDs ?? []).map(Optional.some)
            + adminDefaultModelIDs.map(Optional.some)
        for case let id? in candidates where model(id: id) != nil {
            return id
        }
        return models.first?.id
    }

    /// Remembers the model of a sent Message for the next new Chat.
    public func recordUse(of modelID: String) {
        store.lastUsedModelID = modelID
    }

    /// Stores the Settings default (`nil`: use the last model) in `theseus.models` (roams).
    public func setDefaultModel(_ modelID: String?) async throws(OpenWebUIError) {
        let value = try ModelPreferences(defaultModelID: modelID).jsonValueOrEmpty()
        settings = try await client.updateTheseusSettings { namespace in
            namespace[ModelPreferences.namespaceKey] = value
        }
    }

    // MARK: Effort (MODEL-02)

    public func effortConfiguration(for model: Model?) -> EffortConfiguration? {
        guard let model else { return nil }
        return EffortConfiguration.resolve(for: model, capabilities: capabilities(for: model))
    }

    public func effortSelection(for modelID: String) -> EffortSelection {
        _ = effortRevision
        return store.effortSelection(for: modelID)
    }

    public func setEffort(_ optionID: String, for key: String, modelID: String) {
        var selection = store.effortSelection(for: modelID)
        selection.picks[key] = optionID
        store.setEffortSelection(selection, for: modelID)
        effortRevision += 1
    }

    // MARK: Feature toggles (HOME-03)

    /// Whether `feature` starts on for a new composer with `model`: the Capabilities page
    /// defaults (SET-05) once saved, else the model's own defaults.
    public func startsEnabled(_ feature: FeatureToggle, for model: Model) -> Bool {
        if feature == .codeInterpreter, capabilities(for: model).contains(.sandbox) {
            // The sandbox defaults to on (ADR 0120).
            return settings?.capabilityDefaults.sandbox ?? true
        }
        if let settings, settings.hasCapabilityDefaults {
            let defaults = settings.capabilityDefaults
            switch feature {
            case .webSearch: return defaults.webSearch
            case .imageGeneration: return defaults.imageGeneration
            case .codeInterpreter: return defaults.codeInterpreter
            }
        }
        return model.defaultFeatureIDs.contains(feature.rawValue)
    }

    // MARK: Home (HOME-01, HOME-04)

    public var greetingName: String? {
        Greeting.name(nickname: settings?.nickname, fullName: accountName)
    }

    /// Notes this visit; returns the previous one.
    @discardableResult
    public func recordVisit(at date: Date = Date()) -> Date? {
        let previous = store.lastVisit
        store.lastVisit = date
        return previous
    }

    public var visibleBanners: [ServerBanner] {
        banners.filter { !$0.isDismissible || !dismissedBannerIDs.contains($0.id) }
    }

    public func dismiss(_ banner: ServerBanner) {
        dismissedBannerIDs.insert(banner.id)
        store.dismissedBannerIDs = dismissedBannerIDs
    }
}

/// A per-Message tool switch in the Add to Chat sheet (`features.*`).
public enum FeatureToggle: String, CaseIterable, Sendable {
    case webSearch = "web_search"
    case imageGeneration = "image_generation"
    case codeInterpreter = "code_interpreter"

    public var capability: Capability {
        switch self {
        case .webSearch: .webSearch
        case .imageGeneration: .imageGeneration
        case .codeInterpreter: .codeInterpreter
        }
    }

    /// Whether the switch shows. "Code execution" is backed by the model's sandbox when it has one,
    /// else by the code interpreter (ADR 0120).
    public func isAvailable(in capabilities: Capabilities) -> Bool {
        if self == .codeInterpreter, capabilities.contains(.sandbox) { return true }
        return capabilities.contains(capability)
    }

    /// The `features` entries for a request: every switch the Capabilities allow. Code execution
    /// backed by the sandbox goes out as `terminal_id` instead, never as `code_interpreter`.
    /// `canRunCode` is Theseus Pro's free allowance (ADR 0173): once today's free code execution
    /// runs are used up, the code interpreter goes out off, like the sandbox.
    public static func requestFeatures(
        capabilities: Capabilities,
        canRunCode: Bool,
        isOn: (FeatureToggle) -> Bool
    ) -> [String: Bool] {
        var features: [String: Bool] = [:]
        for feature in allCases where capabilities.contains(feature.capability) {
            if feature == .codeInterpreter {
                features[feature.rawValue] = !capabilities.contains(.sandbox) && canRunCode && isOn(feature)
            } else {
                features[feature.rawValue] = isOn(feature)
            }
        }
        return features
    }
}

extension ModelPreferences {
    func jsonValueOrEmpty() throws(OpenWebUIError) -> JSONValue {
        do {
            return try jsonValue()
        } catch {
            throw .decoding(String(describing: error))
        }
    }
}
