import Foundation
import Persistence
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// One thing another app shared, loaded from its `NSItemProvider` (PLAT-04).
struct SharedContent: Identifiable, Sendable {
    enum Kind: Sendable {
        case text(String)
        case url(URL)
        case image(Data, filename: String, contentType: String?)
        case file(Data, filename: String, contentType: String?)
    }

    let id = UUID()
    let kind: Kind

    var inboxItem: ShareInbox.Item {
        switch kind {
        case .text(let text): .text(text)
        case .url(let url): .url(url)
        case .image(let data, let filename, let contentType): .file(data, filename: filename, contentType: contentType)
        case .file(let data, let filename, let contentType): .file(data, filename: filename, contentType: contentType)
        }
    }

    var byteCount: Int {
        switch kind {
        case .text, .url: 0
        case .image(let data, _, _), .file(let data, _, _): data.count
        }
    }
}

/// Loads what the share sheet handed over: images, files, web links and text, in that order of
/// preference per item. Main-actor bound because the share sheet's items aren't Sendable; the
/// providers' completion handlers are, and only resume continuations.
@MainActor
enum SharedContentLoader {
    /// Shares above this size are refused (the extension's memory is limited, and Servers cap
    /// uploads well below it).
    static let maxTotalBytes = 100 * 1_000_000

    /// What one `NSExtensionItem` carries, pulled out on the main actor (the item isn't Sendable).
    struct Item {
        var providers: [NSItemProvider]
        /// The item's own text (e.g. a web page's title), used when no provider loads.
        var text: String?

        init(_ item: NSExtensionItem) {
            providers = item.attachments ?? []
            text = item.attributedContentText?.string
        }
    }

    static func load(_ items: [Item]) async -> [SharedContent] {
        var contents: [SharedContent] = []
        for item in items {
            var loadedSomething = false
            for provider in item.providers {
                if let content = await load(provider) {
                    contents.append(content)
                    loadedSomething = true
                }
            }
            if !loadedSomething, let text = item.text, !text.isEmpty {
                contents.append(SharedContent(kind: .text(text)))
            }
        }
        return contents
    }

    static func load(_ provider: NSItemProvider) async -> SharedContent? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let (data, type) = await data(from: provider, conformingTo: .image) {
            let filename = filename(provider, type: type, fallback: "Photo")
            return SharedContent(kind: .image(data, filename: filename, contentType: type.preferredMIMEType))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await url(from: provider), url.scheme?.hasPrefix("http") == true {
            return SharedContent(kind: .url(url))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let text = await text(from: provider) {
            return SharedContent(kind: .text(text))
        }
        if let (data, type) = await data(from: provider, conformingTo: .data) {
            let filename = filename(provider, type: type, fallback: "File")
            return type.conforms(to: .image)
                ? SharedContent(kind: .image(data, filename: filename, contentType: type.preferredMIMEType))
                : SharedContent(kind: .file(data, filename: filename, contentType: type.preferredMIMEType))
        }
        return nil
    }

    private static func filename(_ provider: NSItemProvider, type: UTType, fallback: String) -> String {
        let base = provider.suggestedName ?? fallback
        guard (base as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    /// The file's bytes and its most specific type.
    private static func data(from provider: NSItemProvider, conformingTo base: UTType) async -> (Data, UTType)? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: base) } ?? base
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // The file only exists inside this callback.
                let data = url.flatMap { try? Data(contentsOf: $0) }
                continuation.resume(returning: data.map { ($0, type) })
            }
        }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { value, _ in continuation.resume(returning: value) }
        }
    }
}
