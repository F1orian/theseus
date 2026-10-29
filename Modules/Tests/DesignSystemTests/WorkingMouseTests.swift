@testable import DesignSystem
import Foundation
import SwiftUI
import Testing

/// #185: the generated working-mouse scenes, their playback and their colours.
@Suite("Working mouse scenes (#185)")
struct WorkingMouseTests {
    private static let cases: [(WorkingMouse.Scene, WorkingMouse.Size)] = WorkingMouse.Scene.allCases.flatMap { scene in
        WorkingMouse.Size.allCases.map { (scene, $0) }
    }

    /// One scene per row of #185's table.
    @Test func everyRowOfTheTableHasAScene() {
        let names = WorkingMouse.Scene.allCases.map(\.rawValue)
        #expect(names == [
            "thinking", "stillWriting", "webSearch", "readingPage", "knowledge", "memory", "pastChats", "time", "image",
            "runningCode", "runningCommand", "readingFiles", "writingFiles", "searchingFiles", "skill", "subAgent",
            "tool", "waitingOnYou",
        ])
    }

    @Test(arguments: cases)
    func framesHaveTheSizesPixelSize(scene: WorkingMouse.Scene, size: WorkingMouse.Size) {
        let frames = WorkingMouse.sprites(scene, size: size)
        #expect(frames.count >= 8 && frames.count <= 16, "\(scene) \(size) loops through \(frames.count) frames")
        for sprite in frames {
            #expect(sprite.width == size.pixels.width)
            #expect(sprite.height == size.pixels.height)
            #expect(sprite.rows.allSatisfy { $0.count == size.pixels.width })
            #expect(!sprite.runs.isEmpty, "no frame is blank")
        }
        #expect((0..<frames.count).contains(WorkingMouse.stillIndex(of: scene, size: size)))
        // Consecutive frames differ, so the scene visibly works (the paused one too: its `?` blinks).
        #expect(Set(frames.map(\.rows)).count > 1)
    }

    @Test(arguments: cases)
    func everyGlyphHasAColourInEveryAccent(scene: WorkingMouse.Scene, size: WorkingMouse.Size) {
        for choice in AccentChoice.allCases {
            let palette = WorkingMouse.palette(for: choice)
            for sprite in WorkingMouse.sprites(scene, size: size) {
                for glyph in Set(sprite.rows.joined()) where glyph != "." {
                    #expect(palette[glyph] != nil, "\(scene) \(size) uses \(glyph)")
                }
            }
        }
    }

    /// `v`/`V` are the accent (#179); every other colour stays fixed.
    @Test(arguments: AccentChoice.allCases)
    func theAccentPixelsFollowTheChoice(choice: AccentChoice) {
        let palette = WorkingMouse.palette(for: choice)
        #expect(palette["v"] == choice.tokens.accent.light)
        #expect(palette["V"] == choice.tokens.accent.dark)
        let verdigris = WorkingMouse.palette(for: .verdigris)
        #expect(verdigris["v"] == RGBA(hex: 0x2C6656), "the approved mock-up's verdigris")
        #expect(verdigris["V"] == RGBA(hex: 0x7CC7B0))
        for (glyph, colour) in palette where glyph != "v" && glyph != "V" {
            #expect(verdigris[glyph] == colour, "\(glyph) doesn't change with the accent")
        }
        for (glyph, colour) in PixelMouse.palette {
            #expect(palette[glyph] == colour, "the mouse keeps its own colours")
        }
        // Scenery keeps the mock-up's verdigris whatever the accent.
        #expect(palette["n"] == RGBA(hex: 0x2C6656))
        #expect(palette["N"] == RGBA(hex: 0x7CC7B0))
    }

    /// Only UI-accent pixels follow the accent (the thought dot, highlighted lines, bubbles, code
    /// and terminal output); scenery that depicts a real object stays verdigris.
    /// #192: freestanding ink (the waiting `?`, the thought puffs) is the ink glyph, so it turns light
    /// grey in dark mode; outlines attached to the mouse or a prop stay `K`.
    @Test func freestandingMarksUseTheInkGlyph() {
        func glyphs(_ scene: WorkingMouse.Scene, _ size: WorkingMouse.Size) -> Set<Character> {
            Set(WorkingMouse.sprites(scene, size: size).flatMap { $0.rows.joined() })
        }
        let ink = PixelMouse.inkGlyph
        for size in WorkingMouse.Size.allCases {
            #expect(glyphs(.thinking, size).isSuperset(of: [ink, "K"]), "the puffs are ink, the bubble keeps its outline")
            #expect(glyphs(.waitingOnYou, size).isSuperset(of: [ink, "K"]), "the ? is ink, the mouse keeps its outline")
            for scene in WorkingMouse.Scene.allCases where scene != .thinking && scene != .waitingOnYou {
                #expect(!glyphs(scene, size).contains(ink), "\(scene) \(size) has no freestanding marks")
            }
        }
        // The `?` is wholly ink: its frames hold no `K` above the peeking mouse.
        let question = WorkingMouse.still(.waitingOnYou, size: .large).rows.prefix(9).joined()
        #expect(question.contains(ink) && !question.contains("K"))
        // Light mode is unchanged: the ink is `K`'s umber in every scene palette.
        for choice in AccentChoice.allCases {
            #expect(WorkingMouse.palette(for: choice)[ink] == PixelMouse.palette["K"])
        }
    }

    @Test func sceneryDoesNotFollowTheAccent() {
        func glyphs(_ scene: WorkingMouse.Scene, _ size: WorkingMouse.Size) -> Set<Character> {
            Set(WorkingMouse.sprites(scene, size: size).flatMap { $0.rows.joined() })
        }
        for size in WorkingMouse.Size.allCases {
            // Book spines, the painted hills and the paint, the folders' match label.
            for scene in [WorkingMouse.Scene.knowledge, .image, .searchingFiles] {
                #expect(glyphs(scene, size).isDisjoint(with: ["v", "V"]), "\(scene) \(size) is scenery")
            }
            #expect(glyphs(.knowledge, size).contains("n") && glyphs(.image, size).isSuperset(of: ["n", "N"]))
            // The thought dot, the terminal's output and cursor, highlighted lines and bubbles.
            #expect(glyphs(.thinking, size).contains("v"))
            #expect(glyphs(.runningCommand, size).contains("V"))
            #expect(glyphs(.pastChats, size).contains("V"))
            #expect(glyphs(.readingPage, size).isSuperset(of: ["v", "n"]), "highlighted lines follow, the window's green light doesn't")
        }
    }

    @Test func framesStepAtSixFPSAndLoop() {
        let start = Date(timeIntervalSinceReferenceDate: 600) // a multiple of every loop's length
        let count = WorkingMouse.frameCount(of: .webSearch, size: .compact)
        #expect(count == 12)
        #expect(WorkingMouse.frameIndex(of: .webSearch, size: .compact, at: start) == 0)
        #expect(WorkingMouse.frameIndex(of: .webSearch, size: .compact, at: start.addingTimeInterval(1.0 / 6 + 0.001)) == 1)
        #expect(WorkingMouse.frameIndex(of: .webSearch, size: .compact, at: start.addingTimeInterval(1.0 / 12)) == 0, "no in-between frames")
        #expect(WorkingMouse.frameIndex(of: .webSearch, size: .compact, at: start.addingTimeInterval(2 + 0.001)) == 0, "12 frames loop in 2 s")
        #expect(WorkingMouse.frameIndex(of: .webSearch, size: .compact, at: Date(timeIntervalSinceReferenceDate: -1 / 6.0 + 0.001)) == count - 1)
    }

    @Test func prewarmingDecodesOffTheMainThread() async {
        await WorkingMouse.prewarm([.compact, .large])
        for scene in WorkingMouse.Scene.allCases {
            #expect(WorkingMouse.frameCount(of: scene, size: .compact) > 0)
        }
    }

    @Test func decodingExpandsRunsAndPadsWithTransparency() {
        #expect(WorkingMouse.decode(".2K3/W/", width: 6, height: 4) == ["..KKK.", "W.....", "......", "......"])
        #expect(WorkingMouse.decode("", width: 2, height: 2) == ["..", ".."])
        #expect(WorkingMouse.decode("K12", width: 12, height: 1) == ["KKKKKKKKKKKK"])
    }

    /// The paused scene doesn't compete with the question or approval card: the head holds still
    /// and only the `?` blinks (#185 coordinator decision).
    @Test func waitingOnYouOnlyBlinksItsQuestionMark() {
        let frames = WorkingMouse.sprites(.waitingOnYou, size: .compact)
        let head = frames.map { $0.rows.map { String($0.prefix(18)) } }
        #expect(Set(head).count == 1)
        #expect(Set(frames.map(\.rows)).count == 2, "with the ? and without")
        #expect(WorkingMouse.Scene.waitingOnYou.isStatic)
        #expect(WorkingMouse.Scene.allCases.filter(\.isStatic) == [.waitingOnYou])
    }

    @Test func sizesAreWholePoints() {
        #expect(WorkingMouse.size(.compact, scale: 2) == CGSize(width: 68, height: 28))
        #expect(WorkingMouse.size(.large, scale: 3) == CGSize(width: 192, height: 90))
        #expect(WorkingMouse.size(.large, scale: 0) == CGSize(width: 64, height: 30))
    }

    /// Decoding is lazy per scene and size: the first frame of a scene costs one decode of its
    /// loop. The bound is loose (debug build, parallel tests); the number is in the log.
    @Test func decodingAWholeSceneIsCheap() {
        let clock = ContinuousClock()
        var total = Duration.zero
        for scene in WorkingMouse.Scene.allCases {
            for size in WorkingMouse.Size.allCases {
                let frames = WorkingMouse.encodedFrames(of: scene, size: size)
                let elapsed = clock.measure {
                    for encoded in frames {
                        _ = PixelMouse.Sprite(rows: WorkingMouse.decode(encoded, width: size.pixels.width, height: size.pixels.height))
                    }
                }
                total += elapsed
                #expect(elapsed < .seconds(1), "\(scene) \(size): \(frames.count) frames in \(elapsed)")
            }
        }
        print("WorkingMouse: decoded all 438 frames in \(total)")
    }
}

