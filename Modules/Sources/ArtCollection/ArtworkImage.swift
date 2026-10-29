import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import Synchronization
import SwiftUI

/// Decoded artwork images, shared by every view. ImageIO downsamples while decoding (a 1600 px
/// JPEG is ~7 MB decoded), and the cache keeps the most recent images up to `byteLimit`.
final class ArtworkImageCache: Sendable {
    static let shared = ArtworkImageCache()

    private struct Key: Hashable {
        let id: String
        let maxPixelSize: Int
    }

    private struct State {
        var images: [Key: CGImage] = [:]
        var order: [Key] = []
        var bytes = 0
    }

    private let state = Mutex(State())
    /// About four full-size paintings, or every thumbnail on About › The Collection.
    private let byteLimit = 32 * 1024 * 1024

    /// The decode sizes in use: the smallest that covers the request, so close sizes share one image.
    static let buckets = [480, 960, 1600]

    static func bucket(for pixels: Int?) -> Int {
        guard let pixels else { return buckets[buckets.count - 1] }
        return buckets.first { $0 >= pixels } ?? buckets[buckets.count - 1]
    }

    /// A cached image, without decoding.
    func cached(for artwork: Artwork, maxPixelSize: Int?) -> CGImage? {
        let key = Key(id: artwork.id, maxPixelSize: Self.bucket(for: maxPixelSize))
        return state.withLock { $0.images[key] }
    }

    func image(for artwork: Artwork, maxPixelSize: Int?) -> CGImage? {
        let key = Key(id: artwork.id, maxPixelSize: Self.bucket(for: maxPixelSize))
        if let hit = state.withLock({ $0.images[key] }) { return hit }
        guard let url = artwork.fileURL, let image = Self.decode(url, maxPixelSize: key.maxPixelSize) else { return nil }
        state.withLock { state in
            guard state.images[key] == nil else { return }
            state.order.append(key)
            state.images[key] = image
            state.bytes += image.bytesPerRow * image.height
            // Evict the oldest, but never the image just decoded.
            while state.bytes > byteLimit, state.order.count > 1 {
                let oldest = state.order.removeFirst()
                if let evicted = state.images.removeValue(forKey: oldest) {
                    state.bytes -= evicted.bytesPerRow * evicted.height
                }
            }
        }
        return image
    }

    static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// How an image of `imageSize` fills `container` (aspect fill) with `focal` as central as the
/// image's edges allow: the image's frame in the container's coordinates.
enum FocalCrop {
    static func frame(imageSize: CGSize, container: CGSize, focal: UnitPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        func offset(_ containerLength: CGFloat, _ length: CGFloat, _ focal: CGFloat) -> CGFloat {
            let centred = containerLength / 2 - focal * length
            return min(max(centred, containerLength - length), 0)
        }
        return CGRect(
            x: offset(container.width, size.width, focal.x),
            y: offset(container.height, size.height, focal.y),
            width: size.width,
            height: size.height
        )
    }
}

/// An artwork filling its frame (aspect fill around a focal point), decoded off the main thread
/// at the size it's shown. Shows the work's average colour until the image is ready. Decorative.
struct ArtworkImage: View {
    let artwork: Artwork
    let focal: UnitPoint
    @Environment(\.displayScale) private var displayScale
    /// The decoded image, keyed by artwork and decode size so a reused view never shows a stale one.
    @State private var loaded: (key: String, image: CGImage)?

    var body: some View {
        GeometryReader { proxy in
            let frame = FocalCrop.frame(imageSize: artwork.pixelSize, container: proxy.size, focal: focal)
            let pixels = Int((max(frame.width, frame.height) * displayScale).rounded(.up))
            let key = "\(artwork.id)@\(ArtworkImageCache.bucket(for: pixels))"
            let image = loaded?.key == key ? loaded?.image : ArtworkImageCache.shared.cached(for: artwork, maxPixelSize: pixels)
            ZStack(alignment: .topLeading) {
                artwork.placeholder.color
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .task(id: key) {
                guard proxy.size.width > 0, proxy.size.height > 0, image == nil else { return }
                guard let decoded = await artwork.loadImage(maxPixelSize: pixels), !Task.isCancelled else { return }
                loaded = (key, decoded)
            }
        }
        .accessibilityHidden(true)
    }
}
