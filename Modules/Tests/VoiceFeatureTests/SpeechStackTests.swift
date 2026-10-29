import Fixtures
import Foundation
import OpenWebUIKit
import Testing
@testable import VoiceFeature

@Suite("Speech stack and Voice settings (ADR 0080, VOICE-02, VOICE-06)")
@MainActor
struct SpeechStackTests {
    @Test func theTestServerHasNoEnginesSoEverythingRunsOnDevice() throws {
        let config = try JSONDecoder().decode(AudioConfig.self, from: Fixture.data("config.json"))
        #expect(!config.hasServerTranscription)
        #expect(!config.hasServerSpeech)
        #expect(SpeechEngines.choose(for: config) == SpeechEngines(recognition: .onDevice, synthesis: .onDevice))
        #expect(SpeechEngines.choose(for: nil) == SpeechEngines())
    }

    @Test func configuredEnginesAreUsed() throws {
        let config = try JSONDecoder().decode(AudioConfig.self, from: Fixture.data("synthetic/config.audio-engines.json"))
        #expect(config.sttEngine == "openai")
        #expect(SpeechEngines.choose(for: config) == SpeechEngines(recognition: .server, synthesis: .server, serverVoice: "alloy"))
        // The web client's browser recogniser isn't a Server engine.
        let web = try JSONDecoder().decode(AudioConfig.self, from: Data(#"{"audio":{"stt":{"engine":"web"},"tts":{"engine":""}}}"#.utf8))
        #expect(SpeechEngines.choose(for: web) == SpeechEngines())
    }

    @Test func liveStackResolvesOnceFromTheServerConfig() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/config", fixture: "config.json")
        let stack = SpeechStack(client: makeClient(transport), audioSession: FakeAudioSession())
        #expect(await stack.engines() == SpeechEngines())
        _ = await stack.engines()
        #expect(transport.requests.count == 1)
    }

    @Test func serverVoicesComeFromTheTTSEngine() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/config", fixture: "synthetic/config.audio-engines.json")
        try transport.stub("GET", "api/v1/audio/voices", fixture: "synthetic/audio.voices.json")
        let stack = SpeechStack(client: makeClient(transport), audioSession: FakeAudioSession())
        let voices = await stack.voices(for: "en-US")
        #expect(voices.map(\.name) == ["Alloy", "Echo", "nova"])
    }

