public import Foundation
public import Observation

/// One Voice mode session (VOICE-03…05, ADR 0081): listens, sends each spoken turn into the
/// Chat, speaks the Response sentence by sentence, and lets the user interrupt (barge-in), mute
/// the microphone or talk with push to talk.
@MainActor
@Observable
public final class VoiceModeModel: Identifiable {
    public enum Phase: Equatable, Sendable {
        /// Asking for permission and starting the audio.
        case starting
        /// The user's turn: the microphone is open (unless muted or push to talk is idle).
        case listening
        /// The turn was sent; waiting for the first sentence of the Response.
        case thinking
        /// The Response is being spoken.
        case speaking
        case failed(String)
        case ended
    }

    /// The latest spoken turn and its Response, shown on the canvas.
    public struct Exchange: Equatable, Sendable {
        public let userText: String
        public let responseID: String
    }

    public nonisolated let id = UUID()
    public private(set) var phase: Phase = .starting
    /// The user's words so far in this turn (italic on the canvas).
    public private(set) var transcript = ""
    public private(set) var exchange: Exchange?
    /// VOICE-05: the microphone is off; the Response is still spoken.
    public private(set) var isMuted = false
    public private(set) var mode: VoicePreferences.Mode
    /// VOICE-04: the push-to-talk pill is held down.
    public private(set) var isHoldingToTalk = false
    /// Recent microphone levels (0…1) for the push-to-talk waveform.
    public private(set) var levels: [Float]
    /// A transient problem (a turn that couldn't be sent, a failed Response).
    public private(set) var notice: String?
    public let startedAt: Date
    /// The Responses of this session, in order.
    public private(set) var responseIDs: [String] = []

    public let conversation: any VoiceConversation
    @ObservationIgnored private let recognizer: any SpeechRecognizer
    @ObservationIgnored private var synthesizer: any SpeechSynthesizer
    @ObservationIgnored private let audioSession: any VoiceAudioSession
    @ObservationIgnored private var locale: Locale
    @ObservationIgnored private let silence: Duration
    @ObservationIgnored private let bargeInWords: Int
    @ObservationIgnored private let now: @MainActor () -> Date

    @ObservationIgnored private var recognizing = false
    @ObservationIgnored private var recognizerGeneration = 0
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var endOfTurn: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    @ObservationIgnored private var splitter = SentenceSplitter()
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var responseComplete = false
    @ObservationIgnored private var heardSpeech = false
    @ObservationIgnored private var lastLevelAt: ContinuousClock.Instant?
    @ObservationIgnored private var endingTurn = false

    /// Microphone level that counts as speech when the recogniser has no live transcript.
    static let speechLevel: Float = 0.35

    /// - Parameters:
    ///   - silence: how long a pause ends a Hands free turn.
    ///   - bargeInWords: how many words heard while the Response is spoken interrupt it.
    public init(
        conversation: any VoiceConversation,
        recognizer: any SpeechRecognizer,
        synthesizer: any SpeechSynthesizer,
        audioSession: any VoiceAudioSession,
        preferences: VoicePreferences,
        silence: Duration = .milliseconds(1_200),
        bargeInWords: Int = 2,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.conversation = conversation
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.audioSession = audioSession
        locale = preferences.locale
        mode = preferences.mode
        self.silence = silence
        self.bargeInWords = bargeInWords
        self.now = now
        startedAt = now()
        levels = Array(repeating: 0, count: DictationModel.levelCount)
    }

    // MARK: Derived state

    /// The microphone is listening right now.
    public var isListening: Bool {
        phase == .listening && !isMuted && (mode == .handsFree || isHoldingToTalk)
    }

    /// The Response of the latest turn, as far as it has arrived.
    public var response: VoiceResponseSnapshot? {
        exchange.flatMap { conversation.voiceResponse(id: $0.responseID) }
    }

    public var lastResponseID: String? { responseIDs.last }

    // MARK: Session

    /// Asks for access, activates the audio session and starts listening.
    public func start() async {
        guard phase == .starting else { return }
        do {
            try await recognizer.authorize()
            guard phase == .starting else { return }
            try audioSession.activate(for: .conversation)
        } catch {
            phase = .failed(VoiceError.from(error).message)
            return
        }
        phase = .listening
        await startRecognizerIfNeeded()
    }

    /// Ends the session: stops listening and speaking. A Response still streaming finishes in
    /// the Chat.
    public func end() {
        guard phase != .ended else { return }
        phase = .ended
        stopRecognizer(discard: true)
        cancelEndOfTurn()
        followTask?.cancel()
        speakTask?.cancel()
        queue.removeAll()
        synthesizer.stop()
        audioSession.deactivate()
    }

    public var duration: TimeInterval {
        max(0, now().timeIntervalSince(startedAt))
    }

    // MARK: Controls

