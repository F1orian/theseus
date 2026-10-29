#if canImport(AppKit)
import AppKit
import SwiftUI

/// Hosts a SwiftUI view in an on-screen window and reads back what it draws, animations
/// included: `cacheDisplay` captures the rendered (presentation) state, so a test can sample
/// frames while a transition runs (#191, #194).
@MainActor
final class HostingProbe<Content: View> {
    let host: NSHostingView<Content>
    let window: NSWindow
    let size: CGSize

    init(_ content: Content, size: CGSize) {
        self.size = size
        host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Ordered in, so the display link ticks and animations run in real time.
        window.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    /// The current frame.
    func frame() -> Pixels {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return Pixels(rep.cgImage!, points: size)
    }

    /// Samples a frame about every `interval` for `duration`, calling `sample` with each.
    func run(for duration: Duration, every interval: Duration = .milliseconds(16), _ sample: (Pixels) -> Void = { _ in }) async {
        let clock = ContinuousClock()
        let end = clock.now + duration
        repeat {
            sample(frame())
            try? await Task.sleep(for: interval)
        } while clock.now < end
    }
}

/// An RGBA8 copy of a frame, addressed in points.
struct Pixels: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Pixels per point.
    let scale: Double
    let image: CGImage
    private let bytes: [UInt8]

    init(_ image: CGImage, points: CGSize) {
        self.image = image
        width = image.width
        height = image.height
        scale = Double(image.width) / points.width
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// The colour at pixel (`x`, `y`), counted from the top left, as 0…255 RGB.
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// How dark the pixel is against white: 0 (white) … 1 (black).
    func darkness(_ x: Int, _ y: Int) -> Double {
        let (r, g, b) = rgb(x, y)
        return 1 - Double(r + g + b) / (3 * 255)
    }

    /// The summed darkness in `rect` (points), in units of fully black points.
    func ink(in rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
        var sum = 0.0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) { sum += darkness(x, y) }
        }
        return sum / (scale * scale)
    }

    func png() -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

/// Writes frames for the evidence strips when `THESEUS_PROBE_DIR` is set (`<dir>/<name>-NNN.png`).
@MainActor
struct ProbeEvidence {
    let name: String
    private(set) var count = 0
    private let directory: URL?

    init(_ name: String) {
        self.name = name
        directory = ProcessInfo.processInfo.environment["THESEUS_PROBE_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    mutating func save(_ pixels: Pixels, note: String = "") {
        guard let directory else { return }
        let file = directory.appending(path: String(format: "%@-%03d%@.png", name, count, note.isEmpty ? "" : "-\(note)"))
        try? pixels.png().write(to: file)
        count += 1
    }
}
#endif
