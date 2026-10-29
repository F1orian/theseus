import ChatDomain
import Foundation
import Testing
@testable import VoiceFeature

@MainActor
struct VoiceModeHarness {
    let conversation = FakeConversation()
    let recognizer = FakeRecognizer()
    let synthesizer = FakeSynthesizer()
    let audio = FakeAudioSession()
    let model: VoiceModeModel

    init(mode: VoicePreferences.Mode = .handsFree, language: String? = "en-GB", silence: Duration = .milliseconds(40)) {
        model = VoiceModeModel(
            conversation: conversation,
            recognizer: recognizer,
            synthesizer: synthesizer,
            audioSession: audio,
            preferences: VoicePreferences(language: language, mode: mode),
            silence: silence
        )
    }

    /// Says `text` and waits until the turn was sent.
    func speakTurn(_ text: String) async -> Bool {
        let count = conversation.sent.count
        recognizer.say(text)
        return await until { conversation.sent.count == count + 1 }
    }
}

@Suite("Voice mode (VOICE-03, VOICE-05)")
@MainActor
struct VoiceModeTests {
    @Test func handsFreeTurnIsSentAfterAPauseAndTheResponseIsSpokenSentenceBySentence() async {
        let harness = VoiceModeHarness()
        let model = harness.model
        await model.start()
        #expect(model.phase == .listening)
        #expect(model.isListening)
        #expect(harness.audio.activations == [.conversation])
        #expect(harness.recognizer.starts == [Locale(identifier: "en-GB")])

        harness.recognizer.say("tell me how a mouse")
        #expect(await until { model.transcript == "tell me how a mouse" })
        #expect(harness.conversation.sent.isEmpty, "still talking")
        harness.recognizer.say("tell me how a mouse solves a maze")
        #expect(await until { harness.conversation.sent == ["tell me how a mouse solves a maze"] })
        #expect(model.phase == .thinking)
        #expect(model.exchange?.userText == "tell me how a mouse solves a maze")
        #expect(model.transcript.isEmpty)
        // Hands free keeps listening while the model answers, for barge-in.
        #expect(await until { harness.recognizer.starts.count == 2 })

        harness.conversation.stream("response-1", "Sure! Here's a **simple** plan. Day")
        #expect(await until { harness.synthesizer.spoken == ["Sure! Here's a simple plan."] })
        #expect(model.phase == .speaking)
        harness.conversation.stream("response-1", "Sure! Here's a **simple** plan. Day one: oats.", finished: true)
        harness.synthesizer.finishSpeaking()
        #expect(await until { harness.synthesizer.spoken == ["Sure! Here's a simple plan.", "Day one: oats."] })
        harness.synthesizer.finishSpeaking()
        #expect(await until { model.phase == .listening })
        #expect(model.response?.text.hasSuffix("oats.") == true)
        #expect(model.responseIDs == ["response-1"])
        // Listening afresh for the next turn.
        #expect(await until { harness.recognizer.isRunning })
        #expect(await harness.speakTurn("thanks"))
    }

    @Test func talkingOverTheResponseInterruptsIt() async {
        let harness = VoiceModeHarness()
        let model = harness.model
        await model.start()
        #expect(await harness.speakTurn("tell me a long story"))
        harness.conversation.stream("response-1", "Once upon a time. There was")
        #expect(await until { harness.synthesizer.isSpeaking })

        // One word (or echo) isn't enough.
        harness.recognizer.say("hmm")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .speaking)
        #expect(harness.synthesizer.stops == 0)

        harness.recognizer.say("wait stop")
        #expect(await until { model.phase == .listening })
        #expect(harness.synthesizer.stops == 1)
        #expect(await until { harness.conversation.stops == 1 }, "the streaming Response is stopped too")
        #expect(model.transcript == "wait stop")

