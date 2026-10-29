public import SwiftUI

/// A pixel mouse that reacts when it's tapped (#174, brand.md §3): the assistant avatar (`head`),
/// the working mouse at a Response's tail (#185), the home's `sit`. Every surface wraps its mouse
/// in this, so they all behave the same.
///
/// - **Tap:** a small stepped reaction, picked at random and never the same twice in a row: a
///   hop, an ear twitch, a blink, a sniff, a squeak (a light impact haptic), or now and then a
///   tiny pixel heart or a cheese crumb floating up.
/// - **Seven quick taps:** a rare surprise, a spin-hop or a run off and back.
/// - **Long press:** it curls up (`sleep`) for two seconds.
///
/// Everything is frame swaps and whole-pixel steps at 8 fps (no tweening, no rotation); with
/// Reduce Motion on, a tap only plays the haptic and swaps one frame (a blink). The hit target is
/// at least 44 pt without changing the layout. Decorative mice stay hidden from VoiceOver; the
/// running one keeps its label.
///
/// ```swift
/// PettableMouse(.pose(.head), scale: 2)
/// PettableMouse(.running(label: "Thinking"), scale: 2)
/// PettableMouse(.working(.runningCommand, label: "Running command"), scale: 2)
/// ```
public struct PettableMouse: View {
    public enum Kind: Sendable, Hashable {
        /// A still pose (decorative, hidden from VoiceOver).
        case pose(PixelMouse.Pose)
        /// The running mouse (`run1`/`run2` at 6 fps), which carries state: VoiceOver reads `label`.
        case running(label: String)
        /// A working-mouse scene (#185), which carries state: VoiceOver reads `label` (with
        /// `updatesFrequently` unless the scene is static).
        case working(WorkingMouse.Scene, size: WorkingMouse.Size = .compact, label: String)
    }

    /// The frame rate of a reaction (brand.md §3: 6 to 8 fps).
    nonisolated public static let framesPerSecond: Double = 8
    /// How long the long-press curl lasts.
    nonisolated public static let curlDuration: Double = 2

    private let kind: Kind
    private let scale: Int
    private let isAnimating: Bool
    @State private var frame: MouseFrame?
    @State private var tracker = PettingTracker()
    @State private var player: Task<Void, Never>?
    @State private var squeaks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - kind: Which mouse.
    ///   - scale: Points per sprite pixel (a whole number, at least 1).
    ///   - isAnimating: For the running and working mice: whether they move (off while hidden).
    public init(_ kind: Kind, scale: Int = 2, isAnimating: Bool = true) {
        self.kind = kind
        self.scale = max(scale, 1)
        self.isAnimating = isAnimating
    }

    public var body: some View {
        let base = kind.baseSprite
        let size = base.size(scale: scale)
        // The base keeps the layout; the drawing (base or reaction frame) sits on top of it. The
        // backdrop (#192) belongs to the base, so it stays put while the mouse hops or runs off.
        Color.clear
            .frame(width: size.width, height: size.height)
            .mouseBackdropBackground(scale: scale)
            .overlay(alignment: .bottomLeading) { drawing.mouseBackdrop(false) }
            .padding(.horizontal, max(0, (AccessibilityMetrics.minimumHitTarget - size.width) / 2))
            .padding(.vertical, max(0, (AccessibilityMetrics.minimumHitTarget - size.height) / 2))
            .contentShape(.rect)
            .onTapGesture(perform: tapped)
            .onLongPressGesture(minimumDuration: 0.5, perform: curl)
            .padding(.horizontal, -max(0, (AccessibilityMetrics.minimumHitTarget - size.width) / 2))
            .padding(.vertical, -max(0, (AccessibilityMetrics.minimumHitTarget - size.height) / 2))
            .sensoryFeedback(.impact(weight: .light), trigger: squeaks)
            .modifier(MouseAccessibility(kind: kind))
            .onDisappear { player?.cancel() }
    }

