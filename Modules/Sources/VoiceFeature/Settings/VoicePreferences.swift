public import Foundation
public import Observation
public import OpenWebUIKit

/// The Account's Voice settings (VOICE-02, VOICE-06), stored at `theseus.voice` in the user
/// settings so they roam across devices (ADR 0012, ADR 0081).
public struct VoicePreferences: Sendable, Equatable, Codable {
    /// The key inside the `theseus` namespace.
    public static let namespaceKey = "voice"

    public enum Speed: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case slow
        case normal
        case fast

        public var id: Self { self }

        public var title: String {
            switch self {
            case .slow: "Slow"
            case .normal: "Normal"
            case .fast: "Fast"
            }
        }

        /// Relative to the synthesiser's default rate.
        public var rateMultiplier: Float {
            switch self {
            case .slow: 0.8
            case .normal: 1
            case .fast: 1.25
            }
        }
    }

    public enum Mode: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case handsFree
        case pushToTalk

        public var id: Self { self }

        public var title: String {
            switch self {
            case .handsFree: "Hands free"
            case .pushToTalk: "Push to talk"
            }
        }

        public var caption: String {
            switch self {
            case .handsFree: "Best for quiet places"
            case .pushToTalk: "Hold while you talk, let go to send"
            }
        }
    }

    /// The voice that speaks Responses: an on-device voice identifier, or a Server voice id when
    /// the Server has a TTS engine (ADR 0080). `nil`: a voice for the Speech language.
    public var voice: String?
    /// The Speech language (BCP 47, e.g. `en-GB`) for Dictation, Voice mode and the voice list.
    /// `nil`: the device's language.
    public var language: String?
    public var speed: Speed
    public var mode: Mode

    public init(voice: String? = nil, language: String? = nil, speed: Speed = .normal, mode: Mode = .handsFree) {
        self.voice = voice
        self.language = language
        self.speed = speed
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case voice, language, speed, mode
    }

    // Unknown or missing values fall back one by one, so older or newer clients' values stay usable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voice = (try? container.decodeIfPresent(String.self, forKey: .voice)).flatMap { $0?.isEmpty == false ? $0 : nil }
        language = (try? container.decodeIfPresent(String.self, forKey: .language)).flatMap { $0?.isEmpty == false ? $0 : nil }
        speed = (try? container.decodeIfPresent(String.self, forKey: .speed)).flatMap { $0.flatMap(Speed.init(rawValue:)) } ?? .normal
        mode = (try? container.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0.flatMap(Mode.init(rawValue:)) } ?? .handsFree
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(speed, forKey: .speed)
        try container.encode(mode, forKey: .mode)
    }

    /// The value as stored in the `theseus` namespace.
    public func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }

    /// The Speech language as a `Locale` (the device's when unset).
    public var locale: Locale {
        language.map(Locale.init(identifier:)) ?? Locale.current
    }
}

extension UserSettings {
    /// Voice settings at `theseus.voice` (defaults when never saved).
    public var voicePreferences: VoicePreferences {
        theseusValue(VoicePreferences.self, forKey: VoicePreferences.namespaceKey) ?? VoicePreferences()
    }
}

/// Loads and saves the Account's `VoicePreferences`. Changes apply locally at once and are
/// written to the Server in the background; a failed write keeps the local value and reports it.
@MainActor
@Observable
public final class VoiceSettingsStore {
    public private(set) var preferences: VoicePreferences
    /// The last failed save, for the Voice settings page.
    public var errorMessage: String?

    @ObservationIgnored private let client: OpenWebUIClient?
    @ObservationIgnored private let cache: UserDefaults?
    @ObservationIgnored private let cacheKey: String
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - client: the Account's client; `nil` keeps everything local (previews).
    ///   - accountKey: scopes the on-device cache that's used until the Server answers.
    public init(client: OpenWebUIClient?, accountKey: String, cache: UserDefaults? = .standard) {
        self.client = client
        self.cache = cache
        cacheKey = "theseus.voice.\(accountKey).preferences"
        if let data = cache?.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(VoicePreferences.self, from: data) {
            preferences = cached
        } else {
            preferences = VoicePreferences()
        }
    }

    /// Reads `theseus.voice` once per session (later calls are no-ops unless `force`).
    public func load(force: Bool = false) async {
        guard let client, force || !loaded else { return }
        guard let settings = try? await client.send(.userSettings) else { return }
        loaded = true
        // A change made while loading wins over the stored value.
        guard saveTask == nil else { return }
        apply(settings.voicePreferences)
    }

    /// Changes the preferences and saves them.
    public func update(_ change: (inout VoicePreferences) -> Void) {
        var updated = preferences
        change(&updated)
        guard updated != preferences else { return }
        apply(updated)
        save(updated)
    }

    private func apply(_ value: VoicePreferences) {
        preferences = value
        if let data = try? JSONEncoder().encode(value) {
            cache?.set(data, forKey: cacheKey)
        }
    }

    private func save(_ value: VoicePreferences) {
        guard let client, let json = try? value.jsonValue() else { return }
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            do {
                try await client.updateTheseusSettings { $0[VoicePreferences.namespaceKey] = json }
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = "Couldn't save your voice settings. \((error as? OpenWebUIError)?.message ?? "")"
            }
            if self?.preferences == value { self?.saveTask = nil }
        }
    }

    /// Waits for pending saves (tests).
    func flush() async {
        while let task = saveTask {
            await task.value
            if saveTask == task { saveTask = nil }
        }
    }
}

/// One-time hints, kept on this device per Account (ADR 0012): the Dictation intro (VOICE-02) and
/// the Push to talk tooltip (VOICE-04).
@MainActor
public final class VoiceHints {
    private let defaults: UserDefaults
    private let prefix: String

    public init(accountKey: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefix = "theseus.voice.\(accountKey)."
    }

    public var hasSeenDictationIntro: Bool {
        get { defaults.bool(forKey: prefix + "dictationIntroSeen") }
        set { defaults.set(newValue, forKey: prefix + "dictationIntroSeen") }
    }

    public var hasSeenPushToTalkHint: Bool {
        get { defaults.bool(forKey: prefix + "pushToTalkHintSeen") }
        set { defaults.set(newValue, forKey: prefix + "pushToTalkHintSeen") }
    }

    /// Forgets the hints (the Account was removed from this device).
    public func reset() {
        defaults.removeObject(forKey: prefix + "dictationIntroSeen")
        defaults.removeObject(forKey: prefix + "pushToTalkHintSeen")
    }
}
