import DesignSystem
import LibraryFeature
public import SwiftUI

/// Drawer › Artifacts (ART-04): a two-column grid of the Account's Artifacts, newest first, or an
/// empty state. Tapping one opens the viewer with that Chat's versions; long-press opens its Chat.
public struct ArtifactsLibraryView: View {
    @Bindable var library: ArtifactLibrary
    @Environment(\.libraryNavigate) private var navigate
    @State private var presented: ArtifactLibrary.Item?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(library: ArtifactLibrary) {
        self.library = library
    }

    public var body: some View {
        NavigationStack {
            content
                .themedBackground()
                .navigationTitle("Artifacts")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .navigation) { DrawerButton() }
                }
                .task { await library.open() }
                .sheet(item: $presented) { item in
                    ArtifactViewerSheet(catalog: library.catalog(chatID: item.chatID), artifactID: item.artifact.id)
                }
                // Indexing → the grid, new Artifacts landing.
                .motionSafeAnimation(Motion.smooth, value: library.items.map(\.id))
        }
        // A container element, so the identifier doesn't replace its children's (PLAT-05).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifacts.library")
    }

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            switch library.state {
            case .idle, .indexing:
                VStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Collecting artifacts from your chats…")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("artifacts.library.indexing")
            case .failed(let message):
                emptyState(symbol: "exclamationmark.triangle", title: "Couldn't collect artifacts", message: message)
            case .ready:
                emptyState(symbol: "square.on.circle", title: "No artifacts yet", message: "Artifacts from your chats will appear here.")
            }
        } else {
            ScrollView {
                if case .failed(let message) = library.state {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(.horizontal, Spacing.l)
                }
                LazyVGrid(columns: Self.columns, spacing: Spacing.l) {
                    ForEach(library.items) { item in
                        Button { presented = item } label: { LibraryCell(item: item) }
                            .buttonStyle(.plain)
                            // Cells settle in as they scroll into view.
                            .scrollTransition(.animated(Motion.smooth)) { [reduceMotion] cell, phase in
                                cell
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.94)
                            }
                            .motionSafeTransition(.opacity.combined(with: .scale(scale: 0.95)))
                            .contextMenu {
                                Button("Open chat", systemImage: "bubble.left.and.bubble.right") {
                                    navigate(.chat(id: item.chatID))
                                }
                            }
                            .accessibilityIdentifier("artifacts.library.item")
                    }
                }
                .padding(Spacing.l)
            }
            .refreshable { await library.rebuild() }
        }
    }

    /// Two columns on iPhone; more on wider screens (iPad, #180) rather than two huge tiles.
    static let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: Spacing.m, alignment: .top)]

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        ScrollView {
            VStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(width: 48, height: 48)
                    .background(Palette.recessedSurface.color, in: .circle)
                    .padding(.bottom, Spacing.xs)
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textSecondary.color)
                Text(message)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary.color)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xl)
            .padding(.top, Spacing.xxxl)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("artifacts.library.empty")
        }
        .refreshable { await library.rebuild() }
    }
}

/// A grid cell: the kind's tile as the preview, then the title, the time and the version count.
struct LibraryCell: View {
    let item: ArtifactLibrary.Item

    private var subtitle: String {
        let time = item.date.formatted(.relative(presentation: .named))
        return item.versionCount > 1 ? "\(time) · \(item.versionCount) versions" : time
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Palette.surface.color)
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
                .overlay {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: item.artifact.symbol)
                            .font(.system(size: 28))
                            .foregroundStyle(Palette.textSecondary.color)
                        Text(item.artifact.typeLabel)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary.color)
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.s)
                    }
                }
                .aspectRatio(1.1, contentMode: .fit)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.artifact.title)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.artifact.title), \(item.artifact.typeLabel), from \(item.chatTitle)")
    }
}

#Preview("Library grid") {
    let catalog = ArtifactPreviewData.catalog
    ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.l) {
            ForEach(catalog.latestVersions) { artifact in
                LibraryCell(item: .init(chatID: "c", chatTitle: "Tip calculator", artifact: artifact,
                                        versionCount: catalog.versions(of: artifact).count, date: .now.addingTimeInterval(-3600)))
            }
        }
        .padding()
    }
    .themedBackground()
}
