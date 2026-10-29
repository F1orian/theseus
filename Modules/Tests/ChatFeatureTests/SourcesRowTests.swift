#if canImport(AppKit)
import AppKit
@testable import ChatFeature
import ChatDomain
import DesignSystem
import Observation
import SwiftUI
import Testing

/// #191: while a live Response's parts arrive, the Sources pill slid over the tail and the step
/// rows, drawn as an empty icon-only capsule with its label elsewhere. The rows' positions
/// animate (a part arrived), but the pill's label changed in a later, unanimated update (a source
/// arrived), so the label jumped to its new place while the capsule and icon were still on their
/// way, and the new rows faded in where the pill and tail were still passing. Every row now moves
/// as one piece (`geometryGroup`) and a new part fades in once the rows below have made room.
@Suite("The Sources row keeps clear (#191)", .serialized)
@MainActor
struct SourcesRowTests {
    private static let size = CGSize(width: 393, height: 560)
    /// The pill's fill in light mode (`Palette.recessedSurface`).
    private static let fill = (r: 0xE7, g: 0xE8, b: 0xE4)
    private static let left: CGFloat = 16

    private static func source(_ number: Int) -> Source {
        Source(id: "https://site\(number).example.com/page", name: "Site \(number)", kind: "web_search", url: "https://site\(number).example.com/page")
    }

    private static func call(_ id: String, _ name: String, arguments: String = "{}") -> OutputItem {
        .toolCall(ToolCall(id: id, callID: id, name: name, arguments: arguments, status: .inProgress))
    }

    private static func result(_ id: String) -> OutputItem {
        .toolResult(ToolResult(id: "fco-\(id)", callID: id, output: ["{}"], status: .completed))
    }

    /// Where the pill is in a frame and whether it's whole and clear of its neighbours.
    private struct Pill {
        var rows: ClosedRange<Int>?
        var groups = 0
        var labelInk = 0.0
        var touching = false
    }

    private static func pill(in pixels: Pixels) -> Pill {
        let x0 = Int(left * pixels.scale), x1 = Int((left + 150) * pixels.scale)
        func isFill(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = pixels.rgb(x, y)
            return abs(r - fill.r) <= 3 && abs(g - fill.g) <= 3 && abs(b - fill.b) <= 3
        }
        var capsuleRows: [Int] = []
        for y in 0..<pixels.height {
            var count = 0
            for x in stride(from: x0, to: x1, by: 1) where isFill(x, y) { count += 1 }
            if Double(count) >= 0.4 * Double(x1 - x0) { capsuleRows.append(y) }
        }
        var result = Pill()
        guard let first = capsuleRows.first, let last = capsuleRows.last else { return result }
        result.groups = 1 + zip(capsuleRows, capsuleRows.dropFirst()).filter { $1 - $0 > 1 }.count
        result.rows = first...last
        // The label: dark pixels inside the capsule, right of the icon.
        let labelRect = CGRect(x: left + 34, y: Double(first) / pixels.scale, width: 220, height: Double(last - first) / pixels.scale)
        result.labelInk = pixels.ink(in: labelRect)
        // Just outside the capsule (2 pt above and below, across its width), nothing else is drawn.
        let band = Int(2 * pixels.scale)
        for y in Array(max(0, first - band - 1)..<max(0, first - 1)) + Array(min(pixels.height, last + 2)..<min(pixels.height, last + band + 2)) {
            for x in stride(from: x0, to: x1, by: 1) where pixels.darkness(x, y) > 0.12 {
                result.touching = true
                break
            }
        }
        return result
    }