    @Test func recordedVoicesAreEmptyWithoutAnEngine() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/audio/voices", fixture: "audio.voices.json")
        let voices = try await makeClient(transport).send(.audioVoices)
        #expect(voices.isEmpty)
    }

    @Test func languagesAreUniqueAndSortedByName() {
        let languages = SpeechStack.languages(from: ["fr_FR", "en-GB", "de-DE", "en_GB", "en-US"], display: Locale(identifier: "en"))
        #expect(languages.map(\.id) == ["en-GB", "en-US", "fr-FR", "de-DE"].sorted { lhs, rhs in
            SpeechLanguage.displayName(for: lhs, in: Locale(identifier: "en")) < SpeechLanguage.displayName(for: rhs, in: Locale(identifier: "en"))
        })
        #expect(languages.first { $0.id == "en-GB" }?.name == "English (United Kingdom)")
    }

    // MARK: Preferences

    @Test func preferencesDecodeLeniently() throws {
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(#"""
        {"ui": {"x": 1}, "theseus": {"voice": {"voice": "com.apple.voice.Ava", "language": "en-GB", "speed": "fast", "mode": "pushToTalk"}}}
        """#.utf8))
        #expect(settings.voicePreferences == VoicePreferences(voice: "com.apple.voice.Ava", language: "en-GB", speed: .fast, mode: .pushToTalk))
        let odd = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"theseus": {"voice": {"speed": "warp", "mode": 3, "voice": ""}}}"#.utf8))
        #expect(odd.voicePreferences == VoicePreferences())
        #expect(UserSettings(raw: [:]).voicePreferences == VoicePreferences())
    }

    @Test func savingWritesOnlyTheVoiceKeyOfTheTheseusNamespace() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/users/user/settings", fixture: "user-settings.json")
        transport.stub("POST", "api/v1/users/user/settings/update") { request in
            (200, request.httpBody ?? Data())
        }
        let store = VoiceSettingsStore(client: makeClient(transport), accountKey: "test", cache: ephemeralDefaults())
        await store.load()
        store.update {
            $0.speed = .slow
            $0.mode = .pushToTalk
            $0.language = "de-DE"
        }
        #expect(store.preferences.speed == .slow, "applies locally at once")
        await store.flush()
        #expect(store.errorMessage == nil)

        let update = try #require(transport.requests.last { $0.url?.path() == "/api/v1/users/user/settings/update" })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(update.httpBody))
        #expect(body.objectValue?.keys.sorted() == ["theseus"])
        #expect(body[path: "theseus.voice.speed"]?.stringValue == "slow")
        #expect(body[path: "theseus.voice.mode"]?.stringValue == "pushToTalk")
        #expect(body[path: "theseus.voice.language"]?.stringValue == "de-DE")
        // Keys other features own in the namespace survive (read-modify-write, ADR 0012).
        let stored = try JSONDecoder().decode(UserSettings.self, from: Fixture.data("user-settings.json"))
        for key in stored.theseus.keys where key != "voice" {
            #expect(body[path: "theseus.\(key)"] == stored.theseus[key])
        }
    }

    @Test func aFailedSaveKeepsTheChoiceAndSaysSo() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/users/user/settings", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        let store = VoiceSettingsStore(client: makeClient(transport), accountKey: "test", cache: ephemeralDefaults())
        store.update { $0.speed = .fast }
        await store.flush()
        #expect(store.preferences.speed == .fast)
        #expect(store.errorMessage?.hasPrefix("Couldn't save your voice settings.") == true)
    }

    @Test func theCacheSeedsTheNextSession() {
        let defaults = ephemeralDefaults()
        let first = VoiceSettingsStore(client: nil, accountKey: "acc", cache: defaults)
        first.update { $0.voice = "daniel" }
        let next = VoiceSettingsStore(client: nil, accountKey: "acc", cache: defaults)
        #expect(next.preferences.voice == "daniel")
        let otherAccount = VoiceSettingsStore(client: nil, accountKey: "other", cache: defaults)
        #expect(otherAccount.preferences.voice == nil)
    }

    @Test func hintsAreRememberedPerAccount() {
        let defaults = ephemeralDefaults()
        let hints = VoiceHints(accountKey: "a", defaults: defaults)
        #expect(!hints.hasSeenDictationIntro)
        hints.hasSeenDictationIntro = true
        hints.hasSeenPushToTalkHint = true
        #expect(VoiceHints(accountKey: "a", defaults: defaults).hasSeenDictationIntro)
        #expect(!VoiceHints(accountKey: "b", defaults: defaults).hasSeenDictationIntro)
        hints.reset()
        #expect(!VoiceHints(accountKey: "a", defaults: defaults).hasSeenPushToTalkHint)
    }

    @Test func readAloudUsesTheChosenVoice() {
        let voice = Voice(speech: FakeSpeech(), settings: VoiceSettingsStore(client: nil, accountKey: "a", cache: nil), hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        #expect(voice.readAloudVoiceIdentifier == nil)
        voice.settings.update { $0.voice = "com.apple.voice.premium.en-GB.Daniel" }
        #expect(voice.readAloudVoiceIdentifier == "com.apple.voice.premium.en-GB.Daniel")
    }

    @Test func speedsMapToRates() {
        #expect(VoicePreferences.Speed.slow.rateMultiplier < VoicePreferences.Speed.normal.rateMultiplier)
        #expect(VoicePreferences.Speed.fast.rateMultiplier > VoicePreferences.Speed.normal.rateMultiplier)
        #expect(VoicePreferences.Mode.allCases.map(\.title) == ["Hands free", "Push to talk"])
    }
}
