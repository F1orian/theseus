@testable import ArtifactsFeature
import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Renders the library grid at iPhone and iPad widths, light and dark, to PNGs for review (#180;
/// not an assertion suite). Opt-in: `THESEUS_ARTIFACT_SNAPSHOTS=<dir> swift test --filter LibrarySnapshotRenders`.
@MainActor
@Suite("Artifacts library renders", .enabled(if: ProcessInfo.processInfo.environment["THESEUS_ARTIFACT_SNAPSHOTS"] != nil))
struct LibrarySnapshotRenders {
    let directory = URL(filePath: ProcessInfo.processInfo.environment["THESEUS_ARTIFACT_SNAPSHOTS"] ?? NSTemporaryDirectory())

    @Test(arguments: [(CGFloat(393), ColorScheme.light), (393, .dark), (1024, .light), (1024, .dark)])
    func grid(width: CGFloat, scheme: ColorScheme) throws {
        let kinds: [(Artifact.Kind, String)] = [
            (.webPage, "Tip Calculator"), (.image, "Sun icon"), (.diagram, "Flowchart"),
            (.component, "Counter Button"), (.document, "Weekend Trip Checklist"), (.code, "water.py"),
        ]
        let items = kinds.enumerated().map { index, entry in
            ArtifactLibrary.Item(
                chatID: "c\(index)", chatTitle: "Chat",
                artifact: Artifact(messageID: "m\(index)", index: 0, kind: entry.0, language: nil, title: entry.1, content: ""),
                versionCount: index % 2 + 1, date: Date(timeIntervalSinceNow: -Double(index) * 3600)
            )
        }
        let view = LazyVGrid(columns: ArtifactsLibraryView.columns, spacing: Spacing.l) {
            ForEach(items) { LibraryCell(item: $0) }
        }
        .padding(Spacing.l)
        .frame(width: width)
        .background(scheme == .dark ? Palette.background.dark.color : Palette.background.light.color)
        .environment(\.colorScheme, scheme)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = directory.appending(path: "library-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