    @ViewBuilder
    private var drawing: some View {
        if let frame {
            FrameView(frame: frame, kind: kind, scale: scale)
        } else if case .running = kind, isAnimating, !reduceMotion {
            TimelineView(.periodic(from: .distantPast, by: 1 / PixelMouseRunning.framesPerSecond)) { timeline in
                SpriteCanvas(sprite: PixelMouseRunning.frame(at: timeline.date).sprite, scale: scale)
            }
        } else if case .working(let scene, let size, _) = kind {
            // Labelled by `MouseAccessibility`, so the scene itself stays unlabelled.
            WorkingMouse(scene, size: size, scale: scale, isAnimating: isAnimating)
        } else {
            SpriteCanvas(sprite: kind.baseSprite, scale: scale)
        }
    }

    private func tapped() {
        if reduceMotion {
            // No movement: the haptic and a one-frame swap.
            squeaks += 1
            play([MouseFrame(drawing: kind.variant(.blink))], hold: 0.3)
            return
        }
        var random = SystemRandomNumberGenerator()
        let reaction = tracker.tap(at: Date(), available: MouseReaction.available(for: kind), using: &random)
        if reaction == .squeak { squeaks += 1 }
        play(reaction.frames(for: kind))
    }

    private func curl() {
        tracker.reset()
        play([MouseFrame(drawing: .pose(.sleep))], hold: Self.curlDuration)
    }

    /// Steps through `frames` at `framesPerSecond`; a single frame is held for `hold` seconds.
    private func play(_ frames: [MouseFrame], hold: Double? = nil) {
        player?.cancel()
        let step = hold ?? 1 / Self.framesPerSecond
        player = Task { @MainActor in
            for next in frames {
                frame = next
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
            }
            frame = nil
        }
    }
}

/// One step of a reaction: what's drawn, where (whole sprite pixels from the resting place), and
/// a prop floating above.
struct MouseFrame: Sendable, Hashable {
    enum Drawing: Sendable, Hashable {
        case pose(PixelMouse.Pose)
        case frame(PixelMouse.Frame)
        /// Frame `index` (looping) of a working-mouse scene.
        case scene(WorkingMouse.Scene, WorkingMouse.Size, index: Int)
    }

    struct Prop: Sendable, Hashable {
        var frame: PixelMouse.Frame
        /// Points above the prop's start (whole points, stepped).
        var rise: Int
        var opacity: Double
    }

    var drawing: Drawing
    /// Sprite pixels right (+) or left (−).
    var dx = 0
    /// Sprite pixels down (+) or up (−).
    var dy = 0
    /// Facing the other way (a mirror image, never a rotation).
    var mirrored = false
    var opacity: Double = 1
    var prop: Prop?
}

/// A tap's reaction, and the rarer surprises.
enum MouseReaction: String, Sendable, CaseIterable {
    case hop, earTwitch, blink, sniff, squeak, heart, crumb
    /// Seven quick taps.
    case spinHop, runOff

    /// The everyday reactions (a tap picks one of these).
    static let everyday: [MouseReaction] = [.hop, .earTwitch, .blink, .sniff, .squeak, .heart, .crumb]
    /// The rare ones after `PettingTracker.surpriseTaps` quick taps.
    static let surprises: [MouseReaction] = [.spinHop, .runOff]

    /// How often a tap picks it, relative to the others: the heart and the crumb are occasional.
    var weight: Int {
        switch self {
        case .heart, .crumb: 1
        default: 3
        }
    }

    /// What `kind` can do: the head and the sitting mouse have blink, ear and sniff frames;
    /// other poses and the running mouse hop, squeak and float props.
    static func available(for kind: PettableMouse.Kind) -> [MouseReaction] {
        if kind.hasFaceFrames { return everyday }
        return [.hop, .squeak, .heart, .crumb]
    }

