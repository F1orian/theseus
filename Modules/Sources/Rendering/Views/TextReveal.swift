import DesignSystem
public import SwiftUI

extension EnvironmentValues {
    /// Whether the markdown being rendered is still streaming in. New text in a streaming
    /// Response fades in glyph by glyph instead of popping in a chunk at a time (CHAT-01).
    @Entry public var isStreamingMarkdown = false
}

extension View {
    /// Fades in text that's appended to this `Text` while `\.isStreamingMarkdown` is on: the
    /// first time it appears and on every growth of `length` (in characters). Text that was
    /// already there when the view appeared outside a stream shows at once. Reduce Motion
    /// turns it off (ADR 0130).
    func streamingReveal(length: Int) -> some View {
        modifier(StreamingReveal(length: length))
    }
}

/// Drives `RevealRenderer`: animates the revealed character count towards `length`, so each
/// streamed chunk sweeps in from where the previous one is. Only drawing changes — layout is the
/// final text's from the start, so lines never jump as they fill.
private struct StreamingReveal: ViewModifier {
    let length: Int
    @Environment(\.isStreamingMarkdown) private var isStreaming
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the text is drawn (characters, animated).
    @State private var revealed: Double = 0
    /// Decided once, when the view appears: whether this text reveals at all.
    @State private var isRevealing: Bool?

    func body(content: Content) -> some View {
        let revealing = isRevealing ?? (isStreaming && !reduceMotion)
        content
            .textRenderer(RevealRenderer(revealed: revealed, total: Double(length), isActive: revealing))
            .onAppear {
                guard isRevealing == nil else { return }
                isRevealing = revealing
                if revealing { reveal(to: length, from: 0) }
            }
            .onChange(of: length) { old, new in
                guard isRevealing == true else { return }
                if new < old || reduceMotion {
                    revealed = Double(new)
                } else {
                    reveal(to: new, from: old)
                }
            }
    }

    private func reveal(to length: Int, from previous: Int) {
        withAnimation(.linear(duration: Motion.revealDuration(characters: length - previous))) {
            revealed = Double(length)
        }
    }
}

/// Draws glyphs up to `revealed` fully, then fades the next few in (a soft leading edge), and
/// nothing past it. Draws whole lines where it can, so a long paragraph costs little per frame.
struct RevealRenderer: TextRenderer, Animatable {
    var revealed: Double
    let total: Double
    /// Off: draws the text as is (and ignores animations of `revealed`).
    let isActive: Bool

    var animatableData: Double {
        get { isActive ? revealed : 0 }
        set { if isActive { revealed = newValue } }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let fade = Motion.revealFadeGlyphs
        guard isActive, revealed < total else {
            for line in layout { context.draw(line) }
            return
        }
        var index = 0.0
        for line in layout {
            let count = Double(line.reduce(0) { $0 + $1.count })
            if index + count <= revealed - fade {
                context.draw(line)
                index += count
                continue
            }
            guard index < revealed else { break }
            for run in line {
                for slice in run {
                    let opacity = min(max((revealed - index) / fade, 0), 1)
                    if opacity >= 1 {
                        context.draw(slice)
                    } else if opacity > 0 {
                        var faded = context
                        faded.opacity = opacity
                        faded.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

#Preview("Streaming reveal") {
    @Previewable @State var text = "Theseus follows the thread."
    VStack(alignment: .leading, spacing: 20) {
        StreamingMarkdownView(text: text, isStreaming: true)
        Button("Append") { text += " Each corridor he walks is marked, so he never walks it twice." }
    }
    .padding()
}
