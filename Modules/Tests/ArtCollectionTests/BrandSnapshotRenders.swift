@testable import ArtCollection
import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Renders the brand components to PNGs for review (not an assertion suite). Opt-in:
/// `THESEUS_BRAND_SNAPSHOTS=<dir> swift test --filter BrandSnapshotRenders`.
@MainActor
@Suite("Brand snapshot renders", .enabled(if: ProcessInfo.processInfo.environment["THESEUS_BRAND_SNAPSHOTS"] != nil))
struct BrandSnapshotRenders {
    let directory = URL(filePath: ProcessInfo.processInfo.environment["THESEUS_BRAND_SNAPSHOTS"] ?? NSTemporaryDirectory())

    func render(_ name: String, scale: CGFloat = 2, @ViewBuilder _ view: () -> some View) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view())
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let url = directory.appending(path: "\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// ImageRenderer draws once, before any `.task` runs, so decode what each render shows first.
    func warm(_ artworks: [Artwork]) {
        for artwork in artworks {
            for bucket in ArtworkImageCache.buckets.prefix(2) { _ = artwork.cgImage(maxPixelSize: bucket) }
        }
    }

    @Test func poses() throws {
        for scale in [2, 4] {
            for pose in PixelMouse.Pose.allCases {
                try render("pose-\(pose.rawValue)-\(scale)x", scale: 1) {
                    PixelMouse(pose: pose, scale: scale)
                        .padding(8)
                        .background(Palette.background.light.color)
                }
            }
        }
        for (index, date) in [Date(timeIntervalSinceReferenceDate: 0), Date(timeIntervalSinceReferenceDate: 0.2)].enumerated() {
            try render("running-frame\(index + 1)", scale: 1) {
                VStack(spacing: 8) {
                    PixelMouse(pose: PixelMouseRunning.frame(at: date), scale: 4)
                    Text("Thinking…").plaqueStyle(color: Palette.textTertiary)
                }
                .padding(12)
                .background(Palette.background.light.color)
            }
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func components(scheme: ColorScheme) throws {
        let suffix = scheme == .light ? "light" : "dark"
        warm([.welcome, .error] + Artwork.projectCovers.prefix(3))
        try render("framed-plaque-\(suffix)") {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                BrandLockup()
                VStack(alignment: .leading, spacing: Spacing.m) {
                    FramedArtwork(.welcome, height: 200)
                    Plaque(.welcome)
                }
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        FramedArtwork(.error, height: 220).padding(.top, 13 * 3 - 3)
                        Plaque(.error, style: .short)
                    }
                }
                HStack(alignment: .top, spacing: Spacing.l) {
                    ForEach(Array(Artwork.projectCovers.prefix(3))) { artwork in
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            FramedArtwork(artwork, height: 90, mat: 5)
                            Plaque(artwork, style: .compact)
                        }
                    }
                }
                HStack(spacing: Spacing.l) {
                    PixelMouse(pose: .head, scale: 2)
                    Text("Thinking…").plaqueStyle()
                    Text("Opus 5.5 ▾").plaqueStyle(color: Palette.textPrimary)
                    Circle().fill(Palette.accent.color).frame(width: 30, height: 30)
                }
            }
            .padding(Spacing.xl)
            .frame(width: 393)
            .background(scheme == .light ? Palette.background.light.color : Palette.background.dark.color)
            .environment(\.colorScheme, scheme)
        }
        warm([.welcome, .welcomeDark])
        _ = (scheme == .light ? Artwork.welcome : .welcomeDark).cgImage(maxPixelSize: 1600)
        try render("hero-\(suffix)") {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ArtworkHero(scheme == .light ? .welcome : .welcomeDark, height: 300)
                Text("Welcome to Theseus").font(Typography.display).padding(.horizontal, Spacing.l)
                    .foregroundStyle(Palette.textPrimary.color)
                PixelMouse(pose: .stand, scale: 3).padding(.horizontal, Spacing.l)
            }
            .padding(.bottom, Spacing.xl)
            .frame(width: 393)
            .background(scheme == .light ? Palette.background.light.color : Palette.background.dark.color)
            .environment(\.colorScheme, scheme)
        }
    }
}
