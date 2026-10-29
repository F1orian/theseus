public import SwiftUI
import Synchronization

/// The working mouse (#185, brand.md §3): a stepped pixel scene for every kind of work a Response
/// does (thinking, searching the web, running a command, reading files, …), at two sizes.
///
/// The frames are generated (`scripts/brand/gen_working_mouse.py`, ADR 0146) and played at
/// `PixelMouseRunning.framesPerSecond` (6 fps), stepped: frames swap, nothing tweens. Drawn like
/// `PixelMouse`, one whole-point rectangle per sprite pixel with anti-aliasing off. The UI-accent
/// pixels (the thought dot, highlighted lines, bubbles, code and terminal output) follow the user's
/// `AccentChoice` (#179); scenery and every other colour is fixed. With Reduce Motion
/// on, each scene holds one representative frame. Freestanding ink (the `?`, thought puffs) turns
/// light grey in dark mode (`PixelMouse.ink`), and `mouseBackdrop()` sets the whole scene on a soft
/// dark-mode backdrop (#192).
///
/// ```swift
/// WorkingMouse(.webSearch, label: "Searching the web")   // the chat tail (compact, 2 pt per pixel)
/// WorkingMouse(.runningCommand, size: .large)            // an empty or long-running state
/// ```
public struct WorkingMouse: View {
    /// The two drawings of every scene.
    public enum Size: String, CaseIterable, Sendable, Hashable {
        /// 34×14 px, the runner's height: the head with a small prop. The chat tail.
        case compact
        /// 64×30 px: the whole mouse at work. Empty or long-running states.
        case large

        /// The scene's size in sprite pixels.
        public var pixels: (width: Int, height: Int) {
            switch self {
            case .compact: (34, 14)
            case .large: (64, 30)
            }
        }

        /// Points per sprite pixel unless the caller picks one: 2 in the chat (like the avatar), 3
        /// for the large scene.
        public var defaultScale: Int {
            switch self {
            case .compact: 2
            case .large: 3
            }
        }
    }

    private let scene: Scene
    private let size: Size
    private let scale: Int
    private let label: String?
    private let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - scene: Which kind of work.
    ///   - size: `.compact` (the chat tail) or `.large`.
    ///   - scale: Points per sprite pixel, a whole number (at least 1); `size.defaultScale` if `nil`.
    ///   - label: What VoiceOver reads (the plaque without its ellipsis). `nil` hides the scene
    ///     from accessibility, for when a container labels it.
    ///   - isAnimating: Whether the frames step (off while the scene is faded out).
    public init(_ scene: Scene, size: Size = .compact, scale: Int? = nil, label: String? = nil, isAnimating: Bool = true) {
        self.scene = scene
        self.size = size
        self.scale = max(scale ?? size.defaultScale, 1)
        self.label = label
        self.isAnimating = isAnimating
    }

    public var body: some View {
        // Read in `body`, so a new accent choice redraws the scene (ADR 0145).
        let palette = Self.palette(for: AccentSelection.shared.choice)
        Group {
            if reduceMotion || !isAnimating {
                SpriteCanvas(sprite: Self.still(scene, size: size), scale: scale, palette: palette)
            } else {
                TimelineView(.periodic(from: .distantPast, by: 1 / PixelMouseRunning.framesPerSecond)) { timeline in
                    SpriteCanvas(sprite: Self.frame(scene, size: size, at: timeline.date), scale: scale, palette: palette)
                }
            }
        }
        .mouseBackdropBackground(scale: scale)
        .modifier(SceneAccessibility(label: label, isStatic: scene.isStatic))
    }

    /// The size of a scene at `scale` points per pixel.
    nonisolated public static func size(_ size: Size, scale: Int) -> CGSize {
        CGSize(width: size.pixels.width * max(scale, 1), height: size.pixels.height * max(scale, 1))
    }

    /// How many frames `scene` loops through at `size`.
    nonisolated public static func frameCount(of scene: Scene, size: Size) -> Int {
        sprites(scene, size: size).count
    }

    /// The index of the frame shown at `date`: the scene steps at `PixelMouseRunning.framesPerSecond`
    /// and loops.
    nonisolated public static func frameIndex(of scene: Scene, size: Size, at date: Date) -> Int {
        let step = Int((date.timeIntervalSinceReferenceDate * PixelMouseRunning.framesPerSecond).rounded(.down))
        let count = max(frameCount(of: scene, size: size), 1)
        return ((step % count) + count) % count
    }

    /// The index of the frame Reduce Motion holds.
    nonisolated public static func stillIndex(of scene: Scene, size: Size) -> Int {
        stillFrame(of: scene, size: size)
    }

    nonisolated static func frame(_ scene: Scene, size: Size, at date: Date) -> PixelMouse.Sprite {
        sprites(scene, size: size)[frameIndex(of: scene, size: size, at: date)]
    }