    /// VOICE-05: turns the microphone off or on again.
    public func toggleMute() async {
        guard isActive else { return }
        isMuted.toggle()
        if isMuted {
            cancelEndOfTurn()
            stopRecognizer(discard: true)
            transcript = ""
        } else {
            await startRecognizerIfNeeded()
        }
    }

    /// Switches between Hands free and Push to talk (from Voice settings during the session).
    public func setMode(_ newMode: VoicePreferences.Mode) async {
        guard newMode != mode else { return }
        mode = newMode
        isHoldingToTalk = false
        guard isActive else { return }
        if newMode == .pushToTalk {
            cancelEndOfTurn()
            stopRecognizer(discard: true)
            if phase == .listening { transcript = "" }
        } else {
            await startRecognizerIfNeeded()
        }
    }

    /// VOICE-04: the pill is pressed. Interrupts a Response being spoken and starts listening.
    public func beginTalking() async {
        guard mode == .pushToTalk, isActive, !isHoldingToTalk else { return }
        isHoldingToTalk = true
        if isMuted { isMuted = false }
        if phase == .thinking || phase == .speaking { interrupt() }
        phase = .listening
        transcript = ""
        await startRecognizerIfNeeded()
    }

    /// VOICE-04: the pill is released; what was said is sent.
    public func endTalking() async {
        guard mode == .pushToTalk, isHoldingToTalk else { return }
        isHoldingToTalk = false
        await endTurn()
    }

    /// Voice, speed or language changed in Voice settings during the session: the next sentence
    /// is spoken with `synthesizer`, the next turn is heard in `locale`.
    public func updateSpeech(synthesizer newSynthesizer: any SpeechSynthesizer, locale newLocale: Locale) {
        let previous = synthesizer
        synthesizer = newSynthesizer
        locale = newLocale
        guard previous !== newSynthesizer else { return }
        // A sentence being spoken in the old voice ends; the queue continues in the new one.
        previous.stop()
    }

    public func clearNotice() {
        notice = nil
    }

    private var isActive: Bool {
        switch phase {
        case .listening, .thinking, .speaking: true
        case .starting, .failed, .ended: false
        }
    }

    // MARK: Listening

    /// Whether the recogniser should run in the current state.
    private var wantsRecognizer: Bool {
        guard isActive, !isMuted else { return false }
        switch mode {
        case .handsFree: return true
        case .pushToTalk: return isHoldingToTalk && phase == .listening
        }
    }

    private func startRecognizerIfNeeded() async {
        guard wantsRecognizer, !recognizing else { return }
        recognizing = true
        recognizerGeneration += 1
        let generation = recognizerGeneration
        heardSpeech = false
        do {
            let events = try await recognizer.start(locale: locale)
            guard generation == recognizerGeneration, recognizing else { return }
            listenTask = Task { [weak self] in
                for await event in events {
                    self?.handle(event, generation: generation)
                }
                self?.recognizerEnded(generation: generation)
            }
        } catch {
            guard generation == recognizerGeneration else { return }
            recognizing = false
            let message = VoiceError.from(error).message
            end()
            phase = .failed(message)
        }
    }

    private func stopRecognizer(discard: Bool) {
        guard recognizing else { return }
        recognizing = false
        recognizerGeneration += 1
        listenTask?.cancel()
        listenTask = nil
        if discard { recognizer.cancel() }
    }

    private func handle(_ event: RecognitionEvent, generation: Int) {
        guard generation == recognizerGeneration else { return }
        switch event {
        case .transcript(let text):
            switch phase {
            case .listening:
                guard text != transcript else { return }
                transcript = text
                if !text.isEmpty { activity() }
            case .thinking, .speaking:
                // Barge-in: enough words over the Response interrupt it (Hands free).
                guard mode == .handsFree, Self.wordCount(text) >= bargeInWords else { return }
                interrupt()
                phase = .listening
                transcript = text
                activity()
            case .starting, .failed, .ended:
                break
            }
        case .level(let level):
            recordLevel(level)
            if !recognizer.providesLiveTranscript, phase == .listening, level >= Self.speechLevel {
                heardSpeech = true
                activity()
            }
        }
    }

    /// The recogniser stopped on its own (a limit or an error): end the turn or listen again.
    private func recognizerEnded(generation: Int) {
        guard generation == recognizerGeneration, recognizing else { return }
        recognizing = false
        if phase == .listening, !transcript.isEmpty {
            Task { await endTurn() }
        } else {
            Task { await startRecognizerIfNeeded() }
        }
    }

    private func recordLevel(_ level: Float) {
        let now = ContinuousClock.now
        if let last = lastLevelAt, now - last < .milliseconds(60) { return }
        lastLevelAt = now
        levels.removeFirst()
        levels.append(level)
    }

