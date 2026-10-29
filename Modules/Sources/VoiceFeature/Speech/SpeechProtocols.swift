public import Foundation

/// What a `SpeechRecognizer` reports while it listens.
public enum RecognitionEvent: Sendable, Equatable {
    /// Everything heard since `start`, replacing the previous transcript (partials get revised).
    case transcript(String)
    /// The microphone level, 0…1, for the waveform and for silence detection.
    case level(Float)
}

/// Why listening or speaking failed, worded for the user.
public enum VoiceError: Error, Equatable, Sendable, LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    /// No recogniser for the Speech language on this device.
    case languageUnavailable(String)
    case failed(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .microphoneDenied:
            "Theseus needs access to the microphone. You can allow it in the Settings app."
        case .speechRecognitionDenied:
            "Theseus needs speech recognition to understand you. You can allow it in the Settings app."
        case .languageUnavailable(let name):
            "Speech recognition for \(name) isn't available on this device."
        case .failed(let message):
            message
        }
    }

    /// Wraps any error as a `VoiceError`.
    public static func from(_ error: any Error) -> VoiceError {
        if let voice = error as? VoiceError { return voice }
        return .failed((error as? any LocalizedError)?.errorDescription ?? "Something went wrong with the microphone.")
    }
}

/// Speech-to-text for one listening session at a time (ADR 0080). `start` begins listening and
/// returns the events of that session; `finish` stops and returns the final transcript; `cancel`
/// discards it.
@MainActor
public protocol SpeechRecognizer: AnyObject {
    /// `true` when transcripts arrive while the user speaks (on-device); `false` when the text
    /// only comes back from `finish()` (Server transcription).
    var providesLiveTranscript: Bool { get }
    /// Asks for microphone and speech-recognition access. Throws `VoiceError` when denied.
    func authorize() async throws
    /// Starts listening in `locale`.
    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent>
    /// Stops listening and returns everything heard.
    func finish() async throws -> String
    /// Stops listening and drops what was heard.
    func cancel()
}

/// Text-to-speech, one sentence (or chunk) at a time.
@MainActor
public protocol SpeechSynthesizer: AnyObject {
    /// Speaks `text`; returns once it has been spoken, or early (without throwing) after `stop()`.
    func speak(_ text: String) async throws
    /// Stops speaking immediately.
    func stop()
}

/// What the audio session is set up for.
public enum VoiceAudioUse: Sendable, Equatable {
    /// Recording only (Dictation).
    case dictation
    /// Listening and speaking at once, echo-cancelled (Voice mode).
    case conversation
}

/// The app's audio session (iOS `AVAudioSession`), behind a protocol for tests.
@MainActor
public protocol VoiceAudioSession: AnyObject {
    func activate(for use: VoiceAudioUse) throws
    func deactivate()
}
