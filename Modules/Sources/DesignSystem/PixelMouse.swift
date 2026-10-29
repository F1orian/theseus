public import SwiftUI

/// Theseus, the pixel mouse (docs/design/brand.md §3, ADR 0140), named after Claude Shannon's 1950
/// maze-solving mouse. *The art is human; the pixel is the machine*: the mouse appears at moments
/// (thinking, waiting, nothing here yet), never inside a painting.
///
/// Drawn with `Canvas` from the generated sprite grids (`scripts/brand/gen_sprites.py`): a whole
/// number of points per sprite pixel, no anti-aliasing, every edge on the point grid. Decorative,
/// so it's hidden from accessibility; use `PixelMouseRunning` where the mouse carries state.
///
/// ```swift
/// PixelMouse(pose: .sleep, scale: 3)   // an empty state
/// PixelMouse(pose: .head)              // the assistant avatar (2 pt per pixel)
/// ```
public struct PixelMouse: View {
    /// The nine poses, each for a moment (see `purpose`).
    public enum Pose: String, CaseIterable, Sendable, Identifiable {
        case sit, stand, run1, run2, peek, read, lantern, sleep, head

        public var id: String { rawValue }
        /// The pose's grid, padded to a rectangle.
        public var sprite: Sprite { Sprite.all[self] ?? Sprite(rows: []) }
    }

    private let pose: Pose
    private let scale: Int

    /// - Parameters:
    ///   - pose: Which drawing.
    ///   - scale: Points per sprite pixel, a whole number (1 or more; 2 for the avatar, 3–4 for
    ///     empty states). The view's size is the sprite's size times `scale`.
    public init(pose: Pose = .sit, scale: Int = 2) {
        self.pose = pose
        self.scale = max(scale, 1)
    }

    public var body: some View {
        SpriteCanvas(sprite: pose.sprite, scale: scale)
            .mouseBackdropBackground(scale: scale)
            .accessibilityHidden(true)
    }

    /// The size of `pose` at `scale` points per pixel.
    nonisolated public static func size(of pose: Pose, scale: Int) -> CGSize {
        pose.sprite.size(scale: scale)
    }

    /// The largest whole-number scale at which `pose` fits in `size` (at least 1).
    nonisolated public static func largestScale(for pose: Pose, fitting size: CGSize) -> Int {
        let sprite = pose.sprite
        guard sprite.width > 0, sprite.height > 0, size.width.isFinite, size.height.isFinite else { return 1 }
        let fit = min(size.width / CGFloat(sprite.width), size.height / CGFloat(sprite.height))
        return max(Int(fit.rounded(.down)), 1)
    }
}

extension PixelMouse {
    /// One pose as a rectangular grid of palette glyphs (`.` is transparent), and its colour runs.
    public struct Sprite: Sendable, Equatable {
        /// The rows, each padded on the right with `.` to `width`.
        public let rows: [String]
        public let width: Int
        public let height: Int
        /// Horizontal runs of one colour, the drawing's rectangles.
        let runs: [Run]

        struct Run: Sendable, Equatable {
            let glyph: Character
            let x: Int
            let y: Int
            let length: Int
        }

        init(rows raw: [String]) {
            let width = raw.map(\.count).max() ?? 0
            let rows = raw.map { $0 + String(repeating: ".", count: width - $0.count) }
            var runs: [Run] = []
            for (y, row) in rows.enumerated() {
                var current: (glyph: Character, x: Int, length: Int)?
                for (x, glyph) in row.enumerated() {
                    if let run = current, run.glyph == glyph {
                        current = (glyph, run.x, run.length + 1)
                        continue
                    }
                    if let run = current, run.glyph != "." { runs.append(Run(glyph: run.glyph, x: run.x, y: y, length: run.length)) }
                    current = (glyph, x, 1)
                }
                if let run = current, run.glyph != "." { runs.append(Run(glyph: run.glyph, x: run.x, y: y, length: run.length)) }
            }
            self.rows = rows
            self.width = width
            self.height = rows.count
            self.runs = runs
        }

        /// The size at `scale` points per pixel.
        public func size(scale: Int) -> CGSize {
            CGSize(width: width * max(scale, 1), height: height * max(scale, 1))
        }

        /// Every pose's sprite, built once.
        static let all: [Pose: Sprite] = Dictionary(
            uniqueKeysWithValues: Pose.allCases.map { ($0, Sprite(rows: PixelMouse.rows(for: $0))) }
        )
    }
}

