@preconcurrency import AVFoundation
import Foundation
import NaturalLanguage
import OpenWebUIKit

/// Builds the live `SpeechOutput` for each reading: Server speech when `/api/config` advertises
/// a TTS engine, on-device speech otherwise or when the Server fails (MSG-07, ADR 0051).
@MainActor
final class LiveSpeech {
    private let client: OpenWebUIClient
    /// The user's on-device voice, if they picked one (VOICE-06).
    var voiceIdentifier: @MainActor () -> String? = { nil }
    private var engine: ReadAloudEngine?

    init(client: OpenWebUIClient) {
        self.client = client
    }

    func makeOutput() async -> any SpeechOutput {
        let engine = await resolveEngine()
        let device = DeviceSpeechOutput(voiceIdentifier: voiceIdentifier)
        switch engine {
        case .onDevice:
            return device
        case .server(let voice):
            return FallbackSpeechOutput(primary: ServerSpeechOutput(client: client, voice: voice), fallback: device)
        }
    }

    private func resolveEngine() async -> ReadAloudEngine {
        if let engine { return engine }
        // Checked once per Account session; a failed check means on-device for now.
        let config = try? await client.send(.audioConfig)
        let resolved = ReadAloudEngine.choose(for: config)
        if config != nil { engine = resolved }
        return resolved
    }
}

/// Tries `primary`; if it fails before saying anything, reads with `fallback` instead.
@MainActor
final class FallbackSpeechOutput: SpeechOutput {
    private let primary: any SpeechOutput
    private let fallback: any SpeechOutput
    private var stopped = false

    init(primary: any SpeechOutput, fallback: any SpeechOutput) {
        self.primary = primary
        self.fallback = fallback
    }

    func speak(_ text: String) async throws {
        do {
            try await primary.speak(text)
        } catch {
            guard !stopped else { return }
            try await fallback.speak(text)
        }
    }

    func stop() {
        stopped = true
        primary.stop()
        fallback.stop()
    }
}

/// Reads aloud with `AVSpeechSynthesizer`, in a voice for the text's language (or the voice the
/// user picked, once Voice settings exist: VOICE-06).
@MainActor
final class DeviceSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: @MainActor () -> String?
    private var continuation: CheckedContinuation<Void, Never>?

    init(voiceIdentifier: @escaping @MainActor () -> String?) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async throws {
        AudioSessionActivation.begin()
        defer { AudioSessionActivation.end() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: text)
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

    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if let identifier = voiceIdentifier(), let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        if let language = recognizer.dominantLanguage?.rawValue, let voice = AVSpeechSynthesisVoice(language: language) {
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

/// Reads aloud with the Server's TTS, chunk by chunk: the next chunk is synthesised while the
/// current one plays.
@MainActor
final class ServerSpeechOutput: NSObject, SpeechOutput, AVAudioPlayerDelegate {
    private let client: OpenWebUIClient
    private let voice: String?
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending: Task<Data, any Error>?
    private var stopped = false

    init(client: OpenWebUIClient, voice: String?) {
        self.client = client
        self.voice = voice
    }

    func speak(_ text: String) async throws {
        let chunks = SpeechText.chunks(of: text)
        guard !chunks.isEmpty else { return }
        AudioSessionActivation.begin()
        defer { AudioSessionActivation.end() }
        pending = fetch(chunks[0])
        for index in chunks.indices {
            guard !stopped, let current = pending else { return }
            let audio = try await current.value
            pending = index + 1 < chunks.count ? fetch(chunks[index + 1]) : nil
            guard !stopped else { return }
            try play(audio)
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        player?.stop()
        finish()
    }

    private func fetch(_ chunk: String) -> Task<Data, any Error> {
        let client = client
        let voice = voice
        return Task { try await client.send(.speech(text: chunk, voice: voice)) }
    }

    private func play(_ audio: Data) throws {
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        self.player = player
        if !player.play() { throw OpenWebUIError.decoding("audio") }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in self.finish() }
    }
}

/// Ducks other audio while a Response is read aloud and plays even with the silent switch on.
@MainActor
enum AudioSessionActivation {
    private static var depth = 0

    static func begin() {
        depth += 1
        #if os(iOS)
        guard depth == 1 else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    static func end() {
        depth = max(depth - 1, 0)
        #if os(iOS)
        guard depth == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
