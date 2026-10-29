import ChatDomain
import ChatFeature
import ComposerFeature
import DesignSystem
import SwiftUI

/// One run of consecutive tool steps, with the sandbox's own steps as run cards, file lines and
/// file cards; other tools (web search, Connectors) keep the shared status line (CHAT-08, OT-02).
struct SandboxToolSteps: View {
    let steps: [ToolActivity]
    let log: SandboxLog
    let chatID: String?
    let files: SandboxFiles

    /// The group, split into runs of other tools and single sandbox steps, in order.
    enum Segment: Identifiable {
        case tools([ToolActivity])
        case sandbox(String, SandboxStep)

        var id: String {
            switch self {
            case .tools(let tools): "tools-\(tools.first?.id ?? "")"
            case .sandbox(let id, _): id
            }
        }
    }

    static func segments(_ steps: [ToolActivity], log: SandboxLog) -> [Segment] {
        var segments: [Segment] = []
        var others: [ToolActivity] = []
        for step in steps {
            if let sandbox = log[step.id] {
                if !others.isEmpty {
                    segments.append(.tools(others))
                    others = []
                }
                // Status, input and kill calls show inside their run card.
                if case .folded = sandbox { continue }
                segments.append(.sandbox(step.id, sandbox))
            } else {
                others.append(step)
            }
        }
        if !others.isEmpty { segments.append(.tools(others)) }
        return segments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Self.segments(steps, log: log)) { segment in
                switch segment {
                case .tools(let tools):
                    ToolActivityLine(tools: tools)
                case .sandbox(_, .run(let run)):
                    RunCard(run: run)
                case .sandbox(_, .file(let step)):
                    FileStepLine(step: step)
                case .sandbox(_, .display(let file)):
                    SandboxFileCard(file: file, chatID: chatID, files: files)
                case .sandbox(_, .folded):
                    EmptyView()
                }
            }
        }
    }
}

/// Files the Server attached to a Response (`files` / `chat:message:files` events, assistant
/// `message.files`): images inline, documents as cards (OT-03).
struct ResponseFilesView: View {
    let attachments: [Attachment]
    let files: SandboxFiles
    let images: AttachmentImageCache

    @State private var preview: URL?
    @State private var share: URL?
    @State private var export: URL?
    @State private var loading: String?
    @State private var failures: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image {
                    ResponseImage(attachment: attachment, images: images) { perform(.open, attachment) }
                } else {
                    FileCardRow(
                        name: attachment.name,
                        badge: attachment.typeBadge,
                        systemImage: FileIcon.symbol(forExtension: (attachment.name as NSString).pathExtension, mimeType: attachment.contentType),
                        subtitle: failures[attachment.id] ?? subtitle(attachment),
                        isLoading: loading == attachment.id,
                        isUnavailable: failures[attachment.id] != nil
                    ) {
                        perform(.open, attachment)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "eye") { perform(.open, attachment) }
                        Button("Share…", systemImage: "square.and.arrow.up") { perform(.share, attachment) }
                        Button("Save to Files", systemImage: "folder") { perform(.saveToFiles, attachment) }
                    }
                    .accessibilityIdentifier("response.file")
                }
            }
        }
        .modifier(FilePresentation(preview: $preview, share: $share, export: $export))
    }

    private func subtitle(_ attachment: Attachment) -> String {
        let size = attachment.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [attachment.typeBadge, size].compactMap { $0 }.joined(separator: " · ")
    }

    private func perform(_ action: FileAction, _ attachment: Attachment) {
        guard loading == nil else { return }
        loading = attachment.id
        Task {
            defer { loading = nil }
            do {
                let url = try await files.download(attachment)
                failures[attachment.id] = nil
                switch action {
                case .open: preview = url
                case .share: share = url
                case .saveToFiles: export = url
                }
            } catch {
                failures[attachment.id] = (error as? SandboxFiles.Failure)?.message ?? "Couldn’t open the file."
            }
        }
    }
}

/// A generated image on the Response.
private struct ResponseImage: View {
    let attachment: Attachment
    let images: AttachmentImageCache
    let open: () -> Void
    @State private var image: DecodedImage?

    var body: some View {
        Button(action: open) {
            Group {
                if let image {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: Radius.medium)
                        .fill(Palette.recessedSurface.color)
                        .overlay { ProgressView() }
                        .aspectRatio(4 / 3, contentMode: .fit)
                }
            }
            .frame(maxWidth: 300, maxHeight: 300, alignment: .leading)
            .clipShape(.rect(cornerRadius: Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("response.image")
        .task(id: attachment.id) {
            if let url = attachment.url, url.hasPrefix("data:"), let data = SandboxFiles.decodeDataURL(url) {
                image = await Task.detached(priority: .userInitiated) { ImageProcessing.thumbnail(data, maxPixelSize: 900) }.value
            } else if let fileID = SandboxFiles.serverFileID(attachment) {
                image = await images.image(for: fileID, size: .preview)
            }
        }
    }
}
