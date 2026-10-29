import ComposerFeature
import DesignSystem
import Foundation
import QuickLook
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What a file card can do with a downloaded file.
enum FileAction: Sendable {
    /// Quick Look.
    case open
    case share
    case saveToFiles
}

/// Presents a downloaded file: Quick Look, the share sheet, or Save to Files (OT-03).
struct FilePresentation: ViewModifier {
    @Binding var preview: URL?
    @Binding var share: URL?
    @Binding var export: URL?

    func body(content: Content) -> some View {
        content
            // #143: spreadsheets get a phone-width preview; Quick Look shrinks them to a speck.
            .quickLookPreview(Binding(
                get: { preview.flatMap { SpreadsheetPreview.handles($0) ? nil : $0 } },
                set: { preview = $0 }
            ))
            #if canImport(UIKit)
            .sheet(item: Binding(
                get: { preview.flatMap { SpreadsheetPreview.handles($0) ? IdentifiedURL(url: $0) : nil } },
                set: { preview = $0?.url }
            )) { item in
                SpreadsheetPreviewSheet(url: item.url)
            }
            .sheet(item: Binding(get: { share.map(IdentifiedURL.init) }, set: { share = $0?.url })) { item in
                ActivitySheet(items: [item.url])
                    .presentationDetents([.medium, .large])
            }
            #endif
            .fileMover(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }), file: export) { _ in
                export = nil
            }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

#if canImport(UIKit)
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// A file the model created in the sandbox, as a card on the Response (OT-03): icon by type,
/// name and type. Tap opens it in Quick Look; the menu shares it or saves it to Files. Images
/// also show inline.
struct SandboxFileCard: View {
    let file: SandboxFile
    let chatID: String?
    let files: SandboxFiles

    @State private var loading = false
    @State private var failure: SandboxFiles.Failure?
    @State private var preview: URL?
    @State private var share: URL?
    @State private var export: URL?
    @State private var image: DecodedImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let image {
                Button { perform(.open) } label: {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 220, alignment: .leading)
                        .clipShape(.rect(cornerRadius: Radius.medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(file.name)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("sandbox.file.image")
                // The thumbnail fades in once it's decoded rather than pushing in.
                .motionSafeTransition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
            FileCardRow(
                name: file.name,
                badge: file.typeBadge,
                systemImage: FileIcon.symbol(forExtension: file.fileExtension, mimeType: file.mimeType),
                subtitle: subtitle,
                isLoading: loading || file.isRunning,
                isUnavailable: failure != nil
            ) {
                perform(.open)
            }
            .contextMenu {
                Button("Open", systemImage: "eye") { perform(.open) }
                Button("Share…", systemImage: "square.and.arrow.up") { perform(.share) }
                Button("Save to Files", systemImage: "folder") { perform(.saveToFiles) }
            }
            .accessibilityIdentifier("sandbox.file")
        }
        .modifier(FilePresentation(preview: $preview, share: $share, export: $export))
        // OT-03: "Preparing…" → ready, loading and the thumbnail arriving animate (ADR 0130).
        .motionSafeAnimation(Motion.smooth, value: image != nil)
        .motionSafeAnimation(Motion.snappy, value: [loading, file.isRunning, failure != nil])
        .appearsWithFade()
        .task(id: file.path) {
            guard file.isImage, image == nil, !file.isRunning else { return }
            if let data = try? await files.data(for: file, chatID: chatID) {
                image = await Task.detached(priority: .userInitiated) { ImageProcessing.thumbnail(data, maxPixelSize: 900) }.value
            }
        }
    }

    private var subtitle: String {
        if file.isRunning { return "Preparing…" }
        if let failure { return failure.message }
        return file.typeBadge == "FILE" ? "File" : "\(file.typeBadge) file"
    }

    private func perform(_ action: FileAction) {
        guard !loading, !file.isRunning else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let url = try await files.download(file, chatID: chatID)
                failure = nil
                switch action {
                case .open: preview = url
                case .share: share = url
                case .saveToFiles: export = url
                }
            } catch {
                failure = (error as? SandboxFiles.Failure) ?? .other("Couldn’t open the file.")
            }
        }
    }
}

/// The card's row: a type tile, the name and a subtitle. Shared by sandbox files and files the
/// Server attached to the Response.
struct FileCardRow: View {
    let name: String
    let badge: String
    let systemImage: String
    let subtitle: String
    var isLoading = false
    var isUnavailable = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(Palette.recessedSurface.color)
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(isUnavailable ? Palette.textTertiary.color : Palette.textSecondary.color)
                        .frame(maxHeight: .infinity)
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.textTertiary.color)
                        .padding(.bottom, 3)
                }
                .frame(width: 40, height: 48)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(name)
                        .font(Typography.callout.weight(.medium))
                        .foregroundStyle(isUnavailable ? Palette.textTertiary.color : Palette.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(isUnavailable ? Palette.destructive.color : Palette.textTertiary.color)
                        .lineLimit(2)
                        .contentTransition(.interpolate)
                }
                Spacer(minLength: Spacing.s)
                if isLoading {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                } else if !isUnavailable {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(Palette.textTertiary.color)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
            .contentShape(.rect(cornerRadius: Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(subtitle)")
        .accessibilityHint(isUnavailable ? "" : "Opens a preview")
    }
}

/// SF Symbols for file types.
enum FileIcon {
    static func symbol(forExtension ext: String, mimeType: String?) -> String {
        switch ext.lowercased() {
        case "csv", "tsv", "xlsx", "xls", "xlsm", "numbers": return "tablecells"
        case "pptx", "ppt", "key": return "rectangle.on.rectangle.angled"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        case "zip", "tar", "gz", "tgz": return "doc.zipper"
        case "py", "js", "ts", "swift", "sh", "json", "html", "css", "c", "cpp", "rs", "go", "rb", "java", "yaml", "yml", "toml":
            return "chevron.left.forwardslash.chevron.right"
        case "mp3", "wav", "m4a", "aac": return "waveform"
        case "mp4", "mov", "m4v": return "film"
        default:
            if mimeType?.hasPrefix("image/") == true { return "photo" }
            return "doc.text"
        }
    }
}