    /// Speech happened: in Hands free mode the turn ends after `silence` without more.
    private func activity() {
        guard mode == .handsFree else { return }
        cancelEndOfTurn()
        let silence = silence
        endOfTurn = Task { [weak self] in
            try? await Task.sleep(for: silence)
            guard !Task.isCancelled else { return }
            await self?.endTurn()
        }
    }

    private func cancelEndOfTurn() {
        endOfTurn?.cancel()
        endOfTurn = nil
    }

    /// Ends the user's turn: takes the final transcript and sends it.
    private func endTurn() async {
        guard phase == .listening, recognizing, !endingTurn else { return }
        endingTurn = true
        defer { endingTurn = false }
        cancelEndOfTurn()
        recognizing = false
        recognizerGeneration += 1
        listenTask?.cancel()
        listenTask = nil
        let live = transcript
        var text = live
        do {
            let final = try await recognizer.finish()
            if !final.isEmpty { text = final }
        } catch {
            notice = VoiceError.from(error).message
        }
        guard phase == .listening else { return }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            transcript = ""
            await startRecognizerIfNeeded()
            return
        }
        send(text)
        await startRecognizerIfNeeded()
    }

    // MARK: Responding

    private func send(_ text: String) {
        guard let responseID = conversation.sendVoiceMessage(text) else {
            notice = "Couldn't send that. Check your connection and try again."
            transcript = ""
            return
        }
        notice = nil
        transcript = ""
        exchange = Exchange(userText: text, responseID: responseID)
        responseIDs.append(responseID)
        phase = .thinking
        splitter = SentenceSplitter()
        queue.removeAll()
        responseComplete = false
        follow(responseID)
    }

    private func follow(_ responseID: String) {
        followTask?.cancel()
        let conversation = conversation
        followTask = Task { [weak self] in
            let snapshots = Observations { @MainActor in conversation.voiceResponse(id: responseID) }
            for await snapshot in snapshots {
                guard let self, !Task.isCancelled else { return }
                guard let snapshot else { continue }
                self.consume(snapshot)
                if snapshot.isFinished { return }
            }
        }
    }

    private func consume(_ snapshot: VoiceResponseSnapshot) {
        guard phase == .thinking || phase == .speaking, !responseComplete else { return }
        let pieces = splitter.feed(snapshot.text, isFinal: snapshot.isFinished)
        if !pieces.isEmpty {
            queue.append(contentsOf: pieces)
            phase = .speaking
            speakQueued()
        }
        if snapshot.isFinished {
            responseComplete = true
            if let error = snapshot.error, snapshot.text.isEmpty { notice = error }
            if speakTask == nil { finishSpeaking() }
        }
    }

    private func speakQueued() {
        guard speakTask == nil else { return }
        speakTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let piece = self.queue.removeFirst()
                try? await self.synthesizer.speak(piece)
            }
            guard let self, !Task.isCancelled else { return }
            self.speakTask = nil
            if self.responseComplete { self.finishSpeaking() }
        }
    }

    /// The whole Response was spoken: back to the user.
    private func finishSpeaking() {
        guard phase == .speaking || phase == .thinking else { return }
        phase = .listening
        transcript = ""
        // Whatever the recogniser picked up during the Response (below the barge-in threshold)
        // was echo or noise: listen afresh.
        if recognizing {
            stopRecognizer(discard: true)
        }
        Task { await startRecognizerIfNeeded() }
    }

    /// Stops speaking and a Response still streaming (barge-in, push to talk).
    private func interrupt() {
        followTask?.cancel()
        followTask = nil
        speakTask?.cancel()
        speakTask = nil
        queue.removeAll()
        synthesizer.stop()
        if !responseComplete {
            responseComplete = true
            let conversation = conversation
            Task { await conversation.stopVoiceResponse() }
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
    }

    /// Puts the session into a fixed state without audio (previews).
    func applyPreviewState(phase: Phase, transcript: String = "", exchange: Exchange? = nil, muted: Bool = false, levels: [Float]? = nil) {
        self.phase = phase
        self.transcript = transcript
        self.exchange = exchange
        isMuted = muted
        if let levels { self.levels = levels }
        if let exchange { responseIDs = [exchange.responseID] }
    }

    func applyPreviewHolding(_ holding: Bool) {
        isHoldingToTalk = holding
    }
}

/// What the ended-session banner shows (VOICE-07).
public struct VoiceSessionSummary: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let duration: TimeInterval
    public let chatID: String?
    /// The session's last Response, which the banner's thumbs rate.
    public let lastResponseID: String?
    /// Whether the banner shows thumbs (a saved Chat that allows rating).
    public let canRate: Bool

    public init(duration: TimeInterval, chatID: String?, lastResponseID: String?, canRate: Bool = true) {
        self.duration = duration
        self.chatID = chatID
        self.lastResponseID = lastResponseID
        self.canRate = canRate && lastResponseID != nil
    }

    /// "2m 32s", "45s", "1h 3m".
    public var durationText: String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
