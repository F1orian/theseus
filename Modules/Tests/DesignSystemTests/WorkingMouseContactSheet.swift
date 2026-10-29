@testable import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Renders every working-mouse scene frame by frame, at both sizes, in light and dark (the ink glyph
/// in its dark-mode grey, #192), plus the still frames in every accent, as contact sheets for review (#185; like
/// `PettingContactSheet`). Opt-in:
/// `THESEUS_WORKING_MOUSE_SHEET=<dir> swift test --package-path Modules --filter WorkingMouseContactSheet`.
@MainActor
@Suite("Working mouse contact sheet", .enabled(if: ProcessInfo.processInfo.environment["THESEUS_WORKING_MOUSE_SHEET"] != nil))
struct WorkingMouseContactSheet {
    let directory = URL(filePath: ProcessInfo.processInfo.environment["THESEUS_WORKING_MOUSE_SHEET"] ?? NSTemporaryDirectory())

    private func write(_ view: some View, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = directory.appending(path: "\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test(arguments: WorkingMouse.Size.allCases, [ColorScheme.light, .dark])
    func everyFrame(size: WorkingMouse.Size, scheme: ColorScheme) throws {
        let scale = 2
        let background = scheme == .light ? Palette.background.light : Palette.background.dark
        let text = scheme == .light ? Palette.textSecondary.light : Palette.textSecondary.dark
        let sheet = VStack(alignment: .leading, spacing: 8) {
            Text("#185 working mouse · \(size.rawValue) \(size.pixels.width)×\(size.pixels.height) px · \(scale) pt/px · \(scheme == .light ? "light" : "dark") · ▣ = Reduce Motion still")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(text.color)
            ForEach(WorkingMouse.Scene.allCases) { scene in
                HStack(alignment: .top, spacing: 6) {
                    Text(scene.rawValue)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(text.color)
                        .frame(width: 104, alignment: .leading)
                    let frames = WorkingMouse.sprites(scene, size: size)
                    let still = WorkingMouse.stillIndex(of: scene, size: size)
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, sprite in
                        VStack(spacing: 1) {
                            SpriteCanvas(sprite: sprite, scale: scale, palette: WorkingMouse.palette(for: .verdigris))
                                .padding(CGFloat(scale))
                            Text(index == still ? "▣ \(index)" : "\(index)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(text.color)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(background.color)
        .environment(\.colorScheme, scheme)
        try write(sheet, name: "scenes-\(size.rawValue)-\(scheme == .light ? "light" : "dark")")
    }

    /// The Reduce Motion stills in each accent (#179): only `v`/`V` change.
    @Test func stillsInEveryAccent() throws {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(AccentChoice.allCases) { choice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.displayName).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    HStack(spacing: 6) {
                        ForEach(WorkingMouse.Scene.allCases) { scene in
                            SpriteCanvas(sprite: WorkingMouse.still(scene, size: .compact), scale: 2, palette: WorkingMouse.palette(for: choice))
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(WorkingMouse.Scene.allCases.prefix(9)) { scene in
                            SpriteCanvas(sprite: WorkingMouse.still(scene, size: .large), scale: 1, palette: WorkingMouse.palette(for: choice))
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(WorkingMouse.Scene.allCases.dropFirst(9)) { scene in
                            SpriteCanvas(sprite: WorkingMouse.still(scene, size: .large), scale: 1, palette: WorkingMouse.palette(for: choice))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.background.light.color)
        try write(sheet, name: "stills-accents")
    }
}
