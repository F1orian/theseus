import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
@testable import SandboxFeature
import Testing

/// Sandbox steps from the recorded `sandbox` scenario (OT-02, OT-03): a file write, three runs
/// (one failing), a background run polled until done, an edit and two displayed files.
@Suite("Sandbox steps")
struct SandboxLogTests {
    let fixture = StreamFixture("sandbox")

    private func storedChat() throws -> Chat {
        try Endpoint<ChatDocument>.chat(id: "c").decode(fixture.data("chat.final.json")).chat
    }

    private func activities(_ state: ResponseState) -> [ToolActivity] {
        state.parts.flatMap { part -> [ToolActivity] in
            if case .tools(_, let tools) = part { return tools }
            return []
        }
    }

    private func storedLog(turn: Int) throws -> (SandboxLog, [ToolActivity]) {
        let ids = try fixture.ids()
        let message = try #require(try storedChat().tree[ids.allTurns[turn].assistant])
        let all = activities(message.response)
        return (SandboxLog(all), all)
    }

    private func runs(_ log: SandboxLog, _ activities: [ToolActivity]) -> [SandboxRun] {
        activities.compactMap { activity in
            if case .run(let run)? = log[activity.id] { return run }
            return nil
        }
    }

    @Test func runsShowCommandOutputAndExitStatus() throws {
        let (log, all) = try storedLog(turn: 0)
        let runs = runs(log, all)
        #expect(runs.map(\.command) == ["ls -la theseus-test", "python3 -c 'print(2+2)'", "ls theseus-test/missing.txt"])
        #expect(runs.allSatisfy { !$0.isRunning })

        let listing = runs[0]
        #expect(listing.exitCode == 0 && !listing.failed)
        #expect(listing.output.contains("hello.txt"))
        #expect(!listing.output.contains("\r"), "PTY line endings are normalised")
        #expect(runs[1].output.trimmingCharacters(in: .whitespacesAndNewlines) == "4")

        let missing = runs[2]
        #expect(missing.exitCode == 2)
        #expect(missing.failed)
        #expect(missing.output.contains("No such file"))
    }

    @Test func fileWritesAndDisplayedFilesBecomeLinesAndCards() throws {
        let (log, all) = try storedLog(turn: 0)
        let steps = all.compactMap { log[$0.id] }
        guard case .file(let write)? = steps.first else {
            Issue.record("expected the write first: \(steps)")
            return
        }
        #expect(write.title == "Created hello.txt")
        #expect(write.size == 2)
        #expect(write.path == "/home/user/theseus-test/hello.txt")

        guard case .display(let file)? = steps.last else {
            Issue.record("expected the displayed file last")
            return
        }
        #expect(file.name == "hello.txt")
        #expect(file.path == "/home/user/theseus-test/hello.txt")
        #expect(file.terminalID == "demo-sandbox")
        #expect(try file.sessionID == fixture.ids().chatID)
        #expect(file.mimeType == "text/plain")
        #expect(file.typeBadge == "TXT")
    }

    @Test func aPolledRunFoldsIntoOneCard() throws {
        let (log, all) = try storedLog(turn: 1)
        let started = try #require(all.first { $0.name == "run_command" })
        let poll = try #require(all.first { $0.name == "get_process_status" })
        guard case .run(let run)? = log[started.id], case .folded(let runID)? = log[poll.id] else {
            Issue.record("the poll didn't fold into the run")
            return
        }
        #expect(runID == started.id)
        #expect(run.status == .done)
        #expect(run.exitCode == 0)
        #expect(run.output == "tick 1\ntick 2\ntick 3\n")

        let edit = try #require(all.first { $0.name == "replace_file_content" })
        guard case .file(let step)? = log[edit.id] else { Issue.record("no edit line"); return }
        #expect(step.title == "Edited planets.csv")
        #expect(step.size == 42)
        guard case .display(let csv)? = all.last.flatMap({ log[$0.id] }) else { Issue.record("no card"); return }
        #expect(csv.name == "planets.csv")
        #expect(csv.mimeType == "text/csv")
    }

