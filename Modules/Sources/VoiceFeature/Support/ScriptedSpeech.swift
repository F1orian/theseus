import Foundation
import OpenWebUIKit

/// UI tests and simulator walkthroughs: the simulator has no one to talk into its microphone, so
/// with `-theseus-scripted-speech` the recogniser "hears" the phrases in `THESEUS_SCRIPTED_SPEECH`
/// (separated by `|`), one per listening session, word by word. Everything else (sending,
/// speaking, voices, languages) is the live stack.
@MainActor
final class ScriptedSpeech: SpeechProviding {
    static let argument = "-theseus-scripted-speech"
    static let phrasesKey = "THESEUS_SCRIPTED_SPEECH"

    private let live: SpeechStack
    private let recognizer: QueuedPhraseRecognizer

    /// The scripted stack when the process was launched for it, else `nil`.
    static func fromLaunchArguments(client: OpenWebUIClient, process: ProcessInfo = .processInfo) -> ScriptedSpeech? {
        guard process.arguments.contains(argument) else { return nil }
        let phrases = (process.environment[phrasesKey] ?? "Hello, can you hear me?")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ScriptedSpeech(live: SpeechStack(client: client, audioSession: SilentAudioSession()), phrases: phrases)
    }

    init(live: SpeechStack, phrases: [String]) {
        self.live = live
        recognizer = QueuedPhraseRecognizer(phrases: phrases)
    }

    var audioSession: any VoiceAudioSession { live.audioSession }

    func engines() async -> SpeechEngines { await live.engines() }

    func makeRecognizer(for use: VoiceAudioUse) async -> any SpeechRecognizer { recognizer }

    func makeSynthesizer(preferences: VoicePreferences) async -> any SpeechSynthesizer {
        await live.makeSynthesizer(preferences: preferences)
    }

    func speechLanguages() -> [SpeechLanguage] { live.speechLanguages() }

    func voices(for language: String?) async -> [VoiceOption] { await live.voices(for: language) }
}

/// Says the next phrase each time it starts listening, after a short pause (or `N:` seconds for
/// a phrase written `N:phrase`); then stays silent. A phrase cut off by `cancel()` is said again
/// next time.
@MainActor
final class QueuedPhraseRecognizer: SpeechRecognizer {
    private var phrases: [String]
    private var current: String?
    private var transcript = ""
    private var continuation: AsyncStream<RecognitionEvent>.Continuation?
    private var feeding: Task<Void, Never>?

    init(phrases: [String]) {
        self.phrases = phrases
    }

    var providesLiveTranscript: Bool { true }

    func authorize() async throws {}

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        feeding?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
        self.continuation = continuation
        transcript = ""
        guard !phrases.isEmpty else { return stream }
        let entry = phrases.removeFirst()
        current = entry
        var phrase = entry
        var delay = 1.5
        if let colon = entry.firstIndex(of: ":"), let seconds = Double(entry[..<colon]) {
            delay = seconds
            phrase = String(entry[entry.index(after: colon)...])
        }
        feeding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            var heard: [Substring] = []
            for word in phrase.split(separator: " ") {
                guard !Task.isCancelled else { return }
                heard.append(word)
                let text = heard.joined(separator: " ")
                self?.transcript = text
                continuation.yield(.transcript(text))
                for step in 0..<3 {
                    continuation.yield(.level(Float(4 + (heard.count + step) % 5) / 10))
                    try? await Task.sleep(for: .milliseconds(90))
                }
            }
            continuation.yield(.level(0))
            self?.current = nil
        }
        return stream
    }

    func finish() async throws -> String {
        feeding?.cancel()
        continuation?.finish()
        continuation = nil
        return transcript
    }

    func cancel() {
        feeding?.cancel()
        if let current, transcript.isEmpty { phrases.insert(current, at: 0) }
        current = nil
        continuation?.finish()
        continuation = nil
    }
}
