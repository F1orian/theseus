import CoreText
@testable import DesignSystem
import Foundation
import Testing

@Suite("Pixel mouse and plaque font (BRAND-01)")
struct PixelMouseTests {
    /// brand.md §3: the nine poses and their sizes.
    @Test func posesMatchTheBrandSpec() {
        let sizes: [PixelMouse.Pose: (Int, Int)] = [
            .sit: (25, 14), .stand: (18, 18), .run1: (27, 11), .run2: (27, 11), .peek: (17, 14),
            .read: (20, 18), .lantern: (21, 18), .sleep: (20, 13), .head: (13, 9),
        ]
        #expect(PixelMouse.Pose.allCases.count == 9)
        for pose in PixelMouse.Pose.allCases {
            let sprite = pose.sprite
            #expect(sprite.width == sizes[pose]?.0, "\(pose) width")
            #expect(sprite.height == sizes[pose]?.1, "\(pose) height")
        }
    }

    @Test(arguments: PixelMouse.Pose.allCases)
    func rowsAreRectangularAfterPadding(pose: PixelMouse.Pose) {
        let sprite = pose.sprite
        #expect(!sprite.rows.isEmpty)
        #expect(sprite.rows.allSatisfy { $0.count == sprite.width })
        // Padding only ever adds transparency on the right.
        for (raw, padded) in zip(PixelMouse.rows(for: pose), sprite.rows) {
            #expect(padded.hasPrefix(raw))
            #expect(padded.dropFirst(raw.count).allSatisfy { $0 == "." })
        }
    }

    @Test(arguments: PixelMouse.Pose.allCases)
    func everyGlyphIsInThePalette(pose: PixelMouse.Pose) {
        for row in pose.sprite.rows {
            for glyph in row where glyph != "." {
                #expect(PixelMouse.palette[glyph] != nil, "\(pose) uses \(glyph)")
            }
        }
    }

    /// The runs cover exactly the opaque pixels, so the canvas draws every pixel once.
    @Test(arguments: PixelMouse.Pose.allCases)
    func runsCoverEveryOpaquePixel(pose: PixelMouse.Pose) {
        let sprite = pose.sprite
        let opaque = sprite.rows.reduce(0) { $0 + $1.filter { $0 != "." }.count }
        #expect(sprite.runs.reduce(0) { $0 + $1.length } == opaque)
        for run in sprite.runs {
            let row = Array(sprite.rows[run.y])
            #expect(row[run.x..<(run.x + run.length)].allSatisfy { $0 == run.glyph })
        }
    }

    @Test func sizesAreWholePoints() {
        #expect(PixelMouse.size(of: .head, scale: 2) == CGSize(width: 26, height: 18))
        #expect(PixelMouse.size(of: .head, scale: 0) == CGSize(width: 13, height: 9))
        #expect(PixelMouse.largestScale(for: .head, fitting: CGSize(width: 28, height: 28)) == 2)
        #expect(PixelMouse.largestScale(for: .head, fitting: CGSize(width: 5, height: 5)) == 1)
        #expect(PixelMouse.largestScale(for: .stand, fitting: CGSize(width: 200, height: 200)) == 11)
        #expect(BrandLockup.scale(for: .sit, size: 28) == 2)
        #expect(BrandLockup.scale(for: .sit, size: 40) == 3)
    }

    @Test func runningSwapsFramesAtSixFPS() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(PixelMouseRunning.frame(at: start) == .run1)
        #expect(PixelMouseRunning.frame(at: start.addingTimeInterval(1.0 / 6 + 0.001)) == .run2)
        #expect(PixelMouseRunning.frame(at: start.addingTimeInterval(2.0 / 6 + 0.001)) == .run1)
        #expect(PixelMouseRunning.framesPerSecond >= 6 && PixelMouseRunning.framesPerSecond <= 8)
    }

    @Test func plaqueFontRegistersFromTheBundle() {
        #expect(PlaqueFont.register())
        #expect(PlaqueFont.register(), "registering twice is harmless")
        let font = CTFontCreateWithName(PlaqueFont.postScriptName as CFString, 11, nil)
        #expect(CTFontCopyPostScriptName(font) as String == PlaqueFont.postScriptName)
        #expect(PlaqueFont.licence.contains("SIL Open Font License"))
    }

    @Test func plaqueFontRegistrationIsConcurrencySafe() async {
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { PlaqueFont.register() } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 })
    }
}
