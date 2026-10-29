public import ChatDomain
public import ChatFeature
public import ComposerFeature
public import Foundation
public import Observation
public import OpenWebUIKit
import SwiftUI

/// The Voice Feature area of one signed-in Account (VOICE-01…07): Dictation into a composer,
/// the Voice mode session, the ended-session banner and Voice settings. `AppFeature` creates one
/// per Account, hands `composerActions(for:)` to the Chat screen through `\.conversationVoice`
/// and applies `.voice(_:)` to the shell (ADR 0081).
@MainActor
@Observable
public final class Voice {
    /// The Dictation intro waiting to be shown before the first Dictation (VOICE-02).
    public struct IntroRequest: Identifiable {
        public let id = UUID()
        let composer: ComposerModel
    }

    public let settings: VoiceSettingsStore
    @ObservationIgnored public let hints: VoiceHints
    @ObservationIgnored let speech: any SpeechProviding
    /// The Dictation recording into a composer right now.
    public private(set) var dictation: DictationModel?
    /// The Voice mode session on screen.
    public private(set) var session: VoiceModeModel?
    /// The banner after a session ended (VOICE-07).
    public var endedSession: VoiceSessionSummary?
    public var intro: IntroRequest?
    /// Rates a Response of a Voice mode session (thumbs on the canvas and the ended banner).
    /// `AppFeature` routes it to the Feedback sheet (MSG-06).
    @ObservationIgnored public var onRate: (@MainActor (any VoiceConversation, String, MessageAnnotation.Rating) -> Void)?
    @ObservationIgnored private var endedConversation: (any VoiceConversation)?
    @ObservationIgnored private var starting: Task<Void, Never>?

    public convenience init(client: OpenWebUIClient, accountKey: String) {
        self.init(
            speech: ScriptedSpeech.fromLaunchArguments(client: client) ?? SpeechStack(client: client),
            settings: VoiceSettingsStore(client: client, accountKey: accountKey),
            hints: VoiceHints(accountKey: accountKey)
        )
    }

    public init(speech: any SpeechProviding, settings: VoiceSettingsStore, hints: VoiceHints) {
        self.speech = speech
        self.settings = settings
        self.hints = hints
    }

    /// The on-device voice the user chose, for Read aloud (MSG-07 → `MessageActions.onDeviceVoiceIdentifier`).
    public var readAloudVoiceIdentifier: String? {
        settings.preferences.voice
    }

    /// The hook for the Chat screen (`\.conversationVoice`).
    public var conversationVoice: ConversationVoice {
        ConversationVoice { [weak self] conversation in
            self?.composerActions(for: conversation) ?? ComposerVoiceActions()
        }
    }

    /// The composer's mic and voice-mode buttons for `conversation`.
    public func composerActions(for conversation: ConversationModel) -> ComposerVoiceActions {
        ComposerVoiceActions(
            dictate: { [weak self] composer in self?.dictate(into: composer) },
            startVoiceMode: { [weak self] in self?.startVoiceMode(in: conversation) },
            dictationBar: { [weak self] composer in
                guard let dictation = self?.dictation, dictation.composer === composer else { return nil }
                return AnyView(DictationBar(model: dictation))
            }
        )
    }

    // MARK: Dictation (VOICE-01, VOICE-02)

    /// The mic was tapped: the intro on first use, then recording.
    public func dictate(into composer: ComposerModel) {
        Task { await settings.load() }
        if hints.hasSeenDictationIntro {
            beginDictation(into: composer)
        } else {
            intro = IntroRequest(composer: composer)
        }
    }

    /// The intro's Continue.
    func finishIntro(_ request: IntroRequest) {
        hints.hasSeenDictationIntro = true
        intro = nil
        beginDictation(into: request.composer)
    }

    func beginDictation(into composer: ComposerModel) {
        dictation?.cancel()
        let speech = speech
        let locale = settings.preferences.locale
        Task { [weak self] in
            let recognizer = await speech.makeRecognizer(for: .dictation)
            guard let self else { return }
            let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: speech.audioSession, locale: locale)
            model.onEnd = { [weak self, weak model] in
                if let model, self?.dictation === model { self?.dictation = nil }
            }
            self.dictation = model
            await model.start()
        }
    }

    // MARK: Voice mode (VOICE-03…05)

    public func startVoiceMode(in conversation: any VoiceConversation) {
        guard session == nil, starting == nil else { return }
        dictation?.cancel()
        endedSession = nil
        let speech = speech
        starting = Task {
            await settings.load()
            let preferences = settings.preferences
            let recognizer = await speech.makeRecognizer(for: .conversation)
            let synthesizer = await speech.makeSynthesizer(preferences: preferences)
            let model = VoiceModeModel(
                conversation: conversation,
                recognizer: recognizer,
                synthesizer: synthesizer,
                audioSession: speech.audioSession,
                preferences: preferences
            )
            session = model
            starting = nil
            await model.start()
        }
    }

    /// Ends the session and shows the banner when anything was said (VOICE-07).
    public func endVoiceMode() {
        guard let session else { return }
        let summary = VoiceSessionSummary(
            duration: session.duration,
            chatID: session.conversation.chatID,
            lastResponseID: session.lastResponseID,
            canRate: session.conversation.canRateVoiceResponses
        )
        session.end()
        self.session = nil
        if summary.lastResponseID != nil {
            endedConversation = session.conversation
            endedSession = summary
        }
    }

    /// Voice settings changed during the session (the gear sheet, VOICE-06).
    func preferencesChanged(from old: VoicePreferences, to new: VoicePreferences) {
        guard let session else { return }
        if old.mode != new.mode {
            Task { await session.setMode(new.mode) }
        }
        if old.voice != new.voice || old.speed != new.speed || old.language != new.language {
            let speech = speech
            Task {
                let synthesizer = await speech.makeSynthesizer(preferences: new)
                session.updateSpeech(synthesizer: synthesizer, locale: new.locale)
            }
        }
    }

    // MARK: Rating (VOICE-07)

    /// Thumbs on a Response of `conversation`.
    func rate(_ responseID: String, _ rating: MessageAnnotation.Rating, in conversation: any VoiceConversation) {
        onRate?(conversation, responseID, rating)
    }

    /// The banner's thumbs: rates the session's last Response.
    public func rateEndedSession(_ rating: MessageAnnotation.Rating) {
        guard let summary = endedSession, summary.canRate, let responseID = summary.lastResponseID, let conversation = endedConversation else { return }
        rate(responseID, rating, in: conversation)
        dismissBanner()
    }

    public func dismissBanner() {
        endedSession = nil
        endedConversation = nil
    }

    /// Stops everything (sign-out, Account switch).
    public func tearDown() {
        dictation?.cancel()
        session?.end()
        session = nil
        starting?.cancel()
        starting = nil
        dismissBanner()
    }
}
