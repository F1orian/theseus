import Foundation
public import Observation
public import OpenWebUIKit

/// Something that can speak text and be interrupted. `speak` returns when the text has been
/// spoken, or early (without throwing) after `stop()`.
@MainActor
public protocol SpeechOutput: AnyObject {
    func speak(_ text: String) async throws
    func stop()
}

/// Which speech stack reads Responses aloud (MSG-07, ADR 0051).
public enum ReadAloudEngine: Equatable, Sendable {
    /// The Server's text-to-speech (`/api/v1/audio/speech`) with its configured voice.
    case server(voice: String?)
    /// On-device `AVSpeechSynthesizer`.
    case onDevice

    /// Server speech when the Server has a TTS engine, otherwise on-device.
    public static func choose(for config: AudioConfig?) -> ReadAloudEngine {
        guard let config, config.hasServerSpeech else { return .onDevice }
        return .server(voice: config.ttsVoice)
    }
}

/// Reads one Response at a time aloud (MSG-07). The play icon of the Message being read turns
/// into pause; reading another Message stops the first.
@MainActor
@Observable
public final class ReadAloudController {
    /// The Message being read (or prepared for reading), if any.
    public private(set) var speakingMessageID: String?
    /// The last failure, for a toast.
    public private(set) var lastError: String?

    @ObservationIgnored private let makeOutput: @MainActor () async -> any SpeechOutput
    @ObservationIgnored private var output: (any SpeechOutput)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// `makeOutput` picks the speech stack for each reading (e.g. after checking the Server's
    /// audio config).
    public init(makeOutput: @escaping @MainActor () async -> any SpeechOutput) {
        self.makeOutput = makeOutput
    }

    public func isSpeaking(_ messageID: String) -> Bool {
        speakingMessageID == messageID
    }

    /// Starts reading `markdown` for `messageID`, or stops if that Message is being read.
    public func toggle(messageID: String, markdown: String) {
        if speakingMessageID == messageID {
            stop()
            return
        }
        stop()
        let text = SpeechText.plain(from: markdown)
        guard !text.isEmpty else { return }
        generation += 1
        let current = generation
        speakingMessageID = messageID
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            let output = await self.makeOutput()
            guard current == self.generation else { return }
            self.output = output
            do {
                try await output.speak(text)
            } catch {
                if current == self.generation {
                    self.lastError = "Couldn't read the response aloud."
                }
            }
            if current == self.generation {
                self.speakingMessageID = nil
                self.output = nil
            }
        }
    }

    public func stop() {
        generation += 1
        output?.stop()
        output = nil
        task?.cancel()
        task = nil
        speakingMessageID = nil
    }

    public func clearError() {
        lastError = nil
    }
}