extension PixelMouse {
    /// The ink of freestanding marks (`inkGlyph`, #192: the waiting `?`, thought puffs): `K`'s umber
    /// (#23211F) in light mode, so nothing changes there, and Pewter (#B4B7BF, `textSecondary`'s dark
    /// value) in dark, where umber all but disappears on Nocturne. Outlines stay umber.
    nonisolated public static let ink = ColorToken(light: RGBA(hex: 0x23211F), dark: Palette.textSecondary.dark)
}

/// Draws a sprite: one path per colour, filled without anti-aliasing at whole-point coordinates.
/// The ink glyph (`PixelMouse.inkGlyph`) follows the appearance (`PixelMouse.ink`); every other
/// glyph is its palette colour.
struct SpriteCanvas: View {
    let sprite: PixelMouse.Sprite
    let scale: Int
    /// The glyph colours: the sprite palette, or a working-mouse scene's (`WorkingMouse.palette`).
    var palette: [Character: RGBA] = PixelMouse.palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = sprite.size(scale: scale)
        var palette = palette
        if colorScheme == .dark, palette[PixelMouse.inkGlyph] != nil { palette[PixelMouse.inkGlyph] = PixelMouse.ink.dark }
        return Canvas { context, _ in
            let unit = CGFloat(scale)
            var paths: [Character: Path] = [:]
            for run in sprite.runs {
                let rect = CGRect(x: CGFloat(run.x) * unit, y: CGFloat(run.y) * unit, width: CGFloat(run.length) * unit, height: unit)
                paths[run.glyph, default: Path()].addRect(rect)
            }
            for (glyph, path) in paths {
                guard let colour = palette[glyph] else { continue }
                context.fill(path, with: .color(colour.color), style: FillStyle(antialiased: false))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The mouse running, for "thinking / waiting for the first token" and streaming: `run1` and
/// `run2` swap at about 6 fps (stepped; nothing tweens). With Reduce Motion on it holds the first
/// frame, still. Unlike `PixelMouse` it carries state, so VoiceOver reads its label ("Thinking").
public struct PixelMouseRunning: View {
    /// The frame rate of the stepped animation.
    nonisolated public static let framesPerSecond: Double = 6

    private let scale: Int
    private let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - scale: Points per sprite pixel (whole number, at least 1).
    ///   - label: What VoiceOver reads.
    public init(scale: Int = 2, label: String = "Thinking") {
        self.scale = max(scale, 1)
        self.label = label
    }

    public var body: some View {
        Group {
            if reduceMotion {
                SpriteCanvas(sprite: PixelMouse.Pose.run1.sprite, scale: scale)
            } else {
                TimelineView(.periodic(from: .distantPast, by: 1 / Self.framesPerSecond)) { timeline in
                    SpriteCanvas(sprite: Self.frame(at: timeline.date).sprite, scale: scale)
                }
            }
        }
        .mouseBackdropBackground(scale: scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The pose shown at `date`: `run1` and `run2` alternating at `framesPerSecond`.
    nonisolated public static func frame(at date: Date) -> PixelMouse.Pose {
        let step = Int((date.timeIntervalSinceReferenceDate * framesPerSecond).rounded(.down))
        return step.isMultiple(of: 2) ? .run1 : .run2
    }
}

// MARK: Previews

#Preview("sit") { PixelMouse(pose: .sit, scale: 4).padding().themedBackground() }
#Preview("stand") { PixelMouse(pose: .stand, scale: 4).padding().themedBackground() }
#Preview("run1") { PixelMouse(pose: .run1, scale: 4).padding().themedBackground() }
#Preview("run2") { PixelMouse(pose: .run2, scale: 4).padding().themedBackground() }
#Preview("peek") { PixelMouse(pose: .peek, scale: 4).padding().themedBackground() }
#Preview("read") { PixelMouse(pose: .read, scale: 4).padding().themedBackground() }
#Preview("lantern") { PixelMouse(pose: .lantern, scale: 4).padding().themedBackground() }
#Preview("sleep") { PixelMouse(pose: .sleep, scale: 4).padding().themedBackground() }
#Preview("head") { PixelMouse(pose: .head, scale: 4).padding().themedBackground() }

#Preview("Running") {
    VStack(spacing: Spacing.s) {
        PixelMouseRunning(scale: 3)
        Text("Thinking…").plaqueStyle()
    }
    .padding()
    .themedBackground()
}
