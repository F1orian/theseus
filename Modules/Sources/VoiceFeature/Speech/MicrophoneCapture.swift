@preconcurrency import AVFoundation
import Foundation
import Speech

/// Holds a non-Sendable audio object that is only touched from the audio thread after setup.
final class AudioThreadBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Taps the microphone with `AVAudioEngine` and hands every buffer to a handler on the audio
/// thread (ADR 0080). One capture per listening session.
@MainActor
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var running = false

    /// The microphone's native format.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Starts the engine. `voiceProcessing` turns on echo cancellation (Voice mode), so the
    /// Response being spoken isn't heard as the user's speech.
    func start(voiceProcessing: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        if voiceProcessing, !input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.failed("No microphone is available.")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(onBuffer))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.failed("The microphone couldn't start.")
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Built outside the main actor: the engine calls it on its audio thread.
    private nonisolated static func tap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in handler(buffer) }
    }

    /// The buffer's loudness mapped to 0…1 (-50 dB … 0 dB RMS).
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// Microphone and speech-recognition permission prompts.
enum SpeechPermissions {
    static func requestMicrophone() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw VoiceError.microphoneDenied }
    }

    static func requestSpeechRecognition() async throws {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization(authorizationHandler(continuation))
        }
        guard status == .authorized else { throw VoiceError.speechRecognitionDenied }
    }

    /// Built outside any actor: Speech calls it on a background queue.
    private nonisolated static func authorizationHandler(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { continuation.resume(returning: $0) }
    }
}
