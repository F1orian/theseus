public import Foundation
public import OpenWebUIKit

/// Thumbnails and previews of image Attachments, by server file id (ATT-04). Images the user
/// just uploaded are seeded from the local bytes, so a sent Message shows them without a
/// round trip; others load once from `GET /api/v1/files/{id}/content`.
@MainActor
public final class AttachmentImageCache {
    public enum Size: Sendable {
        case thumbnail
        case preview

        var maxPixelSize: Int {
            switch self {
            case .thumbnail: 480
            case .preview: 2048
            }
        }
    }

    private let client: OpenWebUIClient
    private var thumbnails: [String: DecodedImage] = [:]
    private var previews: [String: DecodedImage] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// The most images kept per size before the oldest are dropped.
    private let limit = 120
    private var order: [String] = []

    public init(client: OpenWebUIClient) {
        self.client = client
    }

    /// Seeds the cache with an image's bytes (e.g. right after uploading it).
    public func store(_ data: Data, for fileID: String) {
        let raw = data
        Task.detached(priority: .userInitiated) {
            let thumbnail = ImageProcessing.thumbnail(raw, maxPixelSize: Size.thumbnail.maxPixelSize)
            await MainActor.run { [weak self] in
                if let thumbnail { self?.insert(thumbnail, for: fileID, size: .thumbnail) }
            }
        }
    }

    public func store(thumbnail: DecodedImage, for fileID: String) {
        insert(thumbnail, for: fileID, size: .thumbnail)
    }

    public func cached(_ fileID: String, size: Size = .thumbnail) -> DecodedImage? {
        switch size {
        case .thumbnail: thumbnails[fileID]
        case .preview: previews[fileID]
        }
    }

    /// The image for `fileID`, loading it from the Server if needed.
    public func image(for fileID: String, size: Size = .thumbnail) async -> DecodedImage? {
        if let cached = cached(fileID, size: size) { return cached }
        guard let data = await bytes(for: fileID) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            ImageProcessing.thumbnail(data, maxPixelSize: size.maxPixelSize)
        }.value
        if let image { insert(image, for: fileID, size: size) }
        return image
    }

    /// The raw file bytes (single-flight per id).
    public func bytes(for fileID: String) async -> Data? {
        if let running = inFlight[fileID] { return await running.value }
        let client = client
        let task = Task<Data?, Never> { try? await client.send(.fileContent(id: fileID)) }
        inFlight[fileID] = task
        let data = await task.value
        inFlight[fileID] = nil
        return data
    }

    private func insert(_ image: DecodedImage, for fileID: String, size: Size) {
        switch size {
        case .thumbnail: thumbnails[fileID] = image
        case .preview: previews[fileID] = image
        }
        order.removeAll { $0 == fileID }
        order.append(fileID)
        while order.count > limit {
            let oldest = order.removeFirst()
            thumbnails[oldest] = nil
            previews[oldest] = nil
        }
    }
}
