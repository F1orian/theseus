#if canImport(AppKit)
import AppKit
@testable import ChatFeature
import ChatDomain
import DesignSystem
import SwiftUI
import Testing

/// #195 on screen: a live step shows once. The tail mouse draws a live step row (no spinner row
/// above it); finished, the row is back as the quiet row and the tail moves on.
@Suite("One live status on screen (#195)")
@MainActor
struct LiveStepViewTests {
    private static let width: CGFloat = 393

    private func render(_ state: ResponseState, toolSteps: (([ToolActivity]) -> AnyView?)? = nil) throws -> Pixels {
        let view = ResponseView(state: state, showsSources: true, showsStatus: true, onRetry: nil, toolSteps: toolSteps)
            .padding(16)
            .frame(width: Self.width, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return Pixels(image, points: CGSize(width: Double(image.width) / 2, height: Double(image.height) / 2))
    }

    /// The drawn rows, top to bottom: runs of pixel rows with ink, split by at least 6 pt of white.
    private func rows(_ pixels: Pixels) -> [ClosedRange<Int>] {
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var lastInk = -100
        let gap = Int(6 * pixels.scale)
        for y in 0..<pixels.height {
            var ink = false
            for x in stride(from: 0, to: pixels.width, by: 2) where pixels.darkness(x, y) > 0.08 {
                ink = true
                break
            }
            guard ink else { continue }
            if let begin = start, y - lastInk > gap {
                bands.append(begin...lastInk)
                start = y
            } else if start == nil {
                start = y
            }
            lastInk = y
        }
        if let start { bands.append(start...lastInk) }
        return bands
    }

    private func call(_ id: String, _ name: String, arguments: String = "{}") -> OutputItem {
        .toolCall(ToolCall(id: id, callID: id, name: name, arguments: arguments, status: .inProgress))
    }

    @Test func aRunningSearchIsOneRowTheTail() throws {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "search_web", arguments: #"{"query":"mice"}"#)))
        #expect(rows(try render(state)).count == 1, "the tail draws the live row; no spinner row above it")

        // Finished: the quiet row is back above the tail, which thinks.
        state.apply(.itemAdded(outputIndex: 1, item: .toolResult(ToolResult(id: "fco-c1", callID: "c1", output: ["{}"], status: .completed))))
        #expect(rows(try render(state)).count == 2)
    }

    @Test func streamingThinkingIsOneRowTheTail() throws {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .reasoning(ReasoningOutput(id: "r1", status: .inProgress))))
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Hmm"))
        #expect(rows(try render(state)).count == 1)
    }

    /// A card (a hook's view, here a stand-in for an Open Terminal run) keeps its own status.
    @Test func aLiveCardKeepsItsRowAndTheTail() throws {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: call("c1", "run_command", arguments: #"{"command":"ls"}"#)))
        let pixels = try render(state) { _ in AnyView(Text("Running ls").font(.body)) }
        #expect(rows(pixels).count == 2, "the card, and the tail mouse without a plaque")
    }

    @Test func aRunningStepDropsItsSpinnerWhileTheTailIsUp() {
        #expect(StepStatusIcon.mark(isRunning: true, systemImage: "globe", tailShowsStatus: false, reduceMotion: false) == .spinner)
        #expect(StepStatusIcon.mark(isRunning: true, systemImage: "globe", tailShowsStatus: true, reduceMotion: false) == .icon("globe"))
        // Reduce Motion: a still status mark in its place.
        #expect(StepStatusIcon.mark(isRunning: true, systemImage: "globe", tailShowsStatus: true, reduceMotion: true) == .icon("hourglass"))
        #expect(StepStatusIcon.mark(isRunning: false, systemImage: "globe", tailShowsStatus: true, reduceMotion: true) == .icon("globe"))
    }

    /// The live row's details open under the tail, as under the finished row.
    @Test func theTailOpensTheLiveStepsDetails() throws {
        func height(expanded: Bool) throws -> Int {
            let tools = [ToolActivity(id: "c1", name: "search_web", arguments: #"{"query":"micromouse rules"}"#, isRunning: true)]
            let details = WorkingIndicator.Details(isExpanded: .constant(expanded), shows: "Shows the steps", hides: "Hides the steps") {
                ToolStepDetails(tools: tools)
            }
            let view = WorkingIndicator(work: .webSearch, plaque: "Searching the web…", details: details)
                .frame(width: 360, alignment: .leading)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            return try #require(renderer.cgImage).height
        }
        #expect(try height(expanded: true) > height(expanded: false) + 10)
    }
}
#endif
