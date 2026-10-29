@testable import DesignSystem
import Foundation
import SwiftUI
import Testing

/// #192: the halo is gone; on dark surfaces every mouse sits on a soft radial backdrop instead, and
/// freestanding ink marks turn light grey.
@Suite("Mouse backdrop and light ink (#192)")
struct MouseBackdropTests {
    @Test func theBackdropShowsOnlyInDarkMode() {
        #expect(PixelMouse.backdropFill(colorScheme: .light, reduceTransparency: false) == nil)
        #expect(PixelMouse.backdropFill(colorScheme: .light, reduceTransparency: true) == nil)
        #expect(PixelMouse.backdropFill(colorScheme: .dark, reduceTransparency: false) == .gradient)
        #expect(PixelMouse.backdropFill(colorScheme: .dark, reduceTransparency: true) == .solid, "Reduce Transparency: a solid fill")
    }

    /// The approved mock-up (option B): Graphite at about 0.27 in the middle, fading to nothing.
    @Test func theGradientFadesFromTheMockUpsOpacityToNothing() {
        #expect(PixelMouse.backdropColor == RGBA(hex: 0x4A505B))
        #expect(PixelMouse.backdropOpacity == 0.27)
        let stops = PixelMouse.backdropStops
        #expect(stops.first?.location == 0 && stops.last?.location == 1)
        #expect(stops.map(\.location) == stops.map(\.location).sorted())
        // The solid fill is subtle: a touch lighter than Nocturne, darker than Slate.
        let solid = PixelMouse.backdropSolid
        #expect(solid.alpha == 1)
        #expect(solid.relativeLuminance > Palette.background.dark.relativeLuminance)
        #expect(solid.relativeLuminance < Palette.surface.dark.relativeLuminance + 0.002)
        #expect(RGBA.contrast(solid, Palette.background.dark) < 1.15)
    }

    @Test func thePaddingIsEightSpritePixelsWithinBounds() {
        #expect(PixelMouse.backdropPadding(scale: 1) == 12)
        #expect(PixelMouse.backdropPadding(scale: 2) == 16)
        #expect(PixelMouse.backdropPadding(scale: 3) == 24)
        #expect(PixelMouse.backdropPadding(scale: 6) == 28)
    }

    @Test func theInkIsUmberInLightAndPewterInDark() {
        #expect(PixelMouse.palette[PixelMouse.inkGlyph] == PixelMouse.palette["K"], "light mode is unchanged")
        #expect(PixelMouse.ink.light == PixelMouse.palette["K"])
        #expect(PixelMouse.ink.dark == Palette.textSecondary.dark)
        #expect(PixelMouse.ink.dark == RGBA(hex: 0xB4B7BF))
        // Umber disappears on Nocturne; the light ink reads.
        #expect(RGBA.contrast(PixelMouse.ink.light, Palette.background.dark) < 1.5)
        #expect(RGBA.contrast(PixelMouse.ink.dark, Palette.background.dark) > 7)
    }

    /// Only freestanding marks are ink: no pose or petting frame has any (the mouse's own outline
    /// and the props' stay `K`).
    @Test func posesAndPettingFramesKeepTheirOutline() {
        for pose in PixelMouse.Pose.allCases {
            #expect(!pose.sprite.rows.joined().contains(PixelMouse.inkGlyph), "\(pose)")
        }
        for frame in PixelMouse.Frame.allCases {
            #expect(!frame.sprite.rows.joined().contains(PixelMouse.inkGlyph), "\(frame)")
        }
    }
}

