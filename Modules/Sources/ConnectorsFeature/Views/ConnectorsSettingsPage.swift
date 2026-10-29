import DesignSystem
import Entitlements
import OpenWebUIKit
import SettingsFeature
import SwiftUI

/// Settings › Connectors (CONN-02, CONN-05, #186), in two clearly separate sections:
///
/// - **Yours** ("Only you"): personal connectors, OpenAPI servers this device calls, the same list
///   (keys included) as the web app's Settings › Integrations (#189). Add, edit, turn off and
///   remove them here. Where the Server doesn't allow them, an explanation instead.
/// - **From <host>**: the Server's shared connectors, switched on per chat under + › Connectors.
///   "+" opens the directory of MCP servers to connect; long-press a connected one to disconnect.
///   Admins also get Add connector, and Edit / Turn off / Remove on each connection.
struct ConnectorsSettingsPage: View {
    let directory: ConnectorDirectory

    @State private var showsDirectory = false
    @State private var confirmingDisconnect: ToolEntry?
    @State private var flow = ConnectionFlowState()
    @State private var paywall: PaywallRequest?
    /// ADR 0173: setting connectors up is free; using them in chats is Pro. `nil` counts as Pro.
    @Environment(\.proStore) private var pro

    private var access: ConnectorAccess { directory.access }
    private var personal: PersonalConnectors { directory.personal }

