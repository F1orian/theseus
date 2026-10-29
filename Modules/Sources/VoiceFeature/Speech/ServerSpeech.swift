@preconcurrency import AVFoundation
import Foundation
import OpenWebUIKit

/// Server speech-to-text (ADR 0080): records the microphone to a WAV file and sends it to
/// `/api/v1/audio/transcriptions` when the turn ends. There is no live transcript.
@MainActor
final class ServerSpeechRecognizer: SpeechRecognizer {
    private let client: OpenWebUIClient
    private let voiceProcessing: Bool
    private var capture: MicrophoneCapture?
    private var file: AudioThreadBox<AVAudioFile>?
    private var url: URL?
    private var events: AsyncStream<RecognitionEvent>.Continuation?
    private var language: String?

    init(client: OpenWebUIClient, voiceProcessing: Bool) {
        self.client = client
        self.voiceProcessing = voiceProcessing
    }

    var providesLiveTranscript: Bool { false }

    func authorize() async throws {
        try await SpeechPermissions.requestMicrophone()
    }

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        cancel()
        language = locale.language.languageCode?.identifier
        let capture = MicrophoneCapture()
        let input = capture.inputFormat
        let url = FileManager.default.temporaryDirectory.appending(path: "theseus-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: input.sampleRate,
            AVNumberOfChannelsKey: input.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: input.commonFormat, interleaved: input.isInterleaved)
        } catch {
            throw VoiceError.failed("Theseus couldn't record your voice.")
        }
        let box = AudioThreadBox(audioFile)
        let (stream, events) = AsyncStream.makeStream(of: RecognitionEvent.self)
        try capture.start(voiceProcessing: voiceProcessing) { buffer in
            try? box.value.write(from: buffer)
            events.yield(.level(MicrophoneCapture.level(of: buffer)))
        }
        self.capture = capture
        self.file = box
        self.url = url
        self.events = events
        return stream
    }

    func finish() async throws -> String {
        capture?.stop()
        capture = nil
        file?.value.close()
        file = nil
        events?.finish()
        events = nil
        guard let url else { return "" }
        self.url = nil
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = (try? Data(contentsOf: url)) ?? Data()
        // A WAV header alone (44 bytes) means nothing was recorded.
        guard audio.count > 1_024 else { return "" }
        do {
            return try await client.send(.transcription(audio: audio, filename: "speech.wav", contentType: "audio/wav", language: language)).text
        } catch {
            throw VoiceError.failed("The Server couldn't transcribe your voice. \(error.message)")
        }
    }

    func cancel() {
        capture?.stop()
        capture = nil
        file?.value.close()
        file = nil
        events?.finish()
        events = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}

/// Speaks with `AVSpeechSynthesizer`: the chosen on-device voice (VOICE-06) at the chosen speed,
/// or a voice for the Speech language.
@MainActor
final class DeviceSpeechSynthesizer: NSObject, SpeechSynthesizer, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private let language: String?
    private let rate: Float
    private var continuation: CheckedContinuation<Void, Never>?

    init(voiceIdentifier: String?, language: String?, speed: VoicePreferences.Speed) {
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        rate = AVSpeechUtteranceDefaultSpeechRate * speed.rateMultiplier
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        finish()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    private func voice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        if let language, let voice = AVSpeechSynthesisVoice(language: language) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}

/// Speaks with the Server's TTS (`/api/v1/audio/speech`); if a request fails, the rest of the
/// session falls back to `fallback` (ADR 0080).
@MainActor
final class ServerSpeechSynthesizer: NSObject, SpeechSynthesizer, AVAudioPlayerDelegate {
    private let client: OpenWebUIClient
    private let voice: String?
    private let rate: Float
    private let fallback: any SpeechSynthesizer
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var request: Task<Data, any Error>?
    private var serverFailed = false
    private var generation = 0

    init(client: OpenWebUIClient, voice: String?, speed: VoicePreferences.Speed, fallback: any SpeechSynthesizer) {
        self.client = client
        self.voice = voice
        rate = speed.rateMultiplier
        self.fallback = fallback
    }

    func speak(_ text: String) async throws {
        if serverFailed {
            try await fallback.speak(text)
            return
        }
        generation += 1
        let current = generation
        let client = client
        let voice = voice
        let request = Task { try await client.send(.speech(text: text, voice: voice)) }
        self.request = request
        let audio: Data
        do {
            audio = try await request.value
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            serverFailed = true
            try await fallback.speak(text)
            return
        }
        guard current == generation else { return }
        do {
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            self.player = player
            guard player.play() else { throw VoiceError.failed("audio") }
        } catch {
            serverFailed = true
            try await fallback.speak(text)
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        generation += 1
        request?.cancel()
        request = nil
        player?.stop()
        player = nil
        fallback.stop()
        continuation?.resume()
        continuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}

/// The shared `AVAudioSession` (iOS); a no-op elsewhere.
@MainActor
final class SystemAudioSession: VoiceAudioSession {
    func activate(for use: VoiceAudioUse) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            switch use {
            case .dictation:
                try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            case .conversation:
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw VoiceError.failed("The microphone is in use by another app.")
        }
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