/// Renders mice with and without the backdrop: layout, light mode and the dark-mode pixels.
@MainActor
@Suite("Mouse backdrop rendering (#192)")
struct MouseBackdropRenderingTests {
    private struct Pixel: Equatable {
        let r: Int, g: Int, b: Int
        init(_ rgba: RGBA) {
            r = Int((rgba.red * 255).rounded()); g = Int((rgba.green * 255).rounded()); b = Int((rgba.blue * 255).rounded())
        }
        init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
        func near(_ other: Pixel, _ tolerance: Int = 2) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
        }
        var sum: Int { r + g + b }
    }

    /// Every kind of mouse the screens draw.
    enum Mouse: String, CaseIterable, Sendable {
        case pose, head, running, pettableHead, pettableWorking, workingCompact, workingLarge, lockup

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .pose: PixelMouse(pose: .sleep, scale: 3)
            case .head: PixelMouse(pose: .head, scale: 2)
            case .running: PixelMouseRunning(scale: 2)
            case .pettableHead: PettableMouse(.pose(.head), scale: 2)
            case .pettableWorking: PettableMouse(.working(.webSearch, label: "Searching the web"), scale: 2, isAnimating: false)
            case .workingCompact: WorkingMouse(.thinking, isAnimating: false)
            case .workingLarge: WorkingMouse(.waitingOnYou, size: .large, isAnimating: false)
            case .lockup: BrandLockup(size: 34)
            }
        }
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

    /// `mouse` with `margin` points of `background` around it, at 1 px per point.
    private func render(_ mouse: Mouse, scheme: ColorScheme, backdrop: Bool, reduceTransparency: Bool = false, margin: CGFloat = 40) throws -> [[Pixel]] {
        let background = scheme == .light ? Palette.background.light : Palette.background.dark
        let view = mouse.view
            .padding(margin)
            .background(background.color)
            .mouseBackdrop(backdrop)
            .environment(\.colorScheme, scheme)
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            // The runner holds one frame, so two renders compare pixel for pixel.
            .environment(\._accessibilityReduceMotion, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return pixels(of: try #require(renderer.cgImage))
    }

    private func fittingSize(_ view: some View) -> CGSize {
        #if canImport(UIKit)
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1000, height: 1000))
        #else
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1000, height: 1000))
        #endif
    }

    /// The backdrop never changes the frame a mouse takes in a hosting view, in either appearance.
    @Test(arguments: Mouse.allCases, [ColorScheme.light, .dark])
    func theBackdropDoesNotChangeTheFrame(mouse: Mouse, scheme: ColorScheme) {
        let plain = fittingSize(mouse.view.environment(\.colorScheme, scheme))
        let backed = fittingSize(mouse.view.mouseBackdrop().environment(\.colorScheme, scheme))
        let solid = fittingSize(mouse.view.mouseBackdrop().environment(\.colorScheme, scheme).environment(\._accessibilityReduceTransparency, true))
        #expect(plain.width > 0 && plain.height > 0)
        #expect(backed == plain, "\(mouse) \(scheme)")
        #expect(solid == plain, "\(mouse) \(scheme), Reduce Transparency")
    }

    /// Light mode: the backdrop draws nothing, pixel for pixel.
    @Test(arguments: Mouse.allCases)
    func lightModeIsUnchanged(mouse: Mouse) throws {
        #expect(try render(mouse, scheme: .light, backdrop: true) == render(mouse, scheme: .light, backdrop: false))
    }

    /// Dark mode: a soft glow past the drawing's frame (it isn't clipped to it), strongest near the
    /// mouse and gone before the corners; the mouse itself is drawn the same.
    @Test(arguments: Mouse.allCases)
    func darkModeGlowsOutsideTheFrame(mouse: Mouse) throws {
        let margin: CGFloat = 40
        let plain = try render(mouse, scheme: .dark, backdrop: false, margin: margin)
        let backed = try render(mouse, scheme: .dark, backdrop: true, margin: margin)
        let nocturne = Pixel(Palette.background.dark)
        let height = plain.count, width = plain[0].count
        let m = Int(margin)
        // Just outside the mouse's frame, centred on each side: lighter than Nocturne.
        // (The lockup's backdrop is the mouse's, on its left, not the wordmark's.)
        let probes = mouse == .lockup
            ? [(m - 4, height / 2)]
            : [(width / 2, m - 4), (width / 2, height - m + 3), (m - 4, height / 2), (width - m + 3, height / 2)]
        for (x, y) in probes {
            #expect(plain[y][x] == nocturne || plain[y][x].near(nocturne), "\(mouse): the plain render is bare at \(x), \(y)")
            #expect(backed[y][x].sum > nocturne.sum + 3, "\(mouse): the backdrop shows at \(x), \(y): \(backed[y][x])")
            // Soft, not a line: well under the gradient's peak over Nocturne.
            #expect(backed[y][x].sum < nocturne.sum + 60)
        }
        // The corners of the canvas, beyond the ellipse, stay Nocturne.
        for (x, y) in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
            #expect(backed[y][x].near(nocturne), "\(mouse): \(backed[y][x]) at the corner")
        }
    }

    /// Reduce Transparency: one solid, quiet colour instead of the gradient.
    @Test(arguments: [Mouse.head, .workingCompact, .pettableHead])
    func reduceTransparencyDrawsASolidFill(mouse: Mouse) throws {
        let margin: CGFloat = 40
        let solid = try render(mouse, scheme: .dark, backdrop: true, reduceTransparency: true, margin: margin)
        let height = solid.count, width = solid[0].count
        let m = Int(margin)
        let fill = Pixel(PixelMouse.backdropSolid)
        for (x, y) in [(width / 2, m - 3), (width / 2, height - m + 2), (m - 3, height / 2), (width - m + 2, height / 2)] {
            #expect(solid[y][x].near(fill), "\(mouse): \(solid[y][x]) at \(x), \(y)")
        }
        #expect(solid[1][1].near(Pixel(Palette.background.dark)))
    }

    /// The `?` of "waiting on you" draws in the light ink in dark mode and in umber in light.
    @Test(arguments: [ColorScheme.light, .dark])
    func theQuestionMarkIsLightInkInDark(scheme: ColorScheme) throws {
        let sprite = WorkingMouse.still(.waitingOnYou, size: .large)
        let rows = sprite.rows.map(Array.init)
        let (y, x) = try #require(rows.indices.lazy.compactMap { y in rows[y].firstIndex(of: PixelMouse.inkGlyph).map { (y, $0) } }.first)
        let scale = 3
        let view = WorkingMouse(.waitingOnYou, size: .large, isAnimating: false)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let grid = pixels(of: try #require(renderer.cgImage))
        let pixel = grid[y * scale + 1][x * scale + 1]
        #expect(pixel.near(Pixel(scheme == .dark ? PixelMouse.ink.dark : PixelMouse.ink.light)), "\(pixel)")
        // An outline pixel stays umber either way.
        let (ky, kx) = try #require(rows.indices.lazy.compactMap { y in rows[y].firstIndex(of: "K").map { (y, $0) } }.first)
        #expect(grid[ky * scale + 1][kx * scale + 1].near(Pixel(PixelMouse.palette["K"]!)))
    }
}
