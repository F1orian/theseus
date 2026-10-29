import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The Chat's sandbox files (OT-04), from the Chat menu: folders push, files open in Quick Look,
/// a folder's menu downloads it as a ZIP. Read-only.
public struct SandboxBrowserView: View {
    @State private var model: SandboxBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    public init(model: SandboxBrowserModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch model.state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    SandboxEmptyState(title: "Couldn't open the sandbox", message: message) {
                        Task { await model.load() }
                    }
                case .loaded:
                    if let root = model.root {
                        SandboxFolderList(model: model, folder: root, isRoot: true)
                    }
                }
            }
            .navigationDestination(for: String.self) { folder in
                SandboxFolderList(model: model, folder: folder, isRoot: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("sandbox.browser.close")
                }
            }
        }
        .tint(Palette.textPrimary.color)
        .task { if model.state == .idle { await model.load() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox.browser")
    }
}

/// One folder of the sandbox.
struct SandboxFolderList: View {
    let model: SandboxBrowserModel
    let folder: String
    let isRoot: Bool

    @State private var query = ""
    @State private var loading: String?
    @State private var failure: String?
    @State private var preview: URL?
    @State private var share: URL?
    @State private var export: URL?

    var body: some View {
        List {
            if isRoot, model.showsSharedNotice {
                Section {
                    SharedSandboxNotice { withAnimation { model.dismissSharedNotice() } }
                }
                .listRowBackground(Palette.recessedSurface.color)
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.destructive.color)
                }
            }
            if !query.isEmpty {
                searchSection
            } else if let entries = model.entries(of: folder) {
                if entries.isEmpty {
                    MouseEmptyState(pose: .sleep, scale: 2, title: Text("This folder is empty."))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(entries) { entry in
                        row(entry, path: model.path(of: entry, in: folder))
                    }
                }
                .listRowBackground(Palette.surface.color)
            } else if let error = model.folderErrors[folder] {
                Text(error)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.destructive.color)
            } else {
                ProgressView().frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(model.title(of: folder))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, prompt: "Search files")
        .onChange(of: query) { _, new in model.search(new, in: folder) }
        .refreshable { await model.open(folder) }
        .task { if model.entries(of: folder) == nil { await model.open(folder) } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Download as ZIP", systemImage: "doc.zipper") { downloadArchive(folder) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Folder options")
                .accessibilityIdentifier("sandbox.browser.folderMenu")
            }
        }
        .modifier(FilePresentation(preview: $preview, share: $share, export: $export))
    }

    @ViewBuilder
    private var searchSection: some View {
        if model.isSearching {
            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
        } else if model.searchResults.isEmpty {
            // BRAND-04: the sleeping mouse, no painting.
            MouseEmptyState(pose: .sleep, scale: 2, title: Text("No matching files"), message: Text(ui: "No files match “\(query)”."))
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section("Results") {
                ForEach(model.searchResults) { result in
                    row(SandboxDirectory.Entry(name: result.name, isDirectory: result.isDirectory), path: result.path, detail: result.path)
                }
            }
            .listRowBackground(Palette.surface.color)
        }
    }

    @ViewBuilder
    private func row(_ entry: SandboxDirectory.Entry, path: String, detail: String? = nil) -> some View {
        if entry.isDirectory {
            NavigationLink(value: path) {
                SandboxEntryLabel(entry: entry, detail: detail)
            }
            .contextMenu {
                Button("Download as ZIP", systemImage: "doc.zipper") { downloadArchive(path) }
            }
            .accessibilityIdentifier("sandbox.browser.entry")
        } else {
            Button {
                download(path, then: .open)
            } label: {
                HStack {
                    SandboxEntryLabel(entry: entry, detail: detail)
                    if loading == path { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open", systemImage: "eye") { download(path, then: .open) }
                Button("Share…", systemImage: "square.and.arrow.up") { download(path, then: .share) }
                Button("Save to Files", systemImage: "folder") { download(path, then: .saveToFiles) }
            }
            .accessibilityIdentifier("sandbox.browser.entry")
        }
    }

    private func download(_ path: String, then action: FileAction) {
        guard loading == nil else { return }
        loading = path
        Task {
            defer { loading = nil }
            do {
                let url = try await model.download(path)
                failure = nil
                switch action {
                case .open: preview = url
                case .share: share = url
                case .saveToFiles: export = url
                }
            } catch {
                failure = (error as? SandboxFiles.Failure)?.message ?? "Couldn't download the file."
            }
        }
    }

    private func downloadArchive(_ path: String) {
        guard loading == nil else { return }
        loading = path
        Task {
            defer { loading = nil }
            do {
                share = try await model.downloadArchive(of: path)
                failure = nil
            } catch {
                failure = (error as? SandboxFiles.Failure)?.message ?? "Couldn't download the folder."
            }
        }
    }
}

/// A folder or file row: icon, name, size and date.
struct SandboxEntryLabel: View {
    let entry: SandboxDirectory.Entry
    var detail: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: entry.isDirectory ? "folder" : FileIcon.symbol(forExtension: (entry.name as NSString).pathExtension, mimeType: nil))
                .font(.system(size: 18))
                .foregroundStyle(entry.isDirectory ? Palette.accent.color : Palette.textSecondary.color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(entry.name)
                    .font(Typography.body)
                    .foregroundStyle(entry.name.hasPrefix(".") ? Palette.textTertiary.color : Palette.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String? {
        if let detail { return detail }
        var parts: [String] = []
        if !entry.isDirectory, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Says once that the sandbox isn't private (single-user Open Terminal, open-terminal.md §5).
struct SharedSandboxNotice: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "person.2")
                .foregroundStyle(Palette.textSecondary.color)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("This sandbox may be shared")
                    .font(Typography.callout.weight(.semibold))
                Text("Other people who use this Server's sandbox may be able to see these files. Don't keep anything private here.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textTertiary.color)
                .accessibilityIdentifier("sandbox.browser.noticeDismiss")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox.browser.notice")
    }
}

/// Centred mouse, title, hint and Try again (BRAND-04: the mouse peeks; no painting here).
struct SandboxEmptyState: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        MouseEmptyState(pose: .peek, title: Text(title), message: Text(message)) {
            Button("Try again", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
