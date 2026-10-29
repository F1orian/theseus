import ChatDomain
import ComposerFeature
import Fixtures
import Foundation
import Observation
import OpenWebUIKit
import Testing
@testable import VoiceFeature

final class StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

func makeClient(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
}

/// Polls the main actor until `condition` holds (bounded).
@MainActor
func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A recogniser driven by the test: `say(_:)` emits a transcript, `level(_:)` a level.
@MainActor
final class FakeRecognizer: SpeechRecognizer {
    var providesLiveTranscript = true
    var authorization: VoiceError?
    var startFailure: VoiceError?
    /// What `finish()` returns; `nil` returns the last transcript.
    var finalText: String?
    private(set) var starts: [Locale] = []
    private(set) var finishes = 0
    private(set) var cancels = 0
    private(set) var lastTranscript = ""
    private var continuation: AsyncStream<RecognitionEvent>.Continuation?

    var isRunning: Bool { continuation != nil }

    func authorize() async throws {
        if let authorization { throw authorization }
    }

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        if let startFailure { throw startFailure }
        starts.append(locale)
        lastTranscript = ""
        let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
        self.continuation = continuation
        return stream
    }

    func say(_ text: String) {
        lastTranscript = text
        continuation?.yield(.transcript(text))
    }

    func level(_ value: Float) {
        continuation?.yield(.level(value))
    }

    func finish() async throws -> String {
        finishes += 1
        continuation?.finish()
        continuation = nil
        return finalText ?? lastTranscript
    }

    func cancel() {
        cancels += 1
        continuation?.finish()
        continuation = nil
    }
}

/// A synthesiser that records what it says; each sentence finishes when the test calls
/// `finishSpeaking()` (or at once with `autoFinish`).
@MainActor
final class FakeSynthesizer: SpeechSynthesizer {
    var autoFinish = false
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    private var waiting: CheckedContinuation<Void, Never>?

    var isSpeaking: Bool { waiting != nil }

    func speak(_ text: String) async throws {
        spoken.append(text)
        if autoFinish { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func finishSpeaking() {
        waiting?.resume()
        waiting = nil
    }

    func stop() {
        stops += 1
        finishSpeaking()
    }
}

@MainActor
final class FakeAudioSession: VoiceAudioSession {
    private(set) var activations: [VoiceAudioUse] = []
    private(set) var deactivations = 0

    func activate(for use: VoiceAudioUse) throws {
        activations.append(use)
    }

    func deactivate() {
        deactivations += 1
    }
}

/// A Chat whose Responses the test writes.
@MainActor
@Observable
final class FakeConversation: VoiceConversation {
    var chatID: String? = "chat-1"
    var canSendVoiceMessage = true
    var canRateVoiceResponses = true
    private(set) var sent: [String] = []
    private(set) var stops = 0
    var responses: [String: VoiceResponseSnapshot] = [:]
    var ratings: [String: MessageAnnotation.Rating] = [:]

    func sendVoiceMessage(_ text: String) -> String? {
        guard canSendVoiceMessage else { return nil }
        sent.append(text)
        let id = "response-\(sent.count)"
        responses[id] = VoiceResponseSnapshot(text: "", isFinished: false)
        return id
    }

    func voiceResponse(id: String) -> VoiceResponseSnapshot? {
        responses[id]
    }

    func voiceRating(id: String) -> MessageAnnotation.Rating? {
        ratings[id]
    }

    func stopVoiceResponse() async {
        stops += 1
        for (id, response) in responses where !response.isFinished {
            responses[id] = VoiceResponseSnapshot(text: response.text, isFinished: true)
        }
    }

    func stream(_ id: String, _ text: String, finished: Bool = false) {
        responses[id] = VoiceResponseSnapshot(text: text, isFinished: finished)
    }
}

@MainActor
func makeComposer() -> ComposerModel {
    let transport = StubTransport()
    let model = Model(id: "claude-haiku-5-5", name: "Claude Haiku")
    let services = ComposerServices(client: makeClient(transport), models: [model], defaultModelIDs: [model.id]) { _ in
        Capabilities(enabled: Set(Capability.allCases))
    }
    return ComposerModel(services: services, selectedModelID: model.id)
}

/// Fresh, isolated defaults for one test.
func ephemeralDefaults() -> UserDefaults {
    UserDefaults(suiteName: "theseus.voice.tests.\(UUID().uuidString)") ?? .standard
}

/// A speech stack handing out the test's fakes.
@MainActor
final class FakeSpeech: SpeechProviding {
    let recognizer: FakeRecognizer
    let synthesizer: FakeSynthesizer
    let session = FakeAudioSession()
    var engineChoice = SpeechEngines()
    var voiceOptions: [VoiceOption] = []
    private(set) var synthesizerPreferences: [VoicePreferences] = []

    init(recognizer: FakeRecognizer = FakeRecognizer(), synthesizer: FakeSynthesizer = FakeSynthesizer()) {
        self.recognizer = recognizer
        self.synthesizer = synthesizer
    }

    var audioSession: any VoiceAudioSession { session }

    func engines() async -> SpeechEngines { engineChoice }

    func makeRecognizer(for use: VoiceAudioUse) async -> any SpeechRecognizer { recognizer }

    func makeSynthesizer(preferences: VoicePreferences) async -> any SpeechSynthesizer {
        synthesizerPreferences.append(preferences)
        return synthesizer
    }

    func speechLanguages() -> [SpeechLanguage] {
        SpeechStack.languages(from: ["en-US", "en-GB", "de-DE"])
    }

    func voices(for language: String?) async -> [VoiceOption] { voiceOptions }
}