    /// reasoning → search (with a source) → result and reasoning → a source → fetch → a source,
    /// with the sources landing a couple of frames after the parts (as they do on the socket).
    @Test func thePillStaysWholeAndClearWhilePartsArrive() async throws {
        var state = ResponseState()
        state.apply(.itemAdded(outputIndex: 0, item: .reasoning(ReasoningOutput(id: "r1", status: .inProgress))))
        state.apply(.delta(.reasoning, itemID: "r1", outputIndex: 0, index: 0, text: "Search first."))
        state.apply(.itemAdded(outputIndex: 1, item: Self.call("c1", "search_web", arguments: #"{"query":"mice"}"#)))
        state.apply(.source(Self.source(1)))
        let driver = ResponseDriver(state)
        let probe = HostingProbe(ResponseHost(driver: driver), size: Self.size)
        var evidence = ProbeEvidence("sources")
        var failures: [String] = []
        var settledInk = 0.0
        var frames = 0
        func check(_ pixels: Pixels) {
            let pill = Self.pill(in: pixels)
            var notes: [String] = []
            if pill.rows == nil {
                notes.append("NO-PILL")
            } else {
                if pill.groups > 1 { notes.append("SPLIT") }
                if settledInk > 0, pill.labelInk < 0.5 * settledInk { notes.append("EMPTY") }
                if pill.touching { notes.append("OVERLAP") }
            }
            if !notes.isEmpty { failures.append("frame \(frames): \(notes.joined(separator: ","))") }
            evidence.save(pixels, note: notes.joined(separator: "-"))
            frames += 1
        }
        await probe.run(for: .milliseconds(300))
        settledInk = Self.pill(in: probe.frame()).labelInk
        #expect(settledInk > 5, "the settled pill has its label")

        driver.state.apply(.itemAdded(outputIndex: 2, item: Self.result("c1")))
        driver.state.apply(.itemAdded(outputIndex: 3, item: .reasoning(ReasoningOutput(id: "r2", status: .inProgress))))
        driver.state.apply(.delta(.reasoning, itemID: "r2", outputIndex: 3, index: 0, text: "Now read it."))
        await probe.run(for: .milliseconds(40), check)
        driver.state.apply(.source(Self.source(2)))
        await probe.run(for: .milliseconds(60), check)
        driver.state.apply(.itemAdded(outputIndex: 4, item: Self.call("c2", "fetch_url", arguments: #"{"url":"https://site2.example.com"}"#)))
        await probe.run(for: .milliseconds(40), check)
        driver.state.apply(.source(Self.source(3)))
        await probe.run(for: .milliseconds(700), check)
        // The fetch finishes: its row comes back above the tail.
        driver.state.apply(.itemAdded(outputIndex: 5, item: Self.result("c2")))
        await probe.run(for: .milliseconds(600), check)
        // A part that goes away (the Server replaces the output without the second reasoning)
        // pulls the rows below up cleanly too.
        let output = driver.state.output.filter { item in
            if case .reasoning(let reasoning) = item { return reasoning.id != "r2" }
            return true
        }
        driver.state.apply(.snapshot(output))
        await probe.run(for: .milliseconds(600), check)
        #expect(failures.isEmpty, "\(failures.count) bad frames: \(failures.prefix(8).joined(separator: "; "))")
    }

    @Test func noPillWithoutSourcesAndNeverAnEmptyLabel() throws {
        #expect(Citation.list(from: []).isEmpty)
        let label = SourcesButton.label(for: Citation.list(from: [Self.source(1)]))
        #expect(label == "site1.example.com · 1 source")
        // A source without a link or a name still counts.
        let bare = SourcesButton.label(for: Citation.list(from: [Source(id: nil, name: "")]))
        #expect(bare == "1 source")
        #expect(SourcesButton.label(for: []).isEmpty)
    }
}

@Observable @MainActor
final class ResponseDriver {
    var state: ResponseState
    init(_ state: ResponseState) { self.state = state }
}

struct ResponseHost: View {
    let driver: ResponseDriver

    var body: some View {
        ResponseView(state: driver.state, showsSources: true, showsStatus: true, onRetry: nil)
            .padding(16)
            .frame(width: 393, height: 560, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
    }
}
#endif
