import Testing
@testable import VoiceFeature

@Suite("Speaking a streaming Response (VOICE-03)")
struct SentenceSplitterTests {
    @Test func finishedSentencesAreHandedOutAsTheyArrive() {
        var splitter = SentenceSplitter()
        #expect(splitter.feed("Sure! Here's a straight", isFinal: false) == ["Sure!"])
        #expect(splitter.feed("Sure! Here's a straightforward plan. Day", isFinal: false) == ["Here's a straightforward plan."])
        #expect(splitter.feed("Sure! Here's a straightforward plan. Day one", isFinal: false).isEmpty)
        #expect(splitter.feed("Sure! Here's a straightforward plan. Day one: oats.", isFinal: true) == ["Day one: oats."])
        #expect(splitter.feed("Sure! Here's a straightforward plan. Day one: oats.", isFinal: true).isEmpty)
    }

    @Test func markdownIsSpokenAsPlainText() {
        var splitter = SentenceSplitter()
        let text = "**Day One:** Start with *oatmeal* [1].\n\n- Lunch: a [salad](https://x.example).\n"
        #expect(splitter.feed(text, isFinal: false) == ["Day One: Start with oatmeal.\n\nLunch: a salad."])
    }

    @Test func decimalsAndListNumbersDontEndASentence() {
        var splitter = SentenceSplitter()
        #expect(splitter.feed("It costs 3.50 euros", isFinal: false).isEmpty)
        #expect(splitter.feed("It costs 3.50 euros today. Then", isFinal: false) == ["It costs 3.50 euros today."])
        var list = SentenceSplitter()
        #expect(list.feed("Steps:\n1. Boil", isFinal: false) == ["Steps:"])
        #expect(list.feed("Steps:\n1. Boil water.\n2. Add", isFinal: false) == ["Boil water."])
    }

    @Test func codeBlocksAreNeverCutOpenAndNotRead() {
        var splitter = SentenceSplitter()
        let partial = "Try this:\n```swift\nprint(\"a. b\")\n"
        #expect(splitter.feed(partial, isFinal: false) == ["Try this:"])
        let closed = partial + "```\nThat prints it. Done"
        #expect(splitter.feed(closed, isFinal: false) == ["That prints it."])
        #expect(splitter.feed(closed, isFinal: true) == ["Done"])
    }
}
