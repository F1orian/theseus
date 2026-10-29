public import ComposerFeature
public import Foundation
public import Observation

/// One Dictation into a composer (VOICE-01): records, shows the live transcript and waveform, and
/// on confirm drops the text into the composer. Cancel discards it. Failures become the
/// composer's notice.
@MainActor
@Observable
public final class DictationModel {
    public enum Phase: Equatable, Sendable {
        /// Asking for permission and starting the microphone.
        case starting
        case recording
        /// Confirmed; waiting for the final transcript.
        case finishing
        case ended
    }

    public private(set) var phase: Phase = .starting
    /// What has been heard so far (italic above the composer).
    public private(set) var transcript = ""
    /// Recent microphone levels (0…1), oldest first, for the waveform.
    public private(set) var levels: [Float]
    /// The composer the text goes into.
    public let composer: ComposerModel

    /// Bars in the waveform.
    public static let levelCount = 36

    @ObservationIgnored private let recognizer: any SpeechRecognizer
    @ObservationIgnored private let audioSession: any VoiceAudioSession
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let maxDuration: Duration
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var timeLimit: Task<Void, Never>?
    @ObservationIgnored private var lastLevelAt: ContinuousClock.Instant?
    /// Called once when the Dictation ends (confirmed, cancelled or failed).
    @ObservationIgnored var onEnd: (@MainActor () -> Void)?

    /// - Parameter maxDuration: Dictation confirms itself after this long ("up to 10 minutes").
    public init(
        composer: ComposerModel,
        recognizer: any SpeechRecognizer,
        audioSession: any VoiceAudioSession,
        locale: Locale,
        maxDuration: Duration = .seconds(600)
    ) {
        self.composer = composer
        self.recognizer = recognizer
        self.audioSession = audioSession
        self.locale = locale
        self.maxDuration = maxDuration
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    /// Whether the transcript shows while the user speaks (on-device recognition).
    public var showsLiveTranscript: Bool { recognizer.providesLiveTranscript }

    /// Asks for access, starts the microphone and follows the recogniser.
    public func start() async {
        guard phase == .starting else { return }
        do {
            try await recognizer.authorize()
            guard phase == .starting else { return }
            try audioSession.activate(for: .dictation)
            let events = try await recognizer.start(locale: locale)
            guard phase == .starting else {
                recognizer.cancel()
                return
            }
            phase = .recording
            listening = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
            let limit = maxDuration
            timeLimit = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                await self?.confirm()
            }
        } catch {
            fail(error)
        }
    }

    /// Stops recording and appends what was heard to the composer's text.
    public func confirm() async {
        guard phase == .recording else {
            if phase == .starting { cancel() }
            return
        }
        phase = .finishing
        timeLimit?.cancel()
        do {
            let final = try await recognizer.finish()
            let text = final.isEmpty ? transcript : final
            insert(text)
            end()
        } catch {
            fail(error)
        }
    }

    /// Stops recording and drops what was heard.
    public func cancel() {
        guard phase != .ended else { return }
        recognizer.cancel()
        end()
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .transcript(let text):
            if phase == .recording || phase == .finishing { transcript = text }
        case .level(let level):
            // About 16 bars a second keeps the waveform readable.
            let now = ContinuousClock.now
            if let last = lastLevelAt, now - last < .milliseconds(60) { return }
            lastLevelAt = now
            levels.removeFirst()
            levels.append(level)
        }
    }

    private func insert(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let existing = composer.text
        if existing.isEmpty {
            composer.text = spoken
        } else if existing.last?.isWhitespace == true {
            composer.text = existing + spoken
        } else {
            composer.text = existing + " " + spoken
        }
    }

    private func fail(_ error: any Error) {
        recognizer.cancel()
        composer.notice = VoiceError.from(error).message
        end()
    }

    private func end() {
        guard phase != .ended else { return }
        phase = .ended
        listening?.cancel()
        listening = nil
        timeLimit?.cancel()
        timeLimit = nil
        audioSession.deactivate()
        onEnd?()
        onEnd = nil
    }
}