    nonisolated static func still(_ scene: Scene, size: Size) -> PixelMouse.Sprite {
        sprites(scene, size: size)[stillFrame(of: scene, size: size)]
    }

    // MARK: Frames

    private struct Key: Hashable {
        let scene: Scene
        let size: Size
    }

    /// Decoded frames, built on first use per scene and size (a scene's runs cost a few
    /// milliseconds, so the app never decodes the scenes it doesn't show).
    nonisolated private static let cache = Mutex<[Key: [PixelMouse.Sprite]]>([:])

    /// Every frame of `scene` at `size`, as sprites (rows padded to the scene's width).
    nonisolated static func sprites(_ scene: Scene, size: Size) -> [PixelMouse.Sprite] {
        let key = Key(scene: scene, size: size)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let (width, height) = size.pixels
        let sprites = encodedFrames(of: scene, size: size).map { PixelMouse.Sprite(rows: decode($0, width: width, height: height)) }
        cache.withLock { $0[key] = sprites }
        return sprites
    }

    /// Empties the decoded frames, for tests of a scene's first show with nothing prewarmed (#194).
    nonisolated static func resetCache() {
        cache.withLock { $0.removeAll() }
    }

    /// Decodes every scene at `sizes` ahead of time on a background thread (the app does it at
    /// launch for the compact scenes), so a scene's first show doesn't decode on the main thread.
    nonisolated public static func prewarm(_ sizes: [Size] = [.compact]) async {
        await Task.detached(priority: .utility) {
            for size in sizes {
                for scene in Scene.allCases { _ = sprites(scene, size: size) }
            }
        }.value
    }

    /// Expands one run-length encoded frame (`gen_working_mouse.py`): a glyph, then its count when
    /// that's more than 1; rows separated by `/`; missing rows and trailing pixels are transparent.
    nonisolated static func decode(_ encoded: String, width: Int, height: Int) -> [String] {
        var rows: [String] = []
        for part in encoded.split(separator: "/", omittingEmptySubsequences: false) where !encoded.isEmpty {
            var row = ""
            var glyph: Character?
            var count = 0
            func flush() {
                if let glyph { row += String(repeating: glyph, count: max(count, 1)) }
            }
            for character in part {
                if let digit = character.wholeNumberValue, character.isASCII {
                    count = count * 10 + digit
                } else {
                    flush()
                    glyph = character
                    count = 0
                }
            }
            flush()
            rows.append(row.padding(toLength: width, withPad: ".", startingAt: 0))
        }
        while rows.count < height { rows.append(String(repeating: ".", count: width)) }
        return rows
    }

    // MARK: Colours

    /// The scene palette for `choice`: the sprite palette, the scene colours (with `n`/`N`, the
    /// fixed verdigris of scenery), and `v`/`V` as the accent's light and dark values (Verdigris
    /// #2C6656 / #7CC7B0, as in the approved mock-up).
    nonisolated public static func palette(for choice: AccentChoice) -> [Character: RGBA] {
        palettes[choice] ?? PixelMouse.palette
    }

    nonisolated private static let palettes: [AccentChoice: [Character: RGBA]] = Dictionary(
        uniqueKeysWithValues: AccentChoice.allCases.map { choice in
            var palette = PixelMouse.palette.merging(scenePalette) { sprite, _ in sprite }
            palette["v"] = choice.tokens.accent.light
            palette["V"] = choice.tokens.accent.dark
            return (choice, palette)
        }
    )
}

extension WorkingMouse.Scene {
    /// Paused on the user: no motion loop but the blinking `?`, and nothing VoiceOver needs to
    /// re-read while the user answers.
    public var isStatic: Bool { self == .waitingOnYou }
}

/// A labelled scene is one element (VoiceOver reads the plaque, `updatesFrequently` unless the
/// scene is static); an unlabelled one is hidden.
private struct SceneAccessibility: ViewModifier {
    let label: String?
    let isStatic: Bool

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(isStatic ? [] : .updatesFrequently)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

// MARK: Previews

#Preview("Compact, every scene") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(WorkingMouse.Scene.allCases) { scene in
                HStack(spacing: Spacing.m) {
                    WorkingMouse(scene, label: scene.rawValue)
                    Text(scene.rawValue).plaqueStyle()
                }
            }
        }
        .padding()
    }
    .mouseBackdrop()
    .themedBackground()
}

#Preview("Large, every scene") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(WorkingMouse.Scene.allCases) { scene in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    WorkingMouse(scene, size: .large, label: scene.rawValue)
                    Text(scene.rawValue).plaqueStyle()
                }
            }
        }
        .padding()
    }
    .mouseBackdrop()
    .themedBackground()
}

#Preview("Dark") {
    VStack(spacing: Spacing.l) {
        WorkingMouse(.runningCommand, size: .large)
        WorkingMouse(.webSearch)
    }
    .padding()
    .mouseBackdrop()
    .themedBackground()
    .preferredColorScheme(.dark)
}