    /// The reaction's frames for `kind`, at `PettableMouse.framesPerSecond`.
    func frames(for kind: PettableMouse.Kind) -> [MouseFrame] {
        let rest = kind.restingDrawing
        let fade: [Double] = [1, 1, 1, 1, 0.66, 0.33]
        switch self {
        case .hop:
            return [-2, -3, -1, 0].enumerated().map { index, dy in MouseFrame(drawing: kind.legs(index), dy: dy) }
        case .earTwitch:
            let ear = kind.variant(.ear)
            return [ear, rest, ear, rest].map { MouseFrame(drawing: $0) }
        case .blink:
            let shut = kind.variant(.blink)
            return [shut, shut, rest].map { MouseFrame(drawing: $0) }
        case .sniff:
            let sniff = kind.variant(.sniff)
            return [sniff, rest, sniff, rest, sniff, rest].map { MouseFrame(drawing: $0) }
        case .squeak:
            return [MouseFrame(drawing: kind.variant(.blink), dy: -1), MouseFrame(drawing: kind.variant(.blink)), MouseFrame(drawing: rest)]
        case .heart, .crumb:
            let prop: PixelMouse.Frame = self == .heart ? .heart : .crumb
            // Floats up 12 pt in 2 pt steps, fading out in three steps.
            return fade.enumerated().map { index, opacity in
                let face = self == .crumb && index.isMultiple(of: 2) ? kind.variant(.sniff) : kind.legs(index)
                return MouseFrame(drawing: face, prop: .init(frame: prop, rise: index * 2, opacity: opacity))
            }
        case .spinHop:
            let steps: [(dy: Int, mirrored: Bool)] = [(-2, false), (-3, true), (-4, false), (-3, true), (-2, false), (-1, true), (0, false)]
            return steps.enumerated().map { index, step in MouseFrame(drawing: kind.legs(index), dy: step.dy, mirrored: step.mirrored) }
        case .runOff:
            // Off to the right in 6-pixel strides, fading out; back in from the left.
            let out: [(dx: Int, opacity: Double)] = [(0, 1), (6, 1), (12, 0.66), (18, 0.33), (24, 0)]
            let back: [(dx: Int, opacity: Double)] = [(-18, 0), (-12, 0.33), (-6, 0.66), (0, 1)]
            return (out + back).enumerated().map { index, step in
                MouseFrame(drawing: kind.runner(index), dx: step.dx, opacity: step.opacity)
            } + [MouseFrame(drawing: rest)]
        }
    }
}

/// Picks reactions: random by weight, never the last one again; seven quick taps in a row make a
/// surprise.
struct PettingTracker: Sendable {
    /// Taps closer together than this count as one run.
    static let quickTapGap: TimeInterval = 0.6
    /// How many quick taps make a surprise.
    static let surpriseTaps = 7

    private(set) var last: MouseReaction?
    private(set) var quickTaps = 0
    private var lastTap: Date?

    mutating func tap(
        at date: Date,
        available: [MouseReaction] = MouseReaction.everyday,
        using random: inout some RandomNumberGenerator
    ) -> MouseReaction {
        if let lastTap, date.timeIntervalSince(lastTap) <= Self.quickTapGap {
            quickTaps += 1
        } else {
            quickTaps = 1
        }
        lastTap = date
        let pool: [MouseReaction]
        if quickTaps >= Self.surpriseTaps {
            quickTaps = 0
            pool = MouseReaction.surprises
        } else {
            pool = available
        }
        let candidates = pool.count > 1 ? pool.filter { $0 != last } : pool
        let total = candidates.reduce(0) { $0 + $1.weight }
        var pick = Int.random(in: 0..<max(total, 1), using: &random)
        var reaction = candidates.first ?? .blink
        for candidate in candidates {
            if pick < candidate.weight {
                reaction = candidate
                break
            }
            pick -= candidate.weight
        }
        last = reaction
        return reaction
    }

    mutating func reset() {
        quickTaps = 0
        lastTap = nil
    }
}

extension PettableMouse.Kind {
    enum Variant { case blink, ear, sniff }

    /// The sprite that sets the layout.
    var baseSprite: PixelMouse.Sprite {
        restingDrawing.sprite
    }

    var restingDrawing: MouseFrame.Drawing {
        switch self {
        case .pose(let pose): .pose(pose)
        case .running: .pose(.run1)
        case .working(let scene, let size, _): .scene(scene, size, index: WorkingMouse.stillIndex(of: scene, size: size))
        }
    }

    var hasFaceFrames: Bool {
        self == .pose(.head) || self == .pose(.sit)
    }

