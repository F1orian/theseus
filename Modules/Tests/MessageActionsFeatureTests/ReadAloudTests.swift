@testable import MessageActionsFeature
import OpenWebUIKit
import Testing

@Suite("Read aloud (MSG-07)")
@MainActor
struct ReadAloudTests {
    @Test func markdownBecomesSpeakableText() {
        let markdown = """
        ## Easy rules

        - **Half** your plate = *fruits* & veggies [1]
        - Drink water, see [the guide](https://example.com/guide).
        1. Pick `whole wheat` bread

        ```swift
        print("never read code")
        ```

        > A quote with snake_case_name kept.

        | Meal | Time |
        |------|:----:|
        | Lunch | 12 |

        ---
        Done![image](https://example.com/x.png)
        """
        #expect(SpeechText.plain(from: markdown) == """
        Easy rules.

        Half your plate = fruits & veggies. Drink water, see the guide. Pick whole wheat bread.

        A quote with snake_case_name kept.

        Meal Time. Lunch 12.

        Doneimage
        """)
        #expect(SpeechText.plain(from: "```\nonly code\n```").isEmpty)
    }

    @Test func longTextIsChunkedAtSentenceEnds() {
        let sentence = "This sentence has exactly fifty characters in it. "
        let text = String(repeating: sentence, count: 10).trimmingCharacters(in: .whitespaces) + "\n\nSecond paragraph."
        let chunks = SpeechText.chunks(of: text, limit: 120)
        #expect(chunks.count == 6)
        #expect(chunks.allSatisfy { $0.count <= 120 })
        #expect(chunks.last == "Second paragraph.")
        #expect(chunks.first?.hasSuffix("in it.") == true)
    }

    @Test func engineFollowsTheServerConfig() {
        #expect(ReadAloudEngine.choose(for: nil) == .onDevice)
        #expect(ReadAloudEngine.choose(for: AudioConfig(ttsEngine: nil, ttsVoice: "alloy")) == .onDevice)
        #expect(ReadAloudEngine.choose(for: AudioConfig(ttsEngine: "openai", ttsVoice: "alloy")) == .server(voice: "alloy"))
    }

    @Test func playTogglesToPauseAndBack() async {
        let speech = FakeSpeech()
        let controller = ReadAloudController { speech }
        controller.toggle(messageID: "a1", markdown: "**Blue**")
        #expect(controller.isSpeaking("a1"))
        #expect(await until { speech.isSpeaking })
        #expect(speech.spoken == ["Blue"])

        // Tapping pause stops it.
        controller.toggle(messageID: "a1", markdown: "**Blue**")
        #expect(!controller.isSpeaking("a1"))
        #expect(speech.stopCount == 1)
    }

    @Test func finishingResetsTheIcon() async {
        let speech = FakeSpeech()
        let controller = ReadAloudController { speech }
        controller.toggle(messageID: "a1", markdown: "Blue")
        #expect(await until { speech.isSpeaking })
        speech.finish()
        #expect(await until { controller.speakingMessageID == nil })
    }

    @Test func readingAnotherMessageStopsTheFirst() async {
        let first = FakeSpeech()
        let second = FakeSpeech()
        var outputs: [FakeSpeech] = [first, second]
        let controller = ReadAloudController { outputs.removeFirst() }
        controller.toggle(messageID: "a1", markdown: "One")
        #expect(await until { first.isSpeaking })
        controller.toggle(messageID: "a2", markdown: "Two")
        #expect(first.stopCount == 1)
        #expect(controller.isSpeaking("a2"))
        #expect(await until { second.isSpeaking })
        // The first reading finishing late doesn't clear the second's state.
        #expect(controller.speakingMessageID == "a2")
    }

    @Test func failuresAreReported() async {
        let speech = FakeSpeech()
        speech.failure = OpenWebUIError.server(status: 404, detail: nil)
        let controller = ReadAloudController { speech }
        controller.toggle(messageID: "a1", markdown: "Blue")
        #expect(await until { controller.lastError != nil })
        #expect(controller.speakingMessageID == nil)
        controller.clearError()
        #expect(controller.lastError == nil)
    }

    @Test func emptyTextIsNotRead() {
        let speech = FakeSpeech()
        let controller = ReadAloudController { speech }
        controller.toggle(messageID: "a1", markdown: "```\ncode\n```")
        #expect(controller.speakingMessageID == nil)
    }

    @Test func fallbackSpeaksOnDeviceWhenTheServerFails() async throws {
        let server = FakeSpeech()
        server.failure = OpenWebUIError.server(status: 404, detail: nil)
        let device = FakeSpeech()
        let output = FallbackSpeechOutput(primary: server, fallback: device)
        let task = Task { try await output.speak("Blue") }
        #expect(await until { device.isSpeaking })
        #expect(device.spoken == ["Blue"])
        device.finish()
        try await task.value
    }
}
