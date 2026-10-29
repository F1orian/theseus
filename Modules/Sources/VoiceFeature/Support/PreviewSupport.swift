import ChatDomain
import ComposerFeature
import Foundation
import Observation
import OpenWebUIKit

/// Offline stand-ins for previews: a transport that answers nothing, a recogniser that replays a
/// transcript, a silent synthesiser and audio session.
@MainActor
enum PreviewSupport {
    static let client = OpenWebUIClient(server: URL(fileURLWithPath: "/"), transport: OfflineTransport())

    static func composer() -> ComposerModel {
        let model = Model(id: "preview", name: "Sonnet 5.5")
        let services = ComposerServices(client: client, models: [model], defaultModelIDs: [model.id]) { _ in
            Capabilities(enabled: Set(Capability.allCases))
        }
        return ComposerModel(services: services, selectedModelID: model.id)
    }

    /// A Dictation that's recording `transcript`.
    static func dictation(transcript: String) -> DictationModel {
        let recognizer = ScriptedRecognizer(transcript: transcript)
        let model = DictationModel(composer: composer(), recognizer: recognizer, audioSession: SilentAudioSession(), locale: Locale(identifier: "en-US"))
        Task { await model.start() }
        return model
    }
}

extension Voice {
    /// A Voice with preview speech and local-only settings.
    static func preview(mode: VoicePreferences.Mode = .handsFree) -> Voice {
        let settings = VoiceSettingsStore(client: nil, accountKey: "preview", cache: nil)
        settings.update { $0.mode = mode }
        let defaults = UserDefaults(suiteName: "theseus.voice.preview") ?? .standard
        return Voice(speech: PreviewSpeech(), settings: settings, hints: VoiceHints(accountKey: "preview", defaults: defaults))
    }
}

extension VoiceModeModel {
    /// A session in `phase`; with `.speaking` it shows a sample exchange.
    static func preview(voice: Voice, phase: Phase, muted: Bool = false) -> VoiceModeModel {
        let conversation = PreviewConversation()
        let model = VoiceModeModel(
            conversation: conversation,
            recognizer: ScriptedRecognizer(transcript: ""),
            synthesizer: SilentSynthesizer(),
            audioSession: SilentAudioSession(),
            preferences: voice.settings.preferences
        )
        if phase == .speaking || phase == .thinking {
            model.applyPreviewState(
                phase: phase,
                exchange: Exchange(userText: "Tell me how a mouse solves a maze.", responseID: PreviewConversation.responseID),
                muted: muted
            )
        } else {
            model.applyPreviewState(phase: phase, transcript: phase == .listening ? "Tell me how a mouse" : "", muted: muted)
        }
        return model
    }
}

/// A Chat with one finished Response.
@MainActor
@Observable
final class PreviewConversation: VoiceConversation {
    static let responseID = "preview-response"
    var chatID: String? { "preview" }
    var canSendVoiceMessage: Bool { true }
    var canRateVoiceResponses: Bool { true }

    func sendVoiceMessage(_ text: String) -> String? { Self.responseID }

    func voiceResponse(id: String) -> VoiceResponseSnapshot? {
        VoiceResponseSnapshot(
            text: """
            Sure! The simplest way is the wall follower.

            **Step one:** put one paw on the right-hand wall at the entrance and keep it there.

            **Step two:** follow that wall through every turn. In a maze without loops, it leads to the exit.
            """,
            isFinished: true
        )
    }

    func voiceRating(id: String) -> MessageAnnotation.Rating? { nil }

    func stopVoiceResponse() async {}
}

/// Answers every request with a transport error (previews never reach a Server).
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw OpenWebUIError.transport(.notConnectedToInternet)
    }
}

/// Emits `transcript` word by word with a wobbling level, then waits.
@MainActor
final class ScriptedRecognizer: SpeechRecognizer {
    private let transcript: String
    private var continuation: AsyncStream<RecognitionEvent>.Continuation?
    private var feeding: Task<Void, Never>?

    init(transcript: String) {
        self.transcript = transcript
    }

    var providesLiveTranscript: Bool { true }

    func authorize() async throws {}

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
        self.continuation = continuation
        let words = transcript.split(separator: " ").map(String.init)
        continuation.yield(.transcript(transcript))
        feeding = Task {
            var spoken: [String] = []
            for (index, word) in words.enumerated() {
                spoken.append(word)
                continuation.yield(.transcript(spoken.joined(separator: " ")))
                for step in 0..<4 {
                    continuation.yield(.level(Float((index * 7 + step * 3) % 10) / 10))
                    try? await Task.sleep(for: .milliseconds(70))
                }
            }
        }
        return stream
    }

    func finish() async throws -> String {
        feeding?.cancel()
        continuation?.finish()
        return transcript
    }

    func cancel() {
        feeding?.cancel()
        continuation?.finish()
    }
}

@MainActor
final class SilentSynthesizer: SpeechSynthesizer {
    func speak(_ text: String) async throws {}
    func stop() {}
}

@MainActor
final class SilentAudioSession: VoiceAudioSession {
    func activate(for use: VoiceAudioUse) throws {}
    func deactivate() {}
}

/// A speech stack for previews with a few named voices and languages.
@MainActor
final class PreviewSpeech: SpeechProviding {
    let audioSession: any VoiceAudioSession = SilentAudioSession()

    func engines() async -> SpeechEngines { SpeechEngines() }

    func makeRecognizer(for use: VoiceAudioUse) async -> any SpeechRecognizer {
        ScriptedRecognizer(transcript: "Tell me how a mouse solves a maze.")
    }

    func makeSynthesizer(preferences: VoicePreferences) async -> any SpeechSynthesizer {
        SilentSynthesizer()
    }

    func speechLanguages() -> [SpeechLanguage] {
        SpeechStack.languages(from: ["en-US", "en-GB", "en-IN", "de-DE", "de-AT", "fr-FR", "fr-CA", "it-IT", "ja-JP", "zh-CN"])
    }

    func voices(for language: String?) async -> [VoiceOption] {
        [
            VoiceOption(id: "ava", name: "Ava", detail: "English (United States) · Premium"),
            VoiceOption(id: "daniel", name: "Daniel", detail: "English (United Kingdom)"),
            VoiceOption(id: "karen", name: "Karen", detail: "English (Australia)"),
            VoiceOption(id: "rishi", name: "Rishi", detail: "English (India)"),
        ]
    }
}