        // The interruption becomes the next turn.
        harness.recognizer.say("wait stop, shorter please")
        #expect(await until { harness.conversation.sent.last == "wait stop, shorter please" })
    }

    @Test func mutingTurnsTheMicrophoneOffButKeepsSpeaking() async {
        let harness = VoiceModeHarness()
        let model = harness.model
        await model.start()
        #expect(await harness.speakTurn("hello"))
        harness.conversation.stream("response-1", "Hi there! How can I help?", finished: true)
        #expect(await until { harness.synthesizer.isSpeaking })

        await model.toggleMute()
        #expect(model.isMuted)
        #expect(!harness.recognizer.isRunning)
        #expect(harness.synthesizer.stops == 0, "the Response is still spoken")
        harness.synthesizer.finishSpeaking()
        #expect(await until { model.phase == .listening })
        #expect(!model.isListening)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!harness.recognizer.isRunning, "stays off while muted")

        await model.toggleMute()
        #expect(!model.isMuted)
        #expect(harness.recognizer.isRunning)
        #expect(model.isListening)
    }

    @Test func aTurnThatCantBeSentSaysSoAndListensAgain() async {
        let harness = VoiceModeHarness()
        harness.conversation.canSendVoiceMessage = false
        let model = harness.model
        await model.start()
        harness.recognizer.say("are you there")
        #expect(await until { model.notice != nil })
        #expect(model.phase == .listening)
        #expect(await until { harness.recognizer.isRunning })
    }

    @Test func silenceWithoutWordsDoesNothing() async {
        let harness = VoiceModeHarness()
        await harness.model.start()
        harness.recognizer.level(0.9)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.conversation.sent.isEmpty)
        #expect(harness.recognizer.finishes == 0)
    }

    @Test func serverTranscriptionEndsTheTurnOnMicrophoneSilence() async {
        let harness = VoiceModeHarness()
        harness.recognizer.providesLiveTranscript = false
        harness.recognizer.finalText = "what's the weather"
        await harness.model.start()
        harness.recognizer.level(0.8)
        #expect(await until { harness.conversation.sent == ["what's the weather"] })
    }

    @Test func deniedPermissionFailsTheSession() async {
        let harness = VoiceModeHarness()
        harness.recognizer.authorization = .speechRecognitionDenied
        await harness.model.start()
        #expect(harness.model.phase == .failed(VoiceError.speechRecognitionDenied.message))
        #expect(harness.audio.activations.isEmpty)
    }

    @Test func endingStopsEverything() async {
        let harness = VoiceModeHarness()
        let model = harness.model
        await model.start()
        #expect(await harness.speakTurn("hello"))
        harness.conversation.stream("response-1", "Hi! I'm", finished: false)
        #expect(await until { harness.synthesizer.isSpeaking })
        model.end()
        #expect(model.phase == .ended)
        #expect(harness.synthesizer.stops == 1)
        #expect(!harness.recognizer.isRunning)
        #expect(harness.audio.deactivations == 1)
        #expect(harness.conversation.stops == 0, "the Response finishes in the Chat")
    }
}

@Suite("Push to talk (VOICE-04)")
@MainActor
struct PushToTalkTests {
    @Test func holdingListensAndReleasingSends() async {
        let harness = VoiceModeHarness(mode: .pushToTalk)
        let model = harness.model
        await model.start()
        #expect(model.phase == .listening)
        #expect(!model.isListening, "nothing is heard until the pill is held")
        #expect(harness.recognizer.starts.isEmpty)

        await model.beginTalking()
        #expect(model.isHoldingToTalk)
        #expect(model.isListening)
        harness.recognizer.say("what's on my calendar")
        #expect(await until { model.transcript == "what's on my calendar" })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.conversation.sent.isEmpty, "a pause doesn't end a push-to-talk turn")

        await model.endTalking()
        #expect(harness.conversation.sent == ["what's on my calendar"])
        #expect(model.phase == .thinking)
        #expect(!harness.recognizer.isRunning, "no barge-in listening in push to talk")
    }

    @Test func holdingWhileTheResponseIsSpokenInterruptsIt() async {
        let harness = VoiceModeHarness(mode: .pushToTalk)
        let model = harness.model
        await model.start()
        await model.beginTalking()
        harness.recognizer.say("tell me a joke")
        #expect(await until { model.transcript == "tell me a joke" })
        await model.endTalking()
        harness.conversation.stream("response-1", "Why did the chicken cross the road? To get", finished: false)
        #expect(await until { harness.synthesizer.isSpeaking })

        await model.beginTalking()
        #expect(harness.synthesizer.stops == 1)
        #expect(await until { harness.conversation.stops == 1 })
        #expect(model.phase == .listening)
        #expect(model.isListening)
    }

    @Test func switchingModesDuringTheSession() async {
        let harness = VoiceModeHarness()
        let model = harness.model
        await model.start()
        #expect(harness.recognizer.isRunning)
        await model.setMode(.pushToTalk)
        #expect(!harness.recognizer.isRunning)
        #expect(!model.isListening)
        await model.setMode(.handsFree)
        #expect(harness.recognizer.isRunning)
    }
}

