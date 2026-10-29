@preconcurrency import AVFoundation
public import Foundation
public import OpenWebUIKit
import Speech

/// Which engines speak and listen for this Account (ADR 0080).
public struct SpeechEngines: Sendable, Equatable {
    public enum Engine: Sendable, Equatable {
        case onDevice
        case server
    }

    public var recognition: Engine
    public var synthesis: Engine
    /// The Server's default TTS voice, when it has an engine.
    public var serverVoice: String?

    public init(recognition: Engine = .onDevice, synthesis: Engine = .onDevice, serverVoice: String? = nil) {
        self.recognition = recognition
        self.synthesis = synthesis
        self.serverVoice = serverVoice
    }

    /// Server engines where `/api/config` advertises them, on-device otherwise.
    public static func choose(for config: AudioConfig?) -> SpeechEngines {
        guard let config else { return SpeechEngines() }
        return SpeechEngines(
            recognition: config.hasServerTranscription ? .server : .onDevice,
            synthesis: config.hasServerSpeech ? .server : .onDevice,
            serverVoice: config.ttsVoice
        )
    }
}

/// A voice the user can pick in Voice settings (VOICE-06).
public struct VoiceOption: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// A short description: the accent and quality for on-device voices.
    public let detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// A Speech language (VOICE-02).
public struct SpeechLanguage: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// `identifier`'s name in the user's language ("English (United Kingdom)").
    public static func displayName(for identifier: String, in display: Locale = .current) -> String {
        display.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Everything Dictation, Voice mode and Voice settings need from the speech stack. The live
/// implementation is `SpeechStack`; tests and previews pass fakes.
@MainActor
public protocol SpeechProviding: AnyObject {
    func engines() async -> SpeechEngines
    func makeRecognizer(for use: VoiceAudioUse) async -> any SpeechRecognizer
    func makeSynthesizer(preferences: VoicePreferences) async -> any SpeechSynthesizer
    var audioSession: any VoiceAudioSession { get }
    /// The Speech languages this device can recognise, sorted by name.
    func speechLanguages() -> [SpeechLanguage]
    /// The voices that can speak `language` with the engine in use.
    func voices(for language: String?) async -> [VoiceOption]
}

/// The live speech stack of one Account session: resolves the engines once from the
/// authenticated `/api/config` (ADR 0080) and builds recognisers and synthesisers.
@MainActor
public final class SpeechStack: SpeechProviding {
    private let client: OpenWebUIClient
    private var resolved: SpeechEngines?
    public let audioSession: any VoiceAudioSession

    public init(client: OpenWebUIClient, audioSession: (any VoiceAudioSession)? = nil) {
        self.client = client
        self.audioSession = audioSession ?? SystemAudioSession()
    }

    public func engines() async -> SpeechEngines {
        if let resolved { return resolved }
        // Checked once per Account session; a failed check means on-device for now.
        let config = try? await client.send(.audioConfig)
        let engines = SpeechEngines.choose(for: config)
        if config != nil { resolved = engines }
        return engines
    }

    public func makeRecognizer(for use: VoiceAudioUse) async -> any SpeechRecognizer {
        let voiceProcessing = use == .conversation
        switch await engines().recognition {
        case .server: return ServerSpeechRecognizer(client: client, voiceProcessing: voiceProcessing)
        case .onDevice: return OnDeviceSpeechRecognizer(voiceProcessing: voiceProcessing)
        }
    }

    public func makeSynthesizer(preferences: VoicePreferences) async -> any SpeechSynthesizer {
        let engines = await engines()
        switch engines.synthesis {
        case .onDevice:
            return DeviceSpeechSynthesizer(voiceIdentifier: preferences.voice, language: preferences.language, speed: preferences.speed)
        case .server:
            let fallback = DeviceSpeechSynthesizer(voiceIdentifier: nil, language: preferences.language, speed: preferences.speed)
            return ServerSpeechSynthesizer(client: client, voice: preferences.voice ?? engines.serverVoice, speed: preferences.speed, fallback: fallback)
        }
    }

    public func speechLanguages() -> [SpeechLanguage] {
        Self.languages(from: SFSpeechRecognizer.supportedLocales().map(\.identifier))
    }

    public func voices(for language: String?) async -> [VoiceOption] {
        switch await engines().synthesis {
        case .server:
            let voices = (try? await client.send(.audioVoices)) ?? []
            return voices.map { VoiceOption(id: $0.id, name: $0.name) }
        case .onDevice:
            return Self.deviceVoices(for: language ?? Locale.current.identifier)
        }
    }

    /// Unique, named Speech languages sorted by display name.
    static func languages(from identifiers: [String], display: Locale = .current) -> [SpeechLanguage] {
        var seen = Set<String>()
        var languages: [SpeechLanguage] = []
        for identifier in identifiers {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            guard seen.insert(normalized).inserted else { continue }
            languages.append(SpeechLanguage(id: normalized, name: SpeechLanguage.displayName(for: normalized, in: display)))
        }
        return languages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// On-device voices for `language`'s language code, best quality first, one per name.
    static func deviceVoices(for language: String) -> [VoiceOption] {
        let code = Locale(identifier: language).language.languageCode?.identifier ?? language
        let region = Locale(identifier: language).region?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            Locale(identifier: $0.language).language.languageCode?.identifier == code
        }
        let sorted = voices.sorted { lhs, rhs in
            let lhsRegion = Locale(identifier: lhs.language).region?.identifier == region
            let rhsRegion = Locale(identifier: rhs.language).region?.identifier == region
            if lhsRegion != rhsRegion { return lhsRegion }
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return lhs.name < rhs.name
        }
        var seen = Set<String>()
        return sorted.compactMap { voice in
            guard seen.insert(voice.name).inserted else { return nil }
            let accent = Locale.current.localizedString(forIdentifier: voice.language)
            let quality: String? = switch voice.quality {
            case .premium: "Premium"
            case .enhanced: "Enhanced"
            default: nil
            }
            let detail = [accent, quality].compactMap(\.self).joined(separator: " · ")
            return VoiceOption(id: voice.identifier, name: voice.name, detail: detail.isEmpty ? nil : detail)
        }
    }
}