    @Test func theLiveStreamRendersLikeTheStoredChat() throws {
        let ids = try fixture.ids()
        for turn in ids.allTurns {
            var state = ResponseState()
            for (envelope, ackID) in try fixture.envelopes() {
                for event in ChatEventDecoder.decode(envelope, ackID: ackID) where event.messageID == turn.assistant {
                    if case .response(let response) = event.kind { state.apply(response) }
                }
            }
            let stored = try #require(try storedChat().tree[turn.assistant])
            #expect(SandboxLog(activities(state)) == SandboxLog(activities(stored.response)))
        }
    }

    /// ADR 0173: only Responses that ran in the sandbox count against the free allowance.
    @Test func everyRecordedSandboxTurnCountsAsUsingTheSandbox() throws {
        let ids = try fixture.ids()
        for turn in ids.allTurns {
            let stored = try #require(try storedChat().tree[turn.assistant])
            #expect(Sandbox.usedSandbox(stored.response))
        }
        #expect(!Sandbox.usedSandbox(ResponseState()))
    }

    @Test func aRunStillWaitingShowsAsRunning() {
        let running = ToolActivity(id: "c1", name: "run_command", arguments: #"{"command":"sleep 5"}"#, isRunning: true)
        guard case .run(let run)? = SandboxLog([running])["c1"] else { Issue.record("no run"); return }
        #expect(run.isRunning)
        #expect(run.headline == "sleep 5")
    }

    @Test func aBackgroundRunPolledTwiceAppendsFromItsOffset() {
        let start = ToolActivity(
            id: "c1", name: "run_command", arguments: #"{"command":"make","wait":0}"#, isRunning: false,
            result: #"{"id":"p1","status":"running","exit_code":null,"output":[{"type":"stdout","data":"a\n"}],"next_offset":1}"#
        )
        let first = ToolActivity(
            id: "c2", name: "get_process_status", arguments: #"{"process_id":"p1","offset":1}"#, isRunning: false,
            result: #"{"id":"p1","status":"running","output":[{"type":"stdout","data":"b\n"}],"next_offset":2}"#
        )
        let second = ToolActivity(
            id: "c3", name: "get_process_status", arguments: #"{"process_id":"p1","offset":2}"#, isRunning: false,
            result: #"{"id":"p1","status":"done","exit_code":1,"output":[{"type":"stderr","data":"\u001b[31mboom\u001b[0m\r\n"}],"next_offset":3}"#
        )
        let log = SandboxLog([start, first, second])
        guard case .run(let run)? = log["c1"] else { Issue.record("no run"); return }
        #expect(run.output == "a\nb\nboom\n")
        #expect(run.chunks.last?.isError == true)
        #expect(run.exitCode == 1 && run.failed)
        #expect(log["c3"] == .folded(runID: "c1"))
    }

    @Test func errorsFromTheTerminalShowAsFailures() {
        let run = ToolActivity(id: "c1", name: "run_command", arguments: #"{"command":"x"}"#, isRunning: false, failed: true, result: "Error: HTTP 403")
        guard case .run(let failed)? = SandboxLog([run])["c1"] else { Issue.record("no run"); return }
        #expect(failed.status == .failed("Error: HTTP 403"))
        let missing = ToolActivity(id: "c2", name: "display_file", arguments: #"{"path":"/x.txt"}"#, isRunning: false, result: #"{"path":"/x.txt","exists":false}"#)
        guard case .file(let step)? = SandboxLog([missing])["c2"] else { Issue.record("no step"); return }
        #expect(step.failed)
    }

    @Test func otherToolsAreLeftToTheStatusLine() {
        let search = ToolActivity(id: "w", name: "search_web", arguments: #"{"query":"x"}"#, isRunning: false)
        let write = ToolActivity(id: "f", name: "write_file", arguments: #"{"path":"a.md"}"#, isRunning: false, result: #"{"path":"/home/user/a.md","size":3}"#)
        let log = SandboxLog([search, write])
        #expect(log["w"] == nil)
        let segments = SandboxToolSteps.segments([search, write], log: log)
        #expect(segments.map(\.id) == ["tools-w", "f"])
    }
}
