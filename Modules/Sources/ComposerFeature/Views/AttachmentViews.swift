public import ChatDomain
import DesignSystem
import Foundation
import OpenWebUIKit
public import SwiftUI

/// The composer's Attachments above the text (ATT-01, ATT-02): photo thumbnails and file cards,
/// each with a remove badge and its upload / processing state (ATT-04).
struct ComposerAttachmentStrip: View {
    let model: ComposerModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(model.attachments) { attachment in
                    Group {
                        switch attachment.kind {
                        case .image: ImageChip(attachment: attachment)
                        case .document: FileChip(attachment: attachment)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { model.remove(attachment.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.black.opacity(0.75), in: .circle)
                                // PLAT-06: a 44 pt target over the chip's corner.
                                .padding(Spacing.xs)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                        .accessibilityIdentifier("composer.attachment.remove")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.attachment")
                    // ATT-01/02: a chip pops in when picked and shrinks away when removed.
                    .motionSafeTransition(.pop)
                }
            }
            .padding(.top, Spacing.xs)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ImageChip: View {
    let attachment: ComposerAttachment

    var body: some View {
        ZStack {
            if let thumbnail = attachment.thumbnail {
                Image(decorative: thumbnail.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.recessedSurface.color
                Image(systemName: "photo").foregroundStyle(Palette.textTertiary.color)
            }
            PhaseOverlay(phase: attachment.phase)
        }
        .frame(width: 72, height: 72)
        .clipShape(.rect(cornerRadius: Radius.medium + 2))
        .accessibilityLabel(attachment.name)
    }
}

private struct FileChip: View {
    let attachment: ComposerAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(attachment.name)
                .font(Typography.caption.weight(.medium))
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.trailing, Spacing.l)
            Spacer(minLength: 0)
            HStack(spacing: Spacing.xs) {
                Text(attachment.badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(.horizontal, Spacing.xs + 2)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.separator.color))
                PhaseLabel(phase: attachment.phase)
            }
        }
        .padding(Spacing.s + 2)
        .frame(width: 150, height: 72, alignment: .topLeading)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium + 2))
        .accessibilityElement(children: .combine)
    }
}

/// A spinner or failure mark over a thumbnail.
private struct PhaseOverlay: View {
    let phase: ComposerAttachment.Phase

    var body: some View {
        switch phase {
        case .preparing, .uploading, .processing:
            ZStack {
                Color.black.opacity(0.3)
                ProgressView().tint(.white)
            }
            .accessibilityLabel("Uploading")
        case .failed(let message):
            ZStack {
                Color.black.opacity(0.45)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            }
            .accessibilityLabel(message)
        case .ready:
            EmptyView()
        }
    }
}

/// "Uploading…", "Reading…" or the failure, next to a file card's badge.
private struct PhaseLabel: View {
    let phase: ComposerAttachment.Phase

    var body: some View {
        switch phase {
        case .preparing, .uploading:
            Label("Uploading", systemImage: "arrow.up.circle").labelStyle(.compact)
        case .processing:
            Label("Reading", systemImage: "doc.text.magnifyingglass").labelStyle(.compact)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle").labelStyle(.compact)
                .foregroundStyle(Palette.destructive.color)
        case .ready:
            EmptyView()
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
        .font(.caption2)
        .foregroundStyle(Palette.textTertiary.color)
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    fileprivate static var compact: CompactLabelStyle { CompactLabelStyle() }
}

// MARK: - In the conversation (ATT-04)

/// A sent user Message's Attachments, right-aligned above its bubble: photos as rounded
/// thumbnails (tap for a full-screen preview), documents as file cards.
public struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    let images: AttachmentImageCache
    @State private var previewing: Attachment?

    public init(attachments: [Attachment], images: AttachmentImageCache) {
        self.attachments = attachments
        self.images = images
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.s) {
            let photos = attachments.filter { $0.kind == .image }
            if !photos.isEmpty {
                HStack(spacing: Spacing.s) {
                    Spacer(minLength: 48)
                    ForEach(photos) { photo in
                        Button { previewing = photo } label: {
                            AttachmentThumbnail(attachment: photo, images: images, side: photos.count == 1 ? 180 : 110)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photo.name)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("message.attachment.image")
                    }
                }
            }
            ForEach(attachments.filter { $0.kind == .document }) { document in
                HStack {
                    Spacer(minLength: 48)
                    DocumentCard(attachment: document)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        #if os(iOS)
        .fullScreenCover(item: $previewing) { attachment in
            ImagePreview(attachment: attachment, images: images)
        }
        #else
        .sheet(item: $previewing) { attachment in
            ImagePreview(attachment: attachment, images: images)
        }
        #endif
    }
}

/// A rounded image thumbnail that loads from the Server (or an inline data URL).
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let images: AttachmentImageCache
    let side: CGFloat
    @State private var image: DecodedImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.recessedSurface.color
                if failed {
                    Image(systemName: "photo").foregroundStyle(Palette.textTertiary.color)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: Radius.large - 4))
        .task(id: attachment.id) {
            image = await AttachmentImageLoading.load(attachment, from: images, size: .thumbnail)
            failed = image == nil
        }
    }
}

/// A sent document: an icon, the name and its type badge.
struct DocumentCard: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 40, height: 40)
                .background(Palette.surface.color, in: .rect(cornerRadius: Radius.small))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(Spacing.s + 2)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium + 2))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.attachment.file")
    }

    private var detail: String {
        guard let size = attachment.size else { return attachment.typeBadge }
        return "\(attachment.typeBadge) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}

/// A full-screen, zoomable photo.
struct ImagePreview: View {
    let attachment: Attachment
    let images: AttachmentImageCache
    @Environment(\.dismiss) private var dismiss
    @State private var image: DecodedImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture().onChanged { zoom = max(1, $0.magnification) }.onEnded { _ in
                        withAnimation(.snappy) { zoom = 1 }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(attachment.name)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(Spacing.l)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("attachment.preview.close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment.preview")
        .task {
            image = await AttachmentImageLoading.load(attachment, from: images, size: .preview)
        }
    }
}

enum AttachmentImageLoading {
    /// Server files go through the cache; inline `data:` URLs decode locally.
    @MainActor
    static func load(_ attachment: Attachment, from images: AttachmentImageCache, size: AttachmentImageCache.Size) async -> DecodedImage? {
        guard let url = attachment.url else {
            return await images.image(for: attachment.id, size: size) ?? images.cached(attachment.id)
        }
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        let maxPixels = size == .thumbnail ? 480 : 2048
        return await Task.detached {
            Data(base64Encoded: payload).flatMap { ImageProcessing.thumbnail($0, maxPixelSize: maxPixels) }
        }.value
    }
}
