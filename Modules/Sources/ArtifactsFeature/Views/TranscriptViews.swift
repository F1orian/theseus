import ChatDomain
import ChatFeature
import DesignSystem
import Rendering
import SwiftUI

struct ArtifactSelection: Identifiable, Hashable {
    let id: String
}

/// A Response's code block: its Artifact card when it is one (ART-01), else the code block.
struct ArtifactCodeBlock: View {
    let model: ConversationModel
    let messageID: String
    let language: String?
    let code: String
    @State private var presented: ArtifactSelection?

    var body: some View {
        let catalog = ArtifactsCache.shared.catalog(for: model)
        if let artifact = catalog.artifact(messageID: messageID, language: language, code: code) {
            ArtifactCard(artifact: artifact) { presented = ArtifactSelection(id: artifact.id) }
                .sheet(item: $presented) { selection in
                    ArtifactViewerSheet(catalog: ArtifactsCache.shared.catalog(for: model), artifactID: selection.id, writesFiles: !model.isIncognito)
                }
        } else {
            MarkdownView(blocks: [.code(language: language, code: code)])
                .environment(\.codeBlockReplacement, nil)
        }
    }
}

/// A run of tool steps holding Claude `artifacts` calls (imported Chats, #180): a card for each
/// call, in place, and the usual status line for the other steps around them.
struct ImportedArtifactSteps: View {
    let model: ConversationModel
    let messageID: String
    let steps: [ToolActivity]
    @State private var presented: ArtifactSelection?

    private enum Row: Identifiable {
        case steps([ToolActivity])
        case artifact(Artifact)

        var id: String {
            switch self {
            case .steps(let steps): "steps-\(steps.first?.id ?? "")"
            case .artifact(let artifact): artifact.id
            }
        }
    }

    var body: some View {
        let catalog = ArtifactsCache.shared.catalog(for: model)
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(rows(catalog)) { row in
                switch row {
                case .steps(let steps):
                    ToolActivityLine(tools: steps)
                case .artifact(let artifact):
                    ArtifactCard(artifact: artifact) { presented = ArtifactSelection(id: artifact.id) }
                }
            }
        }
        .sheet(item: $presented) { selection in
            ArtifactViewerSheet(catalog: ArtifactsCache.shared.catalog(for: model), artifactID: selection.id, writesFiles: !model.isIncognito)
        }
    }

    private func rows(_ catalog: ArtifactCatalog) -> [Row] {
        var rows: [Row] = []
        var pending: [ToolActivity] = []
        for step in steps {
            if step.name == ToolActivity.artifactsName, let artifact = catalog.artifact(messageID: messageID, callID: step.id) {
                if !pending.isEmpty { rows.append(.steps(pending)) }
                pending = []
                rows.append(.artifact(artifact))
            } else {
                pending.append(step)
            }
        }
        if !pending.isEmpty { rows.append(.steps(pending)) }
        return rows
    }
}

/// After a Response: cards for the HTML views tools attached, and links for URL embeds.
struct ToolEmbedCards: View {
    let model: ConversationModel
    let messageID: String
    @State private var presented: ArtifactSelection?

    var body: some View {
        let catalog = ArtifactsCache.shared.catalog(for: model)
        let embeds = catalog.artifacts.filter { $0.messageID == messageID && $0.origin == .toolEmbed }
        let links = linkEmbeds
        if !embeds.isEmpty || !links.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(embeds) { artifact in
                    ArtifactCard(artifact: artifact) { presented = ArtifactSelection(id: artifact.id) }
                }
                ForEach(links, id: \.self) { url in
                    Link(destination: url) {
                        Label(ServerDisplay.linkHost(url.host()) ?? url.absoluteString, systemImage: "arrow.up.forward.square")
                            .font(Typography.callout)
                    }
                    .accessibilityIdentifier("artifact.embedLink")
                }
            }
            .sheet(item: $presented) { selection in
                ArtifactViewerSheet(catalog: ArtifactsCache.shared.catalog(for: model), artifactID: selection.id, writesFiles: !model.isIncognito)
            }
            .appearsWithFade()
        }
    }

    private var linkEmbeds: [URL] {
        guard let message = model.thread.first(where: { $0.id == messageID }) else { return [] }
        return model.response(for: message).embeds.compactMap { embed in
            let trimmed = embed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ArtifactDetector.isURL(trimmed), let url = URL(string: trimmed) else { return nil }
            return url
        }
    }
}

/// "N artifacts" under the Chat header (ART-01); opens the Chat's Artifacts.
struct ArtifactsPill: View {
    let model: ConversationModel
    @State private var isListShown = false

    var body: some View {
        let catalog = ArtifactsCache.shared.catalog(for: model)
        if !catalog.isEmpty {
            Button { isListShown = true } label: {
                Text(catalog.count == 1 ? "1 artifact" : "\(catalog.count) artifacts")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary.color)
                    .contentTransition(.numericText())
                    .padding(.horizontal, Spacing.l)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: .infinity)
            .motionSafeAnimation(Motion.snappy, value: catalog.count)
            .accessibilityIdentifier("artifacts.pill")
            .sheet(isPresented: $isListShown) {
                ChatArtifactsSheet(model: model)
            }
        }
    }
}

/// The Chat's Artifacts (newest first, one row per Artifact with its version count). Rows open
/// the viewer at the newest version.
struct ChatArtifactsSheet: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let catalog = ArtifactsCache.shared.catalog(for: model)
        NavigationStack {
            ArtifactList(catalog: catalog)
                .navigationTitle("Artifacts")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .tint(Palette.textPrimary.color)
                    }
                }
                .navigationDestination(for: ArtifactSelection.self) { selection in
                    ArtifactViewer(catalog: ArtifactsCache.shared.catalog(for: model), artifactID: selection.id, writesFiles: !model.isIncognito)
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("artifacts.chatList")
    }
}

/// Rows for the newest version of each Artifact in a catalog.
struct ArtifactList: View {
    let catalog: ArtifactCatalog

    var body: some View {
        List(catalog.latestVersions) { artifact in
            NavigationLink(value: ArtifactSelection(id: artifact.id)) {
                HStack(spacing: Spacing.m) {
                    ArtifactIcon(symbol: artifact.symbol)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(artifact.title)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary.color)
                            .lineLimit(1)
                        Text(detail(artifact))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
            }
            .listRowBackground(Palette.surface.color)
            .accessibilityIdentifier("artifacts.row")
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
    }

    private func detail(_ artifact: Artifact) -> String {
        let count = catalog.versions(of: artifact).count
        return count > 1 ? "\(artifact.typeLabel) · \(count) versions" : artifact.typeLabel
    }
}

#Preview("Chat artifacts list") {
    NavigationStack {
        ArtifactList(catalog: ArtifactPreviewData.catalog)
            .navigationTitle("Artifacts")
    }
}
