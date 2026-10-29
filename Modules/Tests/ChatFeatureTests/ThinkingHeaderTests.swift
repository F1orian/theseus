@testable import ChatFeature
import ChatDomain
import DesignSystem
import SwiftUI
import Testing

/// #190: Thinking is a quiet step row in the tool rows' style ("Thinking", then "Thought for
/// 12s ›" or "Thought ›"); the Response's one mouse is its tail indicator.
@Suite("Thinking step (#190)")
@MainActor
struct ThinkingStepTests {
    @Test func liveThenTimed() {
        #expect(ThinkingBlock.title(isStreaming: true, duration: nil) == "Thinking")
        #expect(ThinkingBlock.title(isStreaming: true, duration: 3) == "Thinking")
        #expect(ThinkingBlock.title(isStreaming: false, duration: 11.6) == "Thought for 12s")
        // Untimed reasoning (e.g. `<think>` tags, or a part the Server never closed) or under a second.
        #expect(ThinkingBlock.title(isStreaming: false, duration: nil) == "Thought")
        #expect(ThinkingBlock.title(isStreaming: false, duration: 0.4) == "Thought")
    }

    @Test func voiceOverReadsWords() {
        #expect(ThinkingBlock.accessibilityTitle(isStreaming: true, duration: 3) == "Thinking")
        #expect(ThinkingBlock.accessibilityTitle(isStreaming: false, duration: 12) == "Thought for 12 seconds")
        #expect(ThinkingBlock.accessibilityTitle(isStreaming: false, duration: 1) == "Thought for 1 second")
        #expect(ThinkingBlock.accessibilityTitle(isStreaming: false, duration: nil) == "Thought")
    }

    /// While reasoning streams at the tail, the tail indicator ponders (THINKING…): one mouse.
    @Test func theLiveThinkingPondersInTheTailIndicator() {
        var state = ResponseState()
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Hmm"))
        #expect(ResponseActivity(state).indicator(stalled: false) == .thinking)
        #expect(ResponseActivity.Work.thinking.scene == .thinking)
    }
}

/// #185 kept: finishing never moves anything. The live row and the finished row are the same
/// height, and the icon slot holds the spinner and the icon alike.
@Suite("Thinking header doesn't reflow (#185)")
@MainActor
struct ThinkingHeaderTests {
    private func size(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    @Test func theHeaderHeightIsUnchangedAcrossStreamingToFinished() throws {
        let streaming = try size(ThinkingBlock(text: "Hmm", summary: "", isStreaming: true, duration: nil).frame(width: 360, alignment: .leading))
        let finished = try size(ThinkingBlock(text: "Hmm", summary: "", isStreaming: false, duration: 12).frame(width: 360, alignment: .leading))
        let untimed = try size(ThinkingBlock(text: "Hmm", summary: "", isStreaming: false, duration: nil).frame(width: 360, alignment: .leading))
        #expect(streaming.height == finished.height)
        #expect(untimed.height == finished.height)
        #expect(streaming.height > 0)
    }

    /// The row is a quiet step: no taller than the hit target, unlike the old mouse-and-plaque
    /// header, and no working-mouse scene fits in it.
    @Test func theRowIsAQuietStep() throws {
        let row = try size(ThinkingBlock(text: "Hmm", summary: "", isStreaming: false, duration: 4).frame(width: 360, alignment: .leading))
        #expect(row.height <= AccessibilityMetrics.minimumHitTarget + 0.5)
        #expect(ThinkingBlock.iconWidth < WorkingMouse.size(.compact, scale: 2).width, "the icon slot can't hold a mouse scene")
    }
}
