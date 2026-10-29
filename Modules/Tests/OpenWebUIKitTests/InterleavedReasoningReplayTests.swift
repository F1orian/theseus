import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// #190 against a real stream: `interleaved` (claude-sonnet-5-5, reasoning effort high, web
/// search) is reasoning → text → search → reasoning → text → fetch → reasoning → search →
/// reasoning → text. The Server leaves the third reasoning item `in_progress` (a tool call
/// follows it directly, so no `output_item.done` closes it) until the Response ends.
@Suite("One mouse over a recorded interleaved stream (#190)")
struct InterleavedReasoningReplayTests {
    @Test func everyStepHasOneIndicatorAndOnlyTheTailThinks() throws {
        let fixture = StreamFixture("interleaved")
        let messageID = try fixture.ids().assistantMessageID
        var state = ResponseState()
        var works: [ResponseActivity.Work] = []
        var sawSupersededInProgress = false
        var steps = 0
        for (envelope, ackID) in try fixture.envelopes() {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) {
                guard event.messageID == messageID, case .response(let response) = event.kind else { continue }
                state.apply(response)
                steps += 1
                let parts = state.parts
                let thinking = parts.enumerated().compactMap { index, part -> (index: Int, streaming: Bool)? in
                    if case .thinking(_, _, _, let streaming, _) = part { return (index, streaming) }
                    return nil
                }
                let streaming = thinking.filter(\.streaming)
                #expect(streaming.count <= 1, "step \(steps): one live Thinking part at most")
                #expect(streaming.allSatisfy { $0.index == parts.count - 1 }, "step \(steps): only the tail thinks")

                // A reasoning item still `in_progress` with a later item after it: the bug's trigger.
                if let last = state.output.indices.last,
                   state.output.indices.dropLast().contains(where: { index in
                       if case .reasoning(let item) = state.output[index] { return item.status == .inProgress && index < last }
                       return false
                   }) {
                    sawSupersededInProgress = true
                }

                let activity = ResponseActivity(state)
                if state.isFinished {
                    #expect(activity.indicator(stalled: true) == nil)
                } else {
                    // The one indicator is always there but while text streams (then it waits for a stall).
                    let indicator = activity.indicator(stalled: false)
                    #expect(indicator != nil || activity == .streamingText, "step \(steps)")
                    #expect(activity.indicator(stalled: true) != nil, "step \(steps)")
                    if let indicator, works.last != indicator { works.append(indicator) }
                }
            }
        }
        #expect(sawSupersededInProgress, "the recording holds a reasoning item the Server never closed mid-stream")
        #expect(state.isFinished)
        // The latest Work, step by step: think, search, think, read, think, search, think.
        let tools = works.filter { $0 != .thinking }
        #expect(tools.first == .webSearch)
        #expect(tools.contains { if case .readingPage = $0 { true } else { false } })
        #expect(tools.last == .webSearch)
        #expect(works.first == .thinking)
        #expect(works.last == .thinking)
        let thinkingParts = state.parts.filter { if case .thinking = $0 { true } else { false } }
        #expect(thinkingParts.count >= 3)
        #expect(thinkingParts.allSatisfy { if case .thinking(_, _, _, let streaming, _) = $0 { !streaming } else { false } })
    }
}