@Suite("Voice chat ended (VOICE-07)")
@MainActor
struct VoiceEndedTests {
    @Test func endingShowsTheBannerAndItsThumbsRateTheLastResponse() async throws {
        let speech = FakeSpeech()
        speech.synthesizer.autoFinish = true
        let voice = Voice(speech: speech, settings: VoiceSettingsStore(client: nil, accountKey: "a", cache: nil), hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        let conversation = FakeConversation()
        voice.startVoiceMode(in: conversation)
        #expect(await until { voice.session?.phase == .listening })
        let session = try #require(voice.session)

        speech.recognizer.say("hello")
        #expect(await until { conversation.sent == ["hello"] })
        conversation.stream("response-1", "Hi!", finished: true)
        #expect(await until { session.phase == .listening && speech.synthesizer.spoken == ["Hi!"] })

        voice.endVoiceMode()
        #expect(voice.session == nil)
        let summary = try #require(voice.endedSession)
        #expect(summary.lastResponseID == "response-1")
        #expect(summary.chatID == "chat-1")
        #expect(speech.session.deactivations == 1)

        var rated: [(String, MessageAnnotation.Rating)] = []
        voice.onRate = { _, id, rating in rated.append((id, rating)) }
        voice.rateEndedSession(.good)
        #expect(rated.map(\.0) == ["response-1"])
        #expect(rated.map(\.1) == [.good])
        #expect(voice.endedSession == nil, "rating dismisses the banner")
    }

    @Test func incognitoSessionsCantBeRated() async throws {
        let speech = FakeSpeech()
        speech.synthesizer.autoFinish = true
        let voice = Voice(speech: speech, settings: VoiceSettingsStore(client: nil, accountKey: "a", cache: nil), hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        let conversation = FakeConversation()
        conversation.chatID = nil
        conversation.canRateVoiceResponses = false
        voice.startVoiceMode(in: conversation)
        #expect(await until { voice.session?.phase == .listening })
        speech.recognizer.say("hello")
        #expect(await until { conversation.sent == ["hello"] })
        voice.endVoiceMode()
        let summary = try #require(voice.endedSession)
        #expect(!summary.canRate)
        var rated = 0
        voice.onRate = { _, _, _ in rated += 1 }
        voice.rateEndedSession(.good)
        #expect(rated == 0)
    }

    @Test func noBannerWhenNothingWasSaid() async {
        let voice = Voice(speech: FakeSpeech(), settings: VoiceSettingsStore(client: nil, accountKey: "a", cache: nil), hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        voice.startVoiceMode(in: FakeConversation())
        #expect(await until { voice.session?.phase == .listening })
        voice.endVoiceMode()
        #expect(voice.endedSession == nil)
    }

    @Test func voiceModeUsesTheAccountsVoiceSettings() async {
        let speech = FakeSpeech()
        let settings = VoiceSettingsStore(client: nil, accountKey: "a", cache: nil)
        settings.update {
            $0.voice = "daniel"
            $0.speed = .fast
            $0.mode = .pushToTalk
            $0.language = "de-DE"
        }
        let voice = Voice(speech: speech, settings: settings, hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        voice.startVoiceMode(in: FakeConversation())
        #expect(await until { voice.session?.phase == .listening })
        #expect(speech.synthesizerPreferences.last?.voice == "daniel")
        #expect(speech.synthesizerPreferences.last?.speed == .fast)
        #expect(voice.session?.mode == .pushToTalk)
        await voice.session?.beginTalking()
        #expect(speech.recognizer.starts.last == Locale(identifier: "de-DE"))
    }

    @Test func changingVoiceSettingsDuringTheSessionApplies() async throws {
        let speech = FakeSpeech()
        let settings = VoiceSettingsStore(client: nil, accountKey: "a", cache: nil)
        let voice = Voice(speech: speech, settings: settings, hints: VoiceHints(accountKey: "a", defaults: ephemeralDefaults()))
        let conversation = FakeConversation()
        voice.startVoiceMode(in: conversation)
        #expect(await until { voice.session?.phase == .listening })
        let session = try #require(voice.session)

        let old = settings.preferences
        settings.update {
            $0.speed = .slow
            $0.voice = "karen"
            $0.mode = .pushToTalk
        }
        voice.preferencesChanged(from: old, to: settings.preferences)
        #expect(await until { speech.synthesizerPreferences.last?.voice == "karen" && session.mode == .pushToTalk })
        #expect(speech.synthesizerPreferences.last?.speed == .slow)
    }

    @Test func durationsReadNaturally() {
        #expect(VoiceSessionSummary(duration: 45, chatID: nil, lastResponseID: nil).durationText == "45s")
        #expect(VoiceSessionSummary(duration: 152, chatID: nil, lastResponseID: nil).durationText == "2m 32s")
        #expect(VoiceSessionSummary(duration: 3_780, chatID: nil, lastResponseID: nil).durationText == "1h 3m")
    }
}