    var body: some View {
        List {
            yoursSection
            sharedSection
        }
        .connectorsList()
        .paywall($paywall)
        .safeAreaInset(edge: .bottom) {
            if let notice = directory.notice ?? personal.notice ?? directory.shared.notice {
                ConnectorsNotice(message: notice) {
                    directory.notice = nil
                    personal.notice = nil
                    directory.shared.notice = nil
                }
            }
        }
        .navigationTitle("Connectors")
        .connectorsInlineTitle()
        .toolbar {
            if !directory.directory.isEmpty || access.canManageShared {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add connectors", systemImage: "plus") { showsDirectory = true }
                        .accessibilityIdentifier("connectors.add")
                }
            }
        }
        .sheet(isPresented: $showsDirectory) {
            ConnectorDirectorySheet(directory: directory)
        }
        .connectionFlow($flow, directory: directory)
        .disconnectAlert($confirmingDisconnect, directory: directory)
        .refreshable { await reload() }
        .task { await reload() }
        // Black "+" and alert buttons, like the rest of the Connectors surfaces.
        .tint(Palette.textPrimary.color)
        .accessibilityIdentifier("settings.connectors")
    }

    private func reload() async {
        async let tools: Void = directory.load()
        async let access: Void = directory.loadAccess()
        _ = await (tools, access)
        if directory.access.canManageShared { await directory.shared.load() }
    }

    // MARK: Yours

    @ViewBuilder
    private var yoursSection: some View {
        Section {
            if access == .unknown {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Palette.surface.color)
            } else if let reason = access.personalUnavailableReason {
                PersonalUnavailableRow(reason: reason, isAdmin: access.isAdmin, host: directory.host)
                    .listRowBackground(Palette.surface.color)
            } else {
                ForEach(personal.connections) { connection in
                    personalRow(connection)
                }
                Button {
                    flow.form = ConnectorForm(kind: .personal)
                } label: {
                    Label("Add personal connector", systemImage: "plus.circle")
                        .foregroundStyle(Palette.textPrimary.color)
                }
                .listRowBackground(Palette.surface.color)
                .accessibilityIdentifier("connectors.personal.add")
            }
        } header: {
            Text("Yours")
        } footer: {
            if access.canUsePersonal {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Your iPhone calls these while Theseus is open, like the web app does in the browser. Only you can use them.")
                    if pro?.allows(.connectors) == false {
                        Button {
                            paywall = PaywallRequest(.connectors)
                        } label: {
                            Text("Chats use them with Theseus Pro ›").underline()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connectors.personal.pro")
                    }
                    if access.isAdmin {
                        NavigationLink(value: SettingsPage.userPermissions) {
                            Text("Choose whether others on \(directory.host) can add their own ›")
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connectors.personal.permissionsLink")
                    }
                }
            }
        }
    }

    private func personalRow(_ connection: ToolServerConnection) -> some View {
        let (status, isError) = personalStatus(connection)
        return Button {
            flow.form = ConnectorForm(kind: .personal, existing: connection, hasStoredKey: personal.hasKey(connection))
        } label: {
            ConnectionRow(connection: connection, scope: .personal, status: status, statusIsError: isError, isBusy: personal.busy == connection.id)
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.surface.color)
        .contextMenu { personalActions(connection) }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { flow.removing = (connection, true) }
            Button(connection.isEnabled ? "Turn off" : "Turn on", systemImage: connection.isEnabled ? "pause.circle" : "play.circle") {
                Task { await personal.setEnabled(connection, !connection.isEnabled) }
            }
        }
        .accessibilityIdentifier("connectors.personal.\(connection.displayName)")
    }

    @ViewBuilder
    private func personalActions(_ connection: ToolServerConnection) -> some View {
        Button("Edit", systemImage: "pencil") {
            flow.form = ConnectorForm(kind: .personal, existing: connection, hasStoredKey: personal.hasKey(connection))
        }
        Button(connection.isEnabled ? "Turn off" : "Turn on", systemImage: connection.isEnabled ? "pause.circle" : "play.circle") {
            Task { await personal.setEnabled(connection, !connection.isEnabled) }
        }
        Button("Remove", systemImage: "trash", role: .destructive) { flow.removing = (connection, true) }
    }

    private func personalStatus(_ connection: ToolServerConnection) -> (String, Bool) {
        guard connection.isEnabled else { return ("Off", false) }
        switch personal.status[connection.id] {
        case .ready(let tools)?: return (tools.count == 1 ? "1 tool" : "\(tools.count) tools", false)
        case .failed(let message)?: return (message, true)
        case .checking?, nil: return ("Checking…", false)
        }
    }

    // MARK: From <host>

    @ViewBuilder
    private var sharedSection: some View {
        Section {
            switch directory.state {
            case .idle, .loading where directory.connectors.isEmpty:
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Palette.surface.color)
            case .failed(let message):
                VStack(spacing: Spacing.s) {
                    ConnectorsEmptyState(pose: .peek, title: "Couldn't load connectors", message: message)
                    Button("Try Again") { Task { await reload() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("connectors.retry")
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Palette.surface.color)
            default:
                sharedRows
            }
        } header: {
            Text("From \(directory.host)")
        } footer: {
            if !directory.usable.isEmpty {
                Text(access.isAdmin
                    ? "You manage these in Server administration. Turn them on for a chat under + › Connectors in the composer."
                    : "Your Server admin sets these up. Turn them on for a chat under + › Connectors in the composer.")
            }
        }
    }

    private var disabledShared: [ToolServerConnection] {
        guard access.canManageShared else { return [] }
        return directory.shared.connections.filter { !$0.isEnabled }
    }

    @ViewBuilder
    private var sharedRows: some View {
        if directory.connectors.isEmpty && disabledShared.isEmpty {
            SharedEmptyState(host: directory.host, canAdd: access.canManageShared) {
                flow.form = ConnectorForm(kind: .shared)
            }
            .listRowBackground(Palette.surface.color)
        } else {
            ForEach(directory.usable) { connector in
                sharedRow(connector)
            }
            // Admins also manage OAuth 2.1 servers nobody has connected yet.
            if access.canManageShared {
                ForEach(directory.awaitingConnection.filter { directory.sharedConnection(for: $0) != nil }) { connector in
                    sharedRow(connector, status: "Not connected yet")
                }
            }
            ForEach(disabledShared) { connection in
                ConnectionRow(connection: connection, scope: .audience(directory.shared.audienceLabel(connection)), status: "Off", isBusy: directory.shared.busy == connection.id)
                    .listRowBackground(Palette.surface.color)
                    .contextMenu { SharedConnectionActions(connection: connection, flow: $flow, shared: directory.shared) }
                    .accessibilityIdentifier("connectors.shared.\(connection.serverID)")
            }
            if !directory.awaitingConnection.isEmpty {
                Button {
                    showsDirectory = true
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Label("Connect more", systemImage: "plus.circle")
                            .foregroundStyle(Palette.textPrimary.color)
                        Text("\(directory.awaitingConnection.count) more need you to sign in before chats can use them.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
                .listRowBackground(Palette.surface.color)
                .accessibilityIdentifier("connectors.connectMore")
            }
            if access.canManageShared {
                AddSharedConnectorButton { flow.form = ConnectorForm(kind: .shared) }
            }
        }
    }

    private func sharedRow(_ connector: ToolEntry, status: String? = nil) -> some View {
        let connection = access.canManageShared ? directory.sharedConnection(for: connector) : nil
        let scope: ConnectorScope = connection.map { .audience(directory.shared.audienceLabel($0)) } ?? .shared(directory.host)
        let isBusy = directory.disconnecting == connector.id || (connection.map { directory.shared.busy == $0.id } ?? false)
        return Group {
            if let connection {
                // Admins: tap to edit the connection behind the Connector.
                Button {
                    flow.form = ConnectorForm(kind: .shared, existing: connection, hasStoredKey: !connection.key.isEmpty)
                } label: {
                    SharedConnectorRow(connector: connector, scope: scope, status: status, isBusy: isBusy)
                }
                .buttonStyle(.plain)
            } else {
                SharedConnectorRow(connector: connector, scope: scope, status: status, isBusy: isBusy)
            }
        }
        .listRowBackground(Palette.surface.color)
        .contextMenu {
            if let connection {
                SharedConnectionActions(connection: connection, flow: $flow, shared: directory.shared)
            }
            if directory.canDisconnect(connector) {
                Button("Disconnect", systemImage: "minus.circle", role: .destructive) {
                    confirmingDisconnect = connector
                }
            }
        }
        .accessibilityIdentifier("connectors.row.\(connector.id)")
    }
}

/// A shared Connector: its label, its scope badge, and a spinner while it changes.
private struct SharedConnectorRow: View {
    let connector: ToolEntry
    let scope: ConnectorScope
    var status: String?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ConnectorLabel(connector: connector)
                if let status {
                    Text(status)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(.leading, 30 + Spacing.m)
                }
                ScopeBadge(scope: scope).padding(.leading, 30 + Spacing.m)
            }
            Spacer(minLength: Spacing.s)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .contentShape(.rect)
        // One element per row, so its identifier (`connectors.row.<id>`) matches exactly once.
        .accessibilityElement(children: .combine)
    }
}

