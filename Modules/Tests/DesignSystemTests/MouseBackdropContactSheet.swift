@testable import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Every pose, petting frame and working-mouse scene (both sizes, the Reduce Motion still) on the
/// mouse backdrop, in light and dark, as contact sheets for review (#192). Each mouse gets a cell
/// wide enough that neighbouring backdrops don't meet. Opt-in:
/// `THESEUS_MOUSE_BACKDROP_SHEET=<dir> swift test --package-path Modules --filter MouseBackdropContactSheet`.
@MainActor
@Suite("Mouse backdrop contact sheet", .enabled(if: ProcessInfo.processInfo.environment["THESEUS_MOUSE_BACKDROP_SHEET"] != nil))
struct MouseBackdropContactSheet {
    let directory = URL(filePath: ProcessInfo.processInfo.environment["THESEUS_MOUSE_BACKDROP_SHEET"] ?? NSTemporaryDirectory())

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

    private func cell(_ title: String, text: RGBA, @ViewBuilder _ mouse: () -> some View) -> some View {
        VStack(spacing: 6) {
            mouse()
                .padding(28)
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(text.color)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func everyMouse(scheme: ColorScheme, reduceTransparency: Bool) throws {
        let background = scheme == .light ? Palette.background.light : Palette.background.dark
        let text = scheme == .light ? Palette.textSecondary.light : Palette.textSecondary.dark
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 4, alignment: .bottom)]
        let wide = [GridItem(.adaptive(minimum: 250), spacing: 4, alignment: .bottom)]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            Text("#192 mouse backdrop · \(scheme == .light ? "light (draws nothing)" : "dark")\(reduceTransparency ? " · Reduce Transparency" : "") · poses at 3 pt/px, compact at 2, large at 3")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(text.color)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(PixelMouse.Pose.allCases) { pose in
                    cell(pose.rawValue, text: text) { PixelMouse(pose: pose, scale: 3) }
                }
                ForEach(PixelMouse.Frame.allCases, id: \.self) { frame in
                    cell(frame.rawValue, text: text) {
                        SpriteCanvas(sprite: frame.sprite, scale: 3).mouseBackdropBackground(scale: 3)
                    }
                }
                cell("pettable head", text: text) { PettableMouse(.pose(.head), scale: 2) }
                cell("running", text: text) { PixelMouseRunning(scale: 2) }
                ForEach(WorkingMouse.Scene.allCases) { scene in
                    cell(scene.rawValue, text: text) { WorkingMouse(scene, isAnimating: false) }
                }
            }
            LazyVGrid(columns: wide, alignment: .leading, spacing: 4) {
                ForEach(WorkingMouse.Scene.allCases) { scene in
                    cell("\(scene.rawValue) large", text: text) { WorkingMouse(scene, size: .large, isAnimating: false) }
                }
            }
        }
        .frame(width: 1040)
        .padding(16)
        .background(background.color)
        .mouseBackdrop()
        .environment(\.colorScheme, scheme)
        .environment(\._accessibilityReduceTransparency, reduceTransparency)
        try write(sheet, name: "backdrop-\(scheme == .light ? "light" : "dark")\(reduceTransparency ? "-reduce-transparency" : "")")
    }
}
