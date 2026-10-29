@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device recognition with `SpeechAnalyzer` + `SpeechTranscriber` when the transcriber
/// supports the Speech language, else `SFSpeechRecognizer` (ADR 0080).
@MainActor
final class OnDeviceSpeechRecognizer: SpeechRecognizer {
    private let voiceProcessing: Bool
    private var active: (any SpeechRecognizer)?

    init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    var providesLiveTranscript: Bool { true }

    func authorize() async throws {
        try await SpeechPermissions.requestMicrophone()
        try await SpeechPermissions.requestSpeechRecognition()
    }

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        active?.cancel()
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let analyzer = AnalyzerSpeechRecognizer(locale: supported, voiceProcessing: voiceProcessing)
            do {
                let events = try await analyzer.start(locale: supported)
                active = analyzer
                return events
            } catch {
                // The model may still be downloading or unsupported here: fall back below.
                analyzer.cancel()
            }
        }
        let legacy = LegacySpeechRecognizer(voiceProcessing: voiceProcessing)
        let events = try await legacy.start(locale: locale)
        active = legacy
        return events
    }

    func finish() async throws -> String {
        guard let active else { return "" }
        self.active = nil
        return try await active.finish()
    }

    func cancel() {
        active?.cancel()
        active = nil
    }
}

/// `SpeechAnalyzer` with a `SpeechTranscriber` module (iOS 26). Volatile results give the live
/// transcript; finalised ones are kept.
@MainActor
final class AnalyzerSpeechRecognizer: SpeechRecognizer {
    private let locale: Locale
    private let voiceProcessing: Bool
    private var capture: MicrophoneCapture?
    private var analyzer: SpeechAnalyzer?
    private var inputs: AsyncStream<AnalyzerInput>.Continuation?
    private var events: AsyncStream<RecognitionEvent>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    init(locale: Locale, voiceProcessing: Bool) {
        self.locale = locale
        self.voiceProcessing = voiceProcessing
    }

    var providesLiveTranscript: Bool { true }

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func authorize() async throws {
        try await SpeechPermissions.requestMicrophone()
    }

    func start(locale _: Locale) async throws -> AsyncStream<RecognitionEvent> {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let modules: [any SpeechModule] = [transcriber]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        let capture = MicrophoneCapture()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: capture.inputFormat) else {
            throw VoiceError.languageUnavailable(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        let (inputStream, inputs) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputStream)
        let (stream, events) = AsyncStream.makeStream(of: RecognitionEvent.self)
        self.analyzer = analyzer
        self.inputs = inputs
        self.events = events

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.receive(text, isFinal: result.isFinal)
                }
            } catch {}
        }

        let converter = AudioThreadBox(AVAudioConverter(from: capture.inputFormat, to: format))
        let target = AudioThreadBox(format)
        try capture.start(voiceProcessing: voiceProcessing) { buffer in
            events.yield(.level(MicrophoneCapture.level(of: buffer)))
            guard let converted = Self.convert(buffer, with: converter.value, to: target.value) else { return }
            inputs.yield(AnalyzerInput(buffer: converted))
        }
        self.capture = capture
        return stream
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        events?.yield(.transcript(transcript))
    }

    func finish() async throws -> String {
        capture?.stop()
        capture = nil
        inputs?.finish()
        inputs = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        analyzer = nil
        events?.finish()
        events = nil
        return transcript
    }

    func cancel() {
        capture?.stop()
        capture = nil
        inputs?.finish()
        inputs = nil
        resultsTask?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        events?.finish()
        events = nil
    }

    /// Converts a microphone buffer to the analyzer's format (runs on the audio thread).
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.format == format ? buffer : nil }
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let source = AudioThreadBox(buffer)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source.value
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}

/// `SFSpeechRecognizer` with partial results, on-device when the locale supports it.
@MainActor
final class LegacySpeechRecognizer: SpeechRecognizer {
    private let voiceProcessing: Bool
    private var capture: MicrophoneCapture?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var events: AsyncStream<RecognitionEvent>.Continuation?
    private var transcript = ""
    private var finalWaiter: CheckedContinuation<Void, Never>?
    private var isDone = false

    init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    var providesLiveTranscript: Bool { true }

    func authorize() async throws {
        try await SpeechPermissions.requestMicrophone()
        try await SpeechPermissions.requestSpeechRecognition()
    }

    func start(locale: Locale) async throws -> AsyncStream<RecognitionEvent> {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceError.languageUnavailable(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let (stream, events) = AsyncStream.makeStream(of: RecognitionEvent.self)
        self.events = events
        self.request = request
        transcript = ""
        isDone = false
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.receive(text, isFinal: isFinal, failed: failed) }
        })
        let capture = MicrophoneCapture()
        let box = AudioThreadBox(request)
        try capture.start(voiceProcessing: voiceProcessing) { buffer in
            box.value.append(buffer)
            events.yield(.level(MicrophoneCapture.level(of: buffer)))
        }
        self.capture = capture
        return stream
    }

    /// Built outside the main actor: Speech calls it on a background queue.
    private nonisolated static func resultHandler(
        _ handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private func receive(_ text: String?, isFinal: Bool, failed: Bool) {
        if let text {
            transcript = text
            events?.yield(.transcript(text))
        }
        if isFinal || failed {
            isDone = true
            finalWaiter?.resume()
            finalWaiter = nil
        }
    }

    func finish() async throws -> String {
        capture?.stop()
        capture = nil
        request?.endAudio()
        if !isDone, task != nil {
            // Wait briefly for the final result; a recogniser that never answers keeps the partial.
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finalWaiter?.resume()
                self?.finalWaiter = nil
            }
            await withCheckedContinuation { finalWaiter = $0 }
            timeout.cancel()
        }
        task = nil
        request = nil
        events?.finish()
        events = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        capture?.stop()
        capture = nil
        task?.cancel()
        task = nil
        request = nil
        finalWaiter?.resume()
        finalWaiter = nil
        events?.finish()
        events = nil
    }
}
