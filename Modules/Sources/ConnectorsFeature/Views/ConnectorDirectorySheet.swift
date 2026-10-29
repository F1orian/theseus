import DesignSystem
import OpenWebUIKit
import SwiftUI

/// The directory (CONN-03, CONN-04): the MCP servers this Server offers that sign in with OAuth,
/// as cards with a black "Connect" pill or a green "Connected" mark, sorted A–Z with search. There
/// is no public catalogue, popularity or categories, so there's no filter menu.
struct ConnectorDirectorySheet: View {
    let directory: ConnectorDirectory
    /// Called with a Connector's id once it's connected (e.g. to switch it on for the Chat).
    var onConnected: @MainActor (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var authorization: ConnectorAuthorization?
    @State private var preparing: String?
    @State private var flow = ConnectionFlowState()

    private var results: [ToolEntry] {
        ConnectorCatalog.filter(directory.directory, matching: query)
    }

    var body: some View {
        NavigationStack {
            List {
                // One card per Connector.
                ForEach(results) { connector in
                    Section {
                        DirectoryCard(
                            connector: connector,
                            isPreparing: preparing == connector.id,
                            connect: { Task { await connect(connector) } }
                        )
                        .listRowBackground(Palette.surface.color)
                    }
                    #if os(iOS)
                    .listSectionSpacing(Spacing.m)
                    #endif
                }
            }
            .connectorsList()
            .overlay {
                if directory.directory.isEmpty {
                    if directory.access.canManageShared {
                        MouseEmptyState(
                            pose: .sit,
                            title: Text("Nothing to connect yet"),
                            message: Text("Add an MCP or OpenAPI server for \(directory.host). Servers that sign in with OAuth 2.1 show up here to connect.")
                        ) {
                            Button("Add connector", systemImage: "plus") { flow.form = ConnectorForm(kind: .shared) }
                                .buttonStyle(.accentPill)
                                .accessibilityIdentifier("connectors.directory.addConnector.empty")
                        }
                    } else {
                        ConnectorsEmptyState(
                            pose: .sit,
                            title: "Nothing to connect",
                            message: "Connectors that need you to sign in will appear here once your Server admin adds them."
                        )
                    }
                } else if results.isEmpty {
                    ConnectorsEmptyState(
                        pose: .sleep,
                        title: "No matching connectors",
                        message: "Nothing matches \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}."
                    )
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Connectors")
            .connectorsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("connectors.directory.close")
                }
                // #186: admins add a connection for the whole Server from here too.
                if directory.access.canManageShared {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add connector", systemImage: "plus") { flow.form = ConnectorForm(kind: .shared) }
                            .accessibilityIdentifier("connectors.directory.addConnector")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = directory.notice {
                    ConnectorsNotice(message: notice) { directory.notice = nil }
                }
            }
            .refreshable { await directory.load() }
            .connectSheet($authorization, directory: directory, onConnected: onConnected)
            .connectionFlow($flow, directory: directory)
        }
        .tint(Palette.textPrimary.color)
        .presentationBackground(Palette.background.color)
        .accessibilityIdentifier("connectors.directory")
    }

    private func connect(_ connector: ToolEntry) async {
        preparing = connector.id
        defer { preparing = nil }
        authorization = await directory.connection(for: connector)
    }
}

private struct DirectoryCard: View {
    let connector: ToolEntry
    let isPreparing: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.m) {
                ConnectorIcon(connector: connector, size: 40)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(connector.name)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(1)
                    Text(connector.kindLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary.color)
                }
                Spacer(minLength: Spacing.s)
                if connector.isUsable {
                    ConnectedMark()
                } else {
                    ConnectPill(isWorking: isPreparing, action: connect)
                        .accessibilityIdentifier("connectors.directory.connect.\(connector.id)")
                }
            }
            if let description = connector.description {
                Text(description)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectors.directory.row.\(connector.id)")
    }
}

// The preview helpers (Previews.swift) exist in Debug builds only.
#if DEBUG
#Preview("Directory") {
    ConnectorDirectorySheet(directory: .preview)
}
#endif
