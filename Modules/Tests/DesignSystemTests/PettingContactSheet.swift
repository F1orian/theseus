@testable import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Renders every petting reaction frame by frame as one contact sheet for review (#174; not an
/// assertion suite). Opt-in: `THESEUS_PETTING_SHEET=<dir> swift test --filter PettingContactSheet`.
@MainActor
@Suite("Petting contact sheet", .enabled(if: ProcessInfo.processInfo.environment["THESEUS_PETTING_SHEET"] != nil))
struct PettingContactSheet {
    @Test func render() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["THESEUS_PETTING_SHEET"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kinds: [(String, PettableMouse.Kind, Int)] = [("head", .pose(.head), 3), ("sit", .pose(.sit), 3), ("running", .running(label: "Thinking"), 2)]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, entry in
                let (name, kind, scale) = entry
                ForEach(MouseReaction.allCases, id: \.self) { reaction in
                    HStack(spacing: 6) {
                        Text("\(name) · \(reaction.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 130, alignment: .leading)
                        ForEach(Array(reaction.frames(for: kind).enumerated()), id: \.offset) { _, frame in
                            FrameView(frame: frame, kind: kind, scale: scale)
                                .frame(width: 96, height: 72, alignment: .bottomLeading)
                                .padding(.leading, 8)
                                .background(Palette.background.light.color)
                                .clipped()
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("\(name) · curl (long press)").font(.system(size: 11, design: .monospaced)).frame(width: 130, alignment: .leading)
                    FrameView(frame: MouseFrame(drawing: .pose(.sleep)), kind: kind, scale: scale)
                        .frame(width: 96, height: 72, alignment: .bottomLeading)
                        .padding(.leading, 8)
                        .background(Palette.background.light.color)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let url = directory.appending(path: "174-petting-frames.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
