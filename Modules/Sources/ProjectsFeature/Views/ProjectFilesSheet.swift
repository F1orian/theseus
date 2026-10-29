import DesignSystem
import Foundation
import OpenWebUIKit
import SwiftUI
import UniformTypeIdentifiers

/// Project Files (PROJ-05): the Project's Knowledge as tiles with a remove badge, uploads in
/// progress, and an "Add files" button offering Choose file (document picker) or Add text.
struct ProjectFilesSheet: View {
    let library: ProjectLibrary
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var isAddingText = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Spacing.m)]

    var body: some View {
        NavigationStack {
            Group {
                if let project = library.project(id: projectID) {
                    content(project)
                }
            }
            .themedBackground()
            .sheetChrome(
                title: "Project files",
                canConfirm: false,
                confirmIdentifier: "files.confirm",
                onClose: { dismiss() },
                onConfirm: nil
            )
        }
        .presentationDetents([.medium, .large])
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                Task { await upload(url) }
            }
        }
        .sheet(isPresented: $isAddingText) {
            AddTextSheet(library: library, projectID: projectID)
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        let uploads = library.uploads(for: project.id)
        VStack(spacing: 0) {
            if project.knowledge.isEmpty && uploads.isEmpty {
                ProjectsEmptyState(
                    title: "No files yet",
                    message: "Add files the model can use in \(project.name)."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.m) {
                        ForEach(project.knowledge) { file in
                            FileTile(name: file.name, detail: file.size.map(Self.formatSize)) {
                                Task { await library.removeKnowledge(file.id, from: project.id) }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("files.tile.\(file.id)")
                        }
                        ForEach(uploads) { upload in
                            UploadTile(upload: upload) { library.dismissUpload(upload.id) }
                        }
                    }
                    .padding(Spacing.l)
                }
            }
            addButton(project)
        }
    }

    @ViewBuilder
    private func addButton(_ project: Project) -> some View {
        if library.capabilities.contains(.fileUpload) {
            VStack(spacing: Spacing.s) {
                if !library.canAddKnowledge(to: project.id), let limit = library.maxKnowledgeFiles {
                    Text("This server allows up to \(limit) files per project.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                }
                Menu {
                    Button { isImporting = true } label: { Label("Choose file", systemImage: "doc") }
                        .accessibilityIdentifier("files.chooseFile")
                    Button { isAddingText = true } label: { Label("Add text", systemImage: "text.alignleft") }
                        .accessibilityIdentifier("files.addText")
                } label: {
                    Label("Add files", systemImage: "paperclip")
                        .font(Typography.headline)
                        .foregroundStyle(Palette.background.color)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.textPrimary.color, in: .capsule)
                }
                .disabled(!library.canAddKnowledge(to: project.id))
                .accessibilityIdentifier("files.add")
            }
            .padding(Spacing.l)
        }
    }

    private func upload(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await library.addFile(to: projectID, filename: url.lastPathComponent, contentType: type, data: data)
    }

    static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A Knowledge file tile with a round remove badge.
private struct FileTile: View {
    let name: String
    let detail: String?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(Palette.textTertiary.color)
            Spacer(minLength: Spacing.s)
            Text(name)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Typography.caption.weight(.bold))
                    .foregroundStyle(Palette.background.color)
                    .frame(width: 26, height: 26)
                    .background(Palette.textPrimary.color, in: .circle)
                    // PLAT-06: a 44 pt target in the card's corner.
                    .padding(Spacing.s)
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
            .accessibilityIdentifier("files.remove")
        }
    }
}

/// A file still uploading or processing, or one that failed.
private struct UploadTile: View {
    let upload: KnowledgeUpload
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            switch upload.state {
            case .uploading:
                ProgressView()
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(Palette.destructive.color)
            }
            Spacer(minLength: Spacing.s)
            Text(upload.name)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(2)
            switch upload.state {
            case .uploading:
                Text("Adding…").font(Typography.caption).foregroundStyle(Palette.textSecondary.color)
            case .failed(let message):
                Text(message).font(Typography.caption).foregroundStyle(Palette.destructive.color).lineLimit(3)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(alignment: .topTrailing) {
            if case .failed = upload.state {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Typography.caption.weight(.bold))
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(Spacing.s)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.upload")
    }
}

/// "Add text" (PROJ-05): a title and content, stored as a Markdown Knowledge file.
struct AddTextSheet: View {
    let library: ProjectLibrary
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    LabelledField(label: "Document title") {
                        SingleLineField(placeholder: "Name your content", text: $title, identifier: "addText.title")
                    }
                    LabelledField(label: "Content") {
                        MultilineField(placeholder: "Write or paste the text…", text: $content, minHeight: 220, identifier: "addText.content")
                    }
                }
                .padding(Spacing.l)
            }
            .themedBackground()
            .sheetChrome(
                title: "Add text",
                canConfirm: canAdd,
                confirmIdentifier: "addText.confirm",
                onClose: { dismiss() },
                onConfirm: {
                    let (title, content) = (title, content)
                    // The upload continues in the Files sheet, which shows its progress.
                    Task { await library.addText(to: projectID, title: title, content: content) }
                    dismiss()
                }
            )
        }
    }
}
