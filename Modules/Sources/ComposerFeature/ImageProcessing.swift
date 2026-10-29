public import CoreGraphics
public import Foundation
import ImageIO
public import OpenWebUIKit
import UniformTypeIdentifiers

/// A decoded image, safe to hand across actors (CGImage is immutable).
public struct DecodedImage: @unchecked Sendable, Equatable {
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public static func == (lhs: DecodedImage, rhs: DecodedImage) -> Bool {
        lhs.cgImage === rhs.cgImage
    }
}

/// Prepares photos for upload (ATT-02, ADR 0042): HEIC/HEIF and other formats vision APIs don't
/// take become JPEG, and images larger than the Server's `image_compression` bound (or
/// `defaultMaxDimension` when the admin set none) are scaled down, honouring EXIF orientation.
/// Upright JPEG, PNG, GIF and WebP within bounds are uploaded untouched; rotated photos are
/// re-encoded upright because vision APIs ignore EXIF orientation.
public enum ImageProcessing {
    /// The longest edge Theseus uploads when the Server sets no bound.
    public static let defaultMaxDimension = 2048
    static let jpegQuality = 0.85

    public struct Prepared: Sendable, Equatable {
        public var upload: FileUpload
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// The bytes were re-encoded (converted and/or scaled).
        public var wasReencoded: Bool
    }

    /// Formats uploaded as they are when they fit.
    static let passthroughTypes: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier, "org.webmproject.webp"]

    /// Returns `nil` when `data` isn't a decodable image.
    public static func prepare(_ data: Data, filename: String, limits: FileLimits) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // Orientations 5–8 rotate by 90°: the displayed size swaps width and height.
        if (5...8).contains(orientation) { swap(&width, &height) }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let maxSide = targetLongestEdge(width: width, height: height, limits: limits)
        let fits = max(width, height) <= maxSide
        let rotated = orientation != 1
        if fits, !rotated, passthroughTypes.contains(type) {
            let mime = UTType(type)?.preferredMIMEType ?? "image/jpeg"
            return Prepared(upload: FileUpload(data: data, filename: filename, contentType: mime), pixelWidth: width, pixelHeight: height, wasReencoded: false)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Keep transparency for PNGs; everything else becomes JPEG.
        let keepsPNG = type == UTType.png.identifier && image.alphaInfo.hasAlpha
        let outputType = keepsPNG ? UTType.png : UTType.jpeg
        guard let encoded = encode(image, as: outputType) else { return nil }
        let name = renamed(filename, to: keepsPNG ? "png" : "jpg")
        return Prepared(
            upload: FileUpload(data: encoded, filename: name, contentType: keepsPNG ? "image/png" : "image/jpeg"),
            pixelWidth: image.width,
            pixelHeight: image.height,
            wasReencoded: true
        )
    }

    /// The longest edge allowed by the Server's width/height bound (or the default).
    static func targetLongestEdge(width: Int, height: Int, limits: FileLimits) -> Int {
        guard limits.imageMaxWidth != nil || limits.imageMaxHeight != nil else { return defaultMaxDimension }
        let scaleW = limits.imageMaxWidth.map { Double($0) / Double(max(width, 1)) } ?? 1
        let scaleH = limits.imageMaxHeight.map { Double($0) / Double(max(height, 1)) } ?? 1
        let scale = min(scaleW, scaleH, 1)
        return max(1, Int((Double(max(width, height)) * scale).rounded(.down)))
    }

    /// A small thumbnail for chips and previews.
    public static func thumbnail(_ data: Data, maxPixelSize: Int = 320) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(DecodedImage.init)
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func renamed(_ filename: String, to ext: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return "\(base.isEmpty ? "Photo" : base).\(ext)"
    }
}

extension CGImageAlphaInfo {
    var hasAlpha: Bool {
        switch self {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