/// Renders the scenes and checks the pixels: every rendered colour is a palette colour (no
/// anti-aliasing, no blending), and the drawing is the frame's grid at whole points.
@MainActor
@Suite("Working mouse rendering (#185)")
struct WorkingMouseRenderingTests {
    private struct Pixel: Hashable {
        let r: Int, g: Int, b: Int
        init(_ rgba: RGBA) {
            r = Int((rgba.red * 255).rounded()); g = Int((rgba.green * 255).rounded()); b = Int((rgba.blue * 255).rounded())
        }
        init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
        func near(_ other: Pixel) -> Bool { abs(r - other.r) <= 2 && abs(g - other.g) <= 2 && abs(b - other.b) <= 2 }
    }

    private func pixels(of image: CGImage) -> [[Pixel]] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4
                return Pixel(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
            }
        }
    }

    @Test(arguments: WorkingMouse.Scene.allCases, [ColorScheme.light, .dark])
    func everyPixelIsAPaletteColourOnWholePoints(scene: WorkingMouse.Scene, scheme: ColorScheme) throws {
        for size in WorkingMouse.Size.allCases {
            let scale = 2
            let background = scheme == .light ? Palette.background.light : Palette.background.dark
            let view = SpriteCanvas(sprite: WorkingMouse.still(scene, size: size), scale: scale, palette: WorkingMouse.palette(for: .ultramarine))
                .padding(CGFloat(scale))
                .background(background.color)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let grid = pixels(of: image)
            #expect(grid.count == (size.pixels.height + 2) * scale)
            // In dark mode the ink glyph draws in the light ink (#192).
            var palette = WorkingMouse.palette(for: .ultramarine)
            if scheme == .dark { palette[PixelMouse.inkGlyph] = PixelMouse.ink.dark }
            var allowed = Set(palette.values.map(Pixel.init))
            allowed.insert(Pixel(background))
            let sprite = WorkingMouse.still(scene, size: size)
            var mismatches = 0
            for (y, row) in grid.enumerated() {
                for (x, pixel) in row.enumerated() {
                    #expect(allowed.contains { $0.near(pixel) }, "\(scene) \(size) \(scheme): a blended pixel at \(x), \(y)")
                    // Inside the frame, each point shows its sprite pixel's colour.
                    let sx = x / scale - 1, sy = y / scale - 1
                    guard sx >= 0, sy >= 0, sx < sprite.width, sy < sprite.height else { continue }
                    let glyph = Array(sprite.rows[sy])[sx]
                    if glyph != ".", let colour = palette[glyph], !Pixel(colour).near(pixel) { mismatches += 1 }
                }
            }
            #expect(mismatches == 0, "\(scene) \(size) \(scheme): \(mismatches) points off the grid")
        }
    }
}
