import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// #173, #185 against recorded streams: replays a scenario's socket events into a `ResponseState`
/// and records the working mouse's plaque after each one.
@Suite("Working mouse in recorded streams")
struct WorkingMouseFixtureTests {
    /// The plaque (or `nil`) after every event of the scenario's first assistant Message; the
    /// stream counts as stalled between events, as it does when the model goes quiet.
    private func plaques(_ scenario: String, stalled: Bool = false) throws -> (seen: [ResponseActivity.Work?], final: ResponseState) {
        let fixture = StreamFixture(scenario)
        let messageID = try fixture.ids().assistantMessageID
        var state = ResponseState()
        var seen: [ResponseActivity.Work?] = []
        for (envelope, ackID) in try fixture.envelopes() {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) where event.messageID == messageID {
                guard case .response(let response) = event.kind else { continue }
                state.apply(response)
                // What lands after the end (follow-ups) doesn't concern the mouse.
                if !state.isFinished { seen.append(ResponseActivity(state).indicator(stalled: stalled)) }
            }
        }
        return (seen, state)
    }

    @Test func anOpenTerminalRunKeepsTheMouseRunning() throws {
        let (seen, final) = try plaques("sandbox")
        #expect(seen.contains(.runningCommand), "the run shows RUNNING COMMAND…")
        #expect(seen.contains(.writingFiles) || seen.contains(.readingFiles), "file steps name themselves")
        #expect(seen.contains(nil), "streamed text hides the mouse")
        #expect(final.isFinished)
        #expect(ResponseActivity(final) == .idle, "a finished Response shows no mouse")
    }

    @Test func aWebSearchShowsSearching() throws {
        let (seen, final) = try plaques("websearch")
        #expect(seen.contains(.webSearch), "the web search shows its globe")
        #expect(ResponseActivity(final).indicator(stalled: true) == nil)
    }

    @Test func aPlainAnswerShowsTheMouseOnlyBeforeTextOrWhenItStalls() throws {
        let (seen, _) = try plaques("plain")
        let firstText = try #require(seen.firstIndex(of: nil))
        #expect(seen[..<firstText].allSatisfy { $0 == .thinking })
        #expect(seen[firstText...].allSatisfy { $0 == nil })

        let (stalled, final) = try plaques("plain", stalled: true)
        #expect(stalled.allSatisfy { $0 == .thinking }, "a quiet stream brings the mouse back")
        #expect(ResponseActivity(final) == .idle)
    }
}
