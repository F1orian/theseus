import AppKit
import Foundation
import Observation
import Rendering
import SwiftUI
import Textual

// Streams a ~5k-token Response into each renderer the way the app does (coalesced updates of
// ~12 tokens), forcing SwiftUI to update, lay out and draw an offscreen window after every
// update. Reports per-update latency.

@MainActor @Observable final class Feed {
    var text = ""
    var isStreaming = true
}

struct TextualNaive: View {
    let feed: Feed
    var body: some View {
        StructuredText(markdown: feed.text, syntaxExtensions: [.math])
            .frame(width: 390, alignment: .topLeading)
    }
}

/// Textual fed through Theseus's frozen-prefix splitter (one StructuredText per frozen chunk).
@MainActor @Observable final class ChunkFeed {
    var frozen: [String] = []
    var tail = ""
}

struct TextualSplit: View {
    let feed: ChunkFeed
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(feed.frozen.enumerated()), id: \.offset) { _, chunk in
                StructuredText(markdown: chunk, syntaxExtensions: [.math])
            }
            StructuredText(markdown: feed.tail, syntaxExtensions: [.math])
        }
        .frame(width: 390, alignment: .topLeading)
    }
}

struct TheseusStreaming: View {
    let feed: Feed
    var body: some View {
        StreamingMarkdownView(text: feed.text, isStreaming: feed.isStreaming)
            .frame(width: 390, alignment: .topLeading)
    }
}

struct TheseusNaive: View {
    let feed: Feed
    var body: some View {
        MarkdownView(blocks: MarkdownParser.parse(feed.text))
            .frame(width: 390, alignment: .topLeading)
    }
}

@MainActor
func measure<V: View>(_ name: String, updates: [String], view: V, apply: (String) -> Void) -> [Double] {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 40_000)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    var samples: [Double] = []
    let clock = ContinuousClock()
    for text in updates {
        let elapsed = clock.measure {
            apply(text)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    }
    return samples
}

func report(_ name: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
    let lastTenth = samples.suffix(max(samples.count / 10, 1))
    let tailMean = lastTenth.reduce(0, +) / Double(lastTenth.count)
    let over16 = samples.filter { $0 > 16.7 }.count
    print(String(format: "%-34@ median %6.2f ms  p95 %7.2f ms  max %7.2f ms  last-10%% mean %7.2f ms  >16.7ms: %3d/%d  total %6.2f s",
                 name as NSString, pct(0.5), pct(0.95), sorted.last ?? 0, tailMean, over16, samples.count, samples.reduce(0, +) / 1000))
}

@MainActor func run() {
    guard let url = Bundle.module.url(forResource: "benchmark-response", withExtension: "md"),
          let document = try? String(contentsOf: url, encoding: .utf8)
    else { fatalError("missing document") }

    // ~4 characters per token → ~5k tokens; one coalesced update per 12 tokens.
    let step = 48
    var updates: [String] = []
    var cursor = document.startIndex
    while cursor < document.endIndex {
        cursor = document.index(cursor, offsetBy: step, limitedBy: document.endIndex) ?? document.endIndex
        updates.append(String(document[..<cursor]))
    }
    print("document: \(document.count) chars (~\(document.count / 4) tokens), \(updates.count) streamed updates\n")

    let feedA = Feed()
    let textual = measure("Textual (whole doc per update)", updates: updates, view: TextualNaive(feed: feedA)) { feedA.text = $0 }
    report("Textual (whole doc per update)", textual)

    let chunks = ChunkFeed()
    var splitter = StreamingMarkdown()
    let textualSplit = measure("Textual + frozen-prefix split", updates: updates, view: TextualSplit(feed: chunks)) { text in
        splitter.update(text, isComplete: false)
        // Re-derive chunk strings from the boundary the splitter uses.
        let (frozen, tail) = StreamingSplitProbe.split(text)
        if frozen.count != chunks.frozen.count { chunks.frozen = frozen }
        chunks.tail = tail
    }
    report("Textual + frozen-prefix split", textualSplit)

    let feedB = Feed()
    let theseus = measure("Theseus (frozen prefix + live tail)", updates: updates, view: TheseusStreaming(feed: feedB)) { feedB.text = $0 }
    report("Theseus (frozen prefix + live tail)", theseus)

    let feedC = Feed()
    let naive = measure("Theseus (full re-parse per update)", updates: updates, view: TheseusNaive(feed: feedC)) { feedC.text = $0 }
    report("Theseus (full re-parse per update)", naive)

    // Parse-only cost, without SwiftUI.
    let clock = ContinuousClock()
    var incremental = StreamingMarkdown()
    let parseStreaming = clock.measure { for text in updates { incremental.update(text, isComplete: false) } }
    let parseFull = clock.measure { for text in updates { _ = MarkdownParser.parse(text) } }
    let foundation = clock.measure {
        for text in updates { _ = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) }
    }
    print("\nparse only, all updates: frozen+tail \(parseStreaming)  full swift-markdown \(parseFull)  Foundation AttributedString(markdown:) \(foundation)")
}

/// Mirrors StreamingMarkdown's split for the Textual variant (blank line outside fences/math,
/// next line unindented).
enum StreamingSplitProbe {
    static func split(_ text: String) -> ([String], String) {
        var chunks: [String] = []
        var current = ""
        var inFence = false
        var inMath = false
        var previousBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            if !inFence, !inMath, previousBlank, !line.isEmpty, line.first != " ", !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.components(separatedBy: "$$").count % 2 == 0 { inMath.toggle() }
            previousBlank = trimmed.isEmpty
            current += (current.isEmpty ? "" : "\n") + line
        }
        return (chunks, current)
    }
}

MainActor.assumeIsolated { run() }
