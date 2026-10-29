import ComposerFeature
import DesignSystem
import Entitlements
import OpenWebUIKit
import SwiftUI

/// Add to Chat › Connectors (CONN-02): a switch per usable Connector for this Chat (sent as
/// `tool_ids`), and a "Connect" pill for MCP servers that still need a sign-in. In the free tier
/// (ADR 0173) the Connectors the model comes with switch freely; turning on any other one opens
/// the paywall, and its row has a `PRO` plaque. Connecting stays free.
struct ChatConnectorsPage: View {
    let directory: ConnectorDirectory
    let composer: ComposerModel

    @State private var showsDirectory = false
    @State private var authorization: ConnectorAuthorization?
    @State private var preparing: String?
    @State private var confirmingDisconnect: ToolEntry?
    @State private var paywall: PaywallRequest?

    var body: some View {
        List {
            if !directory.usable.isEmpty {
                Section {
                    ForEach(directory.usable) { connector in
                        Toggle(isOn: Binding(
                            get: { composer.isToolOn(connector.id) },
                            set: { on in
                                if on, composer.toolNeedsPro(connector.id) {
                                    paywall = PaywallRequest(.connectors)
                                } else {
                                    composer.setTool(connector.id, on: on)
                                }
                            }
                        )) {
                            HStack(spacing: Spacing.s) {
                                ConnectorLabel(connector: connector)
                                if composer.toolNeedsPro(connector.id) {
                                    ProBadge()
                                }
                            }
                        }
                        .tint(Palette.accent.color)
                        .listRowBackground(Palette.recessedSurface.color)
                        .contextMenu {
                            if directory.canDisconnect(connector) {
                                Button("Disconnect", systemImage: "minus.circle", role: .destructive) {
                                    confirmingDisconnect = connector
                                }
                            }
                        }
                        .accessibilityIdentifier("connectors.toggle.\(connector.id)")
                    }
                } footer: {
                    Text(composer.services.pro.allows(.connectors)
                        ? "The model can use the connectors you turn on in this chat."
                        : "The model can use the connectors you turn on in this chat. The ones it comes with are free; turning on others is part of Theseus Pro.")
                }
            }
            if !directory.awaitingConnection.isEmpty {
                Section("Not connected") {
                    ForEach(directory.awaitingConnection) { connector in
                        HStack(spacing: Spacing.m) {
                            ConnectorLabel(connector: connector)
                            Spacer(minLength: Spacing.s)
                            ConnectPill(isWorking: preparing == connector.id) {
                                Task { await connect(connector) }
                            }
                            .accessibilityIdentifier("connectors.connect.\(connector.id)")
                        }
                        .listRowBackground(Palette.recessedSurface.color)
                    }
                }
            }
        }
        .connectorsList()
        .overlay { ConnectorsStateOverlay(directory: directory) }
        .safeAreaInset(edge: .bottom) {
            if let notice = directory.notice {
                ConnectorsNotice(message: notice) { directory.notice = nil }
            }
        }
        .navigationTitle("Connectors")
        .connectorsInlineTitle()
        .toolbar {
            if !directory.directory.isEmpty || directory.access.canManageShared {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add connectors", systemImage: "plus") { showsDirectory = true }
                        .accessibilityIdentifier("connectors.add")
                }
            }
        }
        .sheet(isPresented: $showsDirectory) {
            ConnectorDirectorySheet(directory: directory) { id in switchOn(id) }
        }
        // A Connector connected from here is switched on for the Chat right away (with Pro).
        .connectSheet($authorization, directory: directory) { id in switchOn(id) }
        .paywall($paywall)
        .disconnectAlert($confirmingDisconnect, directory: directory)
        .task { await directory.load() }
        .tint(Palette.textPrimary.color)
        .accessibilityIdentifier("addToChat.connectorsPage")
    }

    /// Switches on a Connector just connected or added. In the free tier it stays off (its row
    /// shows the plaque): a paywall can't open while the connect sheet closes.
    private func switchOn(_ id: String) {
        guard !composer.toolNeedsPro(id) else { return }
        composer.setTool(id, on: true)
    }

    private func connect(_ connector: ToolEntry) async {
        preparing = connector.id
        defer { preparing = nil }
        authorization = await directory.connection(for: connector)
    }
}

/// Loading, empty and error states of Add to Chat › Connectors.
private struct ConnectorsStateOverlay: View {
    let directory: ConnectorDirectory

    var body: some View {
        switch directory.state {
        case .idle, .loading:
            if directory.connectors.isEmpty { ProgressView() }
        case .failed(let message):
            VStack(spacing: Spacing.m) {
                ConnectorsEmptyState(pose: .peek, title: "Couldn't load connectors", message: message)
                Button("Try Again") { Task { await directory.load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("connectors.retry")
            }
        case .loaded:
            if directory.connectors.isEmpty {
                ConnectorsEmptyState(
                    pose: .sleep,
                    title: "No connectors on \(directory.host) yet",
                    message: directory.access.canManageShared
                        ? "Add one in Settings › Connectors. Connectors let the model use tools and services."
                        : "Connectors let the model use tools and services. Your Server admin can add them."
                )
                .accessibilityIdentifier("connectors.empty")
            }
        }
    }
}

extension View {
    /// The Disconnect confirmation (CONN-05): a system alert explaining what's lost.
    func disconnectAlert(_ connector: Binding<ToolEntry?>, directory: ConnectorDirectory) -> some View {
        alert(
            "Disconnect \(connector.wrappedValue?.name ?? "connector")?",
            isPresented: Binding(get: { connector.wrappedValue != nil }, set: { if !$0 { connector.wrappedValue = nil } }),
            presenting: connector.wrappedValue
        ) { target in
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await directory.disconnect(target) }
            }
            .accessibilityIdentifier("connectors.disconnect.confirm")
        } message: { target in
            Text("Chats will lose access to \(target.name)'s tools until you connect it again.")
        }
    }
}

// The preview helpers (Previews.swift) exist in Debug builds only.
#if DEBUG
#Preview("Settings › Connectors") {
    NavigationStack {
        ConnectorsSettingsPage(directory: .preview)
    }
}

#Preview("Empty") {
    NavigationStack {
        ConnectorsSettingsPage(directory: ConnectorDirectory(client: .preview))
    }
}
#endif