    /// Frame `index` of a moving reaction: the runner keeps its legs going and a scene keeps
    /// working; poses hold.
    func legs(_ index: Int) -> MouseFrame.Drawing {
        switch self {
        case .pose(let pose): .pose(pose)
        case .running: .pose(index.isMultiple(of: 2) ? .run1 : .run2)
        case .working(let scene, let size, _): .scene(scene, size, index: index)
        }
    }

    /// Frame `index` of the run off and back: the mouse becomes the runner; a scene goes as a whole.
    func runner(_ index: Int) -> MouseFrame.Drawing {
        switch self {
        case .working: legs(index)
        case .pose, .running: .pose(index.isMultiple(of: 2) ? .run1 : .run2)
        }
    }

    /// The face frame for `variant`, or the resting drawing where the pose has none.
    func variant(_ variant: Variant) -> MouseFrame.Drawing {
        switch (self, variant) {
        case (.pose(.head), .blink): .frame(.headBlink)
        case (.pose(.head), .ear): .frame(.headEar)
        case (.pose(.head), .sniff): .frame(.headSniff)
        case (.pose(.sit), .blink): .frame(.sitBlink)
        case (.pose(.sit), .ear): .frame(.sitEar)
        case (.pose(.sit), .sniff): .frame(.sitSniff)
        default: restingDrawing
        }
    }
}

extension MouseFrame.Drawing {
    var sprite: PixelMouse.Sprite {
        switch self {
        case .pose(let pose): pose.sprite
        case .frame(let frame): frame.sprite
        case .scene(let scene, let size, let index):
            WorkingMouse.sprites(scene, size: size)[index % max(WorkingMouse.frameCount(of: scene, size: size), 1)]
        }
    }

    /// The colours to draw it in: a scene's accent pixels follow the current `AccentChoice`.
    func palette(for choice: AccentChoice) -> [Character: RGBA] {
        if case .scene = self { return WorkingMouse.palette(for: choice) }
        return PixelMouse.palette
    }
}

extension PixelMouse.Frame {
    /// The frame's grid, padded to a rectangle.
    public var sprite: PixelMouse.Sprite { Self.all[self] ?? PixelMouse.Sprite(rows: []) }

    private static let all: [PixelMouse.Frame: PixelMouse.Sprite] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, PixelMouse.Sprite(rows: PixelMouse.rows(for: $0))) }
    )
}

/// Draws one reaction frame: the sprite moved by whole sprite pixels, mirrored or faded in steps,
/// with its prop floating above.
struct FrameView: View {
    let frame: MouseFrame
    let kind: PettableMouse.Kind
    let scale: Int

    var body: some View {
        let unit = CGFloat(scale)
        SpriteCanvas(sprite: frame.drawing.sprite, scale: scale, palette: frame.drawing.palette(for: AccentSelection.shared.choice))
            .scaleEffect(x: frame.mirrored ? -1 : 1, y: 1)
            .opacity(frame.opacity)
            .offset(x: CGFloat(frame.dx) * unit, y: CGFloat(frame.dy) * unit)
            .overlay(alignment: .top) {
                if let prop = frame.prop {
                    let propScale = max(scale - 1, 1)
                    let height = prop.frame.sprite.size(scale: propScale).height
                    SpriteCanvas(sprite: prop.frame.sprite, scale: propScale)
                        .opacity(prop.opacity)
                        .offset(y: -height - CGFloat(prop.rise) - unit)
                }
            }
            .transaction { $0.animation = nil }
    }
}

/// Decorative mice are hidden; the running and working ones read their label.
private struct MouseAccessibility: ViewModifier {
    let kind: PettableMouse.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .pose:
            content.accessibilityHidden(true)
        case .running(let label):
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.updatesFrequently)
        case .working(let scene, _, let label):
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(scene.isStatic ? [] : .updatesFrequently)
        }
    }
}

// MARK: Previews

#Preview("Pettable") {
    HStack(alignment: .bottom, spacing: Spacing.xl) {
        PettableMouse(.pose(.head), scale: 2)
        PettableMouse(.pose(.sit), scale: 3)
        PettableMouse(.running(label: "Thinking"), scale: 2)
        PettableMouse(.working(.webSearch, label: "Searching the web"), scale: 2)
    }
    .padding(40)
    .themedBackground()
}
