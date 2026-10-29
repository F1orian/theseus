import ComposerFeature
import Testing

@Suite("Return to send (PLAT-05)")
struct ComposerReturnKeyTests {
    @Test func aTypedLineBreakIsFound() {
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hello", new: "Hello\n") == "Hello")
        // Typed in the middle (the cursor wasn't at the end).
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hello there", new: "Hello\n there") == "Hello there")
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "", new: "\n") == "")
    }

    @Test func otherEditsAreNotAReturn() {
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hello", new: "Hello!") == nil)
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hello", new: "Hello\n\n") == nil)
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hello\n", new: "Hello") == nil)
        // Pasted text that ends in a line break.
        #expect(ComposerReturnKey.textBeforeTypedReturn(old: "Hi", new: "Hi there\n") == nil)
    }

    @Test func onlyAPlainHardwareReturnSends() {
        #expect(ComposerReturnKey.sends(hardwareKeyboard: true, shift: false))
        #expect(!ComposerReturnKey.sends(hardwareKeyboard: true, shift: true))
        // The on-screen keyboard's Return always types a new line.
        #expect(!ComposerReturnKey.sends(hardwareKeyboard: false, shift: false))
    }
}
