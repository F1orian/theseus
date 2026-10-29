import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// #195 against recorded streams: at no step do a step row or card and the tail's plaque show a
/// live status at the same time. Either the tail draws the live step row (its title is the
/// plaque), or a card shows the status and the tail has no plaque, or no step is live and the
/// plaque names the work.
@Suite("One live status over recorded streams (#195)")
struct LiveStatusReplayTests {
    /// Open Terminal's tools: the Sandbox hook draws a run of them as cards (OT-02).
    private static let terminalTools: Set<String> = [
        "run_command", "get_process_status", "send_process_input", "kill_process", "list_processes",
        "read_user_terminal", "send_user_terminal_input", "read_file", "list_files", "display_file",
        "write_file", "replace_file_content", "grep_search", "glob_search", "match_files", "search_files",
    ]

    private static func isCard(_ part: ResponsePart) -> Bool {
        if case .tools(_, let tools) = part { return tools.contains { terminalTools.contains($0.name) } }
        return false
    }

    /// Whether a shown part says a step is live (a spinner row's title, a running card).
    private static func isLive(_ part: ResponsePart) -> Bool {
        switch part {
        case .thinking(_, _, _, let streaming, _): streaming
        case .tools(_, let tools): tools.contains(where: \.isRunning)
        case .status(_, let update): !update.isDone
        case .code(_, let execution):
            execution.status?.isActive ?? [execution.stdout, execution.result, execution.stderr].allSatisfy { ($0 ?? "").isEmpty }
        case .text, .answers: false
        }
    }

    private struct Tally {
        var steps = 0
        var rows = 0
        var cards = 0
        var plaques = 0
    }

    private func replay(_ name: String) throws -> Tally {
        let fixture = StreamFixture(name)
        let messageID = try fixture.ids().assistantMessageID
        var state = ResponseState()
        var tally = Tally()
        for (envelope, ackID) in try fixture.envelopes() {
            for event in ChatEventDecoder.decode(envelope, ackID: ackID) {
                guard event.messageID == messageID, case .response(let response) = event.kind else { continue }
                state.apply(response)
                tally.steps += 1
                let parts = state.parts
                let activity = ResponseActivity(state)
                let live = LiveStep(parts: parts, activity: activity, isCard: Self.isCard)
                let work = activity.indicator(stalled: false)
                let plaque = work.flatMap(live.plaque(for:))
                let shownLive = parts.filter { $0.id != live.absorbedPartID && Self.isLive($0) }
                let comment: Comment = "\(name) step \(tally.steps): plaque \(plaque ?? "none"), live parts \(shownLive.map(\.id))"
                if plaque != nil {
                    #expect(shownLive.isEmpty, comment)
                } else {
                    #expect(shownLive.count <= 1, comment)
                }
                switch live {
                case .row(let id, let title):
                    tally.rows += 1
                    #expect(parts.last?.id == id, "the tail draws the last part: \(comment)")
                    #expect(plaque == title + "…" || work == nil, comment)
                case .card:
                    tally.cards += 1
                    #expect(plaque == nil, comment)
                case .none:
                    if plaque != nil { tally.plaques += 1 }
                }
            }
        }
        #expect(state.isFinished, "\(name) finishes")
        return tally
    }

    @Test func interleavedReasoningAndSearch() throws {
        let tally = try replay("interleaved")
        #expect(tally.rows > 0, "Thinking and the searches are drawn by the tail")
        #expect(tally.cards == 0)
    }

    @Test func webSearch() throws {
        let tally = try replay("websearch")
        #expect(tally.steps > 0)
    }

    @Test func sandboxRunsAreCards() throws {
        let tally = try replay("sandbox")
        #expect(tally.cards > 0, "a terminal run shows its own status")
    }

    @Test func reasoning() throws {
        let tally = try replay("reasoning")
        #expect(tally.rows > 0)
    }
}