/// Why the Yours section has no controls.
private struct PersonalUnavailableRow: View {
    let reason: ConnectorAccess.PersonalUnavailableReason
    let isAdmin: Bool
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text(title).font(Typography.body).foregroundStyle(Palette.textPrimary.color)
            } icon: {
                Image(systemName: "lock").foregroundStyle(Palette.textSecondary.color)
            }
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            if isAdmin, reason == .notPermitted {
                NavigationLink(value: SettingsPage.userPermissions) {
                    Text("Server administration › User permissions")
                }
                .accessibilityIdentifier("connectors.personal.permissionsLink")
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectors.personal.unavailable")
    }

    private var title: String {
        switch reason {
        case .notPermitted: "Your Server admin hasn't allowed personal connectors"
        case .integrationsOff: "Personal connectors are off on \(host)"
        case .toolServersOff: "Tool servers are off on \(host)"
        }
    }

    private var message: String {
        switch reason {
        case .notPermitted:
            "Personal connectors let you plug your own tool servers into chats. Ask your admin to allow them."
        case .integrationsOff:
            isAdmin
                ? "Turn on Direct Integrations in Open WebUI › Admin › Settings › Connections to let people add their own tool servers."
                : "Your Server admin has turned off direct integrations, so there are no personal connectors."
        case .toolServersOff:
            isAdmin
                ? "Turn on tool servers in Open WebUI › Admin › Settings › External Tools to use personal and shared connectors."
                : "Your Server admin has turned tool servers off, so there are no personal connectors."
        }
    }
}

/// "No connectors on <host> yet", with the next step: Add for admins, who to ask for everyone else.
struct SharedEmptyState: View {
    let host: String
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MouseEmptyState(
                pose: .sleep,
                scale: 2,
                title: Text("No connectors on \(host) yet"),
                message: Text(canAdd
                    ? "Add an MCP or OpenAPI server, and everyone you choose can use it in their chats."
                    : "Your Server admin adds connectors in Open WebUI › Admin › Settings › External Tools.")
            )
            // On the text only: an identifier on a container would also replace the button's.
            .accessibilityIdentifier("connectors.empty")
            if canAdd {
                Button("Add connector", systemImage: "plus", action: add)
                    .buttonStyle(.accentPill)
                    .padding(.bottom, Spacing.l)
                    .accessibilityIdentifier("connectors.empty.add")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AddSharedConnectorButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add connector", systemImage: "plus.circle")
                .foregroundStyle(Palette.textPrimary.color)
        }
        .listRowBackground(Palette.surface.color)
        .accessibilityIdentifier("connectors.shared.add")
    }
}

/// Edit / Turn off·on / Remove for a shared connection (admins).
struct SharedConnectionActions: View {
    let connection: ToolServerConnection
    @Binding var flow: ConnectionFlowState
    let shared: ServerConnections

    var body: some View {
        Button("Edit", systemImage: "pencil") {
            flow.form = ConnectorForm(kind: .shared, existing: connection, hasStoredKey: !connection.key.isEmpty)
        }
        Button(connection.isEnabled ? "Turn off for everyone" : "Turn on", systemImage: connection.isEnabled ? "pause.circle" : "play.circle") {
            Task { await shared.setEnabled(connection, !connection.isEnabled) }
        }
        Button("Remove", systemImage: "trash", role: .destructive) { flow.removing = (connection, false) }
    }
}
