import ComposerFeature
import Foundation
import Testing
@testable import VoiceFeature

@Suite("Dictation (VOICE-01)")
@MainActor
struct DictationTests {
    @Test func liveTranscriptThenConfirmAppendsToTheDraft() async {
        let composer = makeComposer()
        composer.text = "Plan my week."
        let recognizer = FakeRecognizer()
        let audio = FakeAudioSession()
        let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: audio, locale: Locale(identifier: "en-GB"))
        var ended = 0
        model.onEnd = { ended += 1 }

        await model.start()
        #expect(model.phase == .recording)
        #expect(audio.activations == [.dictation])
        #expect(recognizer.starts == [Locale(identifier: "en-GB")])

        recognizer.say("give me a two")
        recognizer.say("tell me how a mouse solves a maze")
        #expect(await until { model.transcript == "tell me how a mouse solves a maze" })
        #expect(composer.text == "Plan my week.", "nothing lands in the composer before confirming")

        recognizer.finalText = "Tell me how a mouse solves a maze."
        await model.confirm()
        #expect(composer.text == "Plan my week. Tell me how a mouse solves a maze.")
        #expect(model.phase == .ended)
        #expect(recognizer.finishes == 1)
        #expect(audio.deactivations == 1)
        #expect(ended == 1)
    }

    @Test func confirmIntoAnEmptyComposerUsesTheLiveTranscriptWhenTheFinalIsEmpty() async {
        let composer = makeComposer()
        let recognizer = FakeRecognizer()
        recognizer.finalText = ""
        let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: FakeAudioSession(), locale: .current)
        await model.start()
        recognizer.say("hello there")
        #expect(await until { model.transcript == "hello there" })
        await model.confirm()
        #expect(composer.text == "hello there")
    }

    @Test func cancelDropsWhatWasHeard() async {
        let composer = makeComposer()
        composer.text = "Draft"
        let recognizer = FakeRecognizer()
        let audio = FakeAudioSession()
        let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: audio, locale: .current)
        await model.start()
        recognizer.say("never mind")
        model.cancel()
        #expect(composer.text == "Draft")
        #expect(recognizer.cancels == 1)
        #expect(model.phase == .ended)
        #expect(audio.deactivations == 1)
    }

    @Test func deniedMicrophoneBecomesTheComposerNotice() async {
        let composer = makeComposer()
        let recognizer = FakeRecognizer()
        recognizer.authorization = .microphoneDenied
        let audio = FakeAudioSession()
        let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: audio, locale: .current)
        await model.start()
        #expect(model.phase == .ended)
        #expect(composer.notice == VoiceError.microphoneDenied.message)
        #expect(audio.activations.isEmpty)
        #expect(recognizer.starts.isEmpty)
    }

    @Test func levelsFeedTheWaveform() async {
        let recognizer = FakeRecognizer()
        let model = DictationModel(composer: makeComposer(), recognizer: recognizer, audioSession: FakeAudioSession(), locale: .current)
        await model.start()
        recognizer.level(0.8)
        #expect(await until { model.levels.last == 0.8 })
        #expect(model.levels.count == DictationModel.levelCount)
    }

    @Test func dictationStopsItselfAfterTheTimeLimit() async {
        let composer = makeComposer()
        let recognizer = FakeRecognizer()
        let model = DictationModel(composer: composer, recognizer: recognizer, audioSession: FakeAudioSession(), locale: .current, maxDuration: .milliseconds(30))
        await model.start()
        recognizer.say("a long story")
        #expect(await until { model.phase == .ended })
        #expect(composer.text == "a long story")
    }

    @Test func theVoiceControllerShowsTheIntroOnceThenRecordsIntoThatComposer() async {
        let defaults = ephemeralDefaults()
        let recognizer = FakeRecognizer()
        let speech = FakeSpeech(recognizer: recognizer)
        let voice = Voice(speech: speech, settings: VoiceSettingsStore(client: nil, accountKey: "a", cache: nil), hints: VoiceHints(accountKey: "a", defaults: defaults))
        let composer = makeComposer()
        let other = makeComposer()

        voice.dictate(into: composer)
        let intro = try? #require(voice.intro)
        #expect(voice.dictation == nil, "the intro comes first (VOICE-02)")
        if let intro { voice.finishIntro(intro) }
        #expect(await until { voice.dictation?.phase == .recording })
        #expect(voice.hints.hasSeenDictationIntro)

        // The recording bar belongs to this composer only.
        #expect(voice.dictation?.composer === composer)
        #expect(voice.dictation?.composer !== other)

        await voice.dictation?.confirm()
        #expect(voice.dictation == nil)

        // Second time: no intro.
        voice.dictate(into: composer)
        #expect(voice.intro == nil)
        #expect(await until { voice.dictation?.phase == .recording })
        voice.dictation?.cancel()
        #expect(voice.dictation == nil)
    }
}
