import DesignSystem
public import Foundation
import Rendering
public import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The bundled Mermaid runtime (ADR 0060), read once.
enum MermaidRuntime {
    static let source: String? = Bundle.module
        .url(forResource: "mermaid.min", withExtension: "js", subdirectory: "mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

/// The full Artifact viewer (ART-02): the rendered preview or the code, the version picker
/// (ART-03), copy, share and reload, over a safety caption. Push it inside a `NavigationStack`;
/// `ArtifactViewerSheet` wraps it for presentation.
public struct ArtifactViewer: View {
    enum Mode: Hashable { case preview, code }

    let catalog: ArtifactCatalog
    /// Whether sharing may write the Artifact to a temporary file (never for Incognito chats).
    let writesFiles: Bool
    @State private var selectedID: String
    @State private var mode: Mode = .preview
    @State private var allowsNetwork = false
    @State private var reloadToken = 0
    @State private var exportURL: URL?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - catalog: The Artifacts to pick versions from (a Chat's active path).
    ///   - artifactID: The Artifact (version) to show first.
    ///   - writesFiles: `false` shares the source as text instead of a file (Incognito chats).
    public init(catalog: ArtifactCatalog, artifactID: String, writesFiles: Bool = true) {
        self.catalog = catalog
        self.writesFiles = writesFiles
        _selectedID = State(initialValue: artifactID)
    }

    private var artifact: Artifact? {
        catalog.artifact(id: selectedID) ?? catalog.artifacts.last
    }

    public var body: some View {
        Group {
            if let artifact {
                content(artifact)
                    .toolbar { toolbar(artifact) }
                    .task(id: artifact) { exportURL = writesFiles ? try? ArtifactExport.write(artifact) : nil }
            } else {
                ContentUnavailableView("This artifact is gone", systemImage: "square.dashed", description: Text("The Response that held it changed."))
            }
        }
        .themedBackground()
        .navigationTitle(artifact?.title ?? "Artifact")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Code inside the viewer is shown as code, never as another card.
        .environment(\.codeBlockReplacement, nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifact.viewer")
    }

    // MARK: Content

    private func content(_ artifact: Artifact) -> some View {
        VStack(spacing: 0) {
            if artifact.hasPreview, artifact.isComplete {
                Picker("Show", selection: $mode) {
                    Text("Preview").tag(Mode.preview)
                    Text("Code").tag(Mode.code)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .accessibilityIdentifier("artifact.mode")
            }
            Group {
                if mode == .preview, artifact.hasPreview, artifact.isComplete {
                    preview(artifact)
                } else {
                    source(artifact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            caption(artifact)
        }
    }

    @ViewBuilder
    private func preview(_ artifact: Artifact) -> some View {
        let dark = colorScheme == .dark
        switch artifact.kind {
        case .webPage, .image:
            SandboxedWebView(
                html: ArtifactDocument.page(for: artifact, allowsNetwork: allowsNetwork, dark: dark),
                policy: SandboxPolicy(
                    allowsScripts: artifact.kind == .webPage,
                    allowsNetwork: allowsNetwork,
                    canvas: ArtifactDocument.canvas(for: artifact.kind, dark: dark)
                )
            )
            .id("\(artifact.id)|\(allowsNetwork)|\(reloadToken)")
        case .diagram:
            if let runtime = MermaidRuntime.source {
                SandboxedWebView(
                    html: ArtifactDocument.page(for: artifact, dark: dark),
                    policy: SandboxPolicy(
                        allowsScripts: true,
                        userScripts: [runtime, ArtifactDocument.mermaidBootstrap(dark: dark)],
                        canvas: ArtifactDocument.canvas(for: .diagram, dark: dark)
                    )
                )
                .id("\(artifact.id)|\(dark)|\(reloadToken)")
            } else {
                source(artifact)
            }
        case .document:
            ScrollView {
                MarkdownView(blocks: MarkdownParser.parse(artifact.content))
                    .padding(Spacing.xl - 4)
            }
        case .component, .code:
            source(artifact)
        }
    }

    private func source(_ artifact: Artifact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if !artifact.isComplete {
                    Label("Writing…", systemImage: "ellipsis")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                } else if artifact.kind == .component {
                    Text("Theseus can't run components yet. Copy the code to try it in a React project.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .accessibilityIdentifier("artifact.componentNote")
                }
                MarkdownView(blocks: [.code(language: artifact.language, code: artifact.content)])
            }
            .padding(Spacing.l)
        }
        .accessibilityIdentifier("artifact.code")
    }

    private func caption(_ artifact: Artifact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: copied ? "checkmark.circle" : allowsNetwork ? "network" : artifact.isStale ? "exclamationmark.triangle" : "info.circle")
                .contentTransition(.symbolEffect(.replace))
            Text(copied
                 ? "Copied to the clipboard."
                 : allowsNetwork
                 ? "Network access is on for this page until you close it."
                 : artifact.isStale
                 ? "An edit in this version couldn't be rebuilt from the imported chat, so it shows the version before it."
                 : "Artifacts are written by AI and may contain errors or unsafe content.")
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textTertiary.color)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("artifact.caption")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ artifact: Artifact) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("artifact.close")
        }
        ToolbarItem(placement: .principal) {
            versionMenu(artifact)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { copy(artifact) }
                    .accessibilityIdentifier("artifact.copy")
                if let exportURL {
                    ShareLink(item: exportURL, preview: SharePreview(artifact.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("artifact.share")
                } else if !writesFiles {
                    ShareLink(item: artifact.content, preview: SharePreview(artifact.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("artifact.share")
                }
                if artifact.hasPreview, artifact.kind != .document {
                    Button("Reload", systemImage: "arrow.clockwise") { reloadToken += 1 }
                        .accessibilityIdentifier("artifact.reload")
                }
                if artifact.referencesNetwork {
                    Section {
                        Toggle(isOn: $allowsNetwork) {
                            Label("Allow network access", systemImage: "network")
                        }
                        .accessibilityIdentifier("artifact.network")
                    } footer: {
                        Text("This page loads files from the internet.")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("artifact.more")
        }
    }

    @ViewBuilder
    private func versionMenu(_ artifact: Artifact) -> some View {
        let versions = catalog.versions(of: artifact)
        if versions.count > 1 {
            Menu {
                Picker("Version", selection: $selectedID) {
                    ForEach(versions.reversed()) { version in
                        Text("Version \(version.version)").tag(version.id)
                    }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(artifact.title)
                        .font(Typography.headline)
                        .lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        Text("Version \(artifact.version) of \(versions.count)")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                }
                .foregroundStyle(Palette.textPrimary.color)
            }
            .accessibilityLabel("\(artifact.title), version \(artifact.version) of \(versions.count)")
            .accessibilityIdentifier("artifact.versions")
        } else {
            Text(artifact.title)
                .font(Typography.headline)
                .lineLimit(1)
                .accessibilityIdentifier("artifact.title")
        }
    }

    private func copy(_ artifact: Artifact) {
        #if canImport(UIKit)
        UIPasteboard.general.string = artifact.content
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.content, forType: .string)
        #endif
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copied = false }
        }
    }
}

/// The viewer as a sheet's content: its own navigation stack, expanded to the large detent.
public struct ArtifactViewerSheet: View {
    let catalog: ArtifactCatalog
    let artifactID: String
    let writesFiles: Bool

    public init(catalog: ArtifactCatalog, artifactID: String, writesFiles: Bool = true) {
        self.catalog = catalog
        self.artifactID = artifactID
        self.writesFiles = writesFiles
    }

    public var body: some View {
        NavigationStack {
            ArtifactViewer(catalog: catalog, artifactID: artifactID, writesFiles: writesFiles)
        }
        .presentationDetents([.large])
        // An artifact is interactive (sliders, games, drags): a drag inside it must never close
        // the viewer. Only the X closes it.
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
    }
}

/// Writes an Artifact to a temporary file for sharing and export.
enum ArtifactExport {
    static func write(_ artifact: Artifact) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Artifacts", directoryHint: .isDirectory)
            .appending(path: artifact.id.replacingOccurrences(of: "/", with: "-"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(fileName(artifact.title)).\(artifact.fileExtension)")
        try Data(artifact.content.utf8).write(to: url, options: .atomic)
        return url
    }

    /// A safe file name from a title.
    static func fileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.filter(allowed.contains)).split(separator: " ").joined(separator: " ")
        return cleaned.isEmpty ? "Artifact" : String(cleaned.prefix(60))
    }
}

#Preview("Viewer: web page") {
    let catalog = ArtifactPreviewData.catalog
    ArtifactViewerSheet(catalog: catalog, artifactID: catalog.artifacts[1].id)
}

#Preview("Viewer: diagram") {
    let catalog = ArtifactPreviewData.catalog
    ArtifactViewerSheet(catalog: catalog, artifactID: catalog.artifacts[3].id)
}
