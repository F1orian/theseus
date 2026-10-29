import DesignSystem
import OpenWebUIKit
import SettingsFeature
import SwiftUI

/// Settings › Server administration › Connectors (#186, admins): every tool-server connection on
/// the Server, on or off, with who can use it. Tap to edit; swipe or long-press to turn off or
/// remove. Changes affect everyone on the Server, which the header says.
struct ServerConnectionsPage: View {
    let directory: ConnectorDirectory

    @State private var flow = ConnectionFlowState()

    private var shared: ServerConnections { directory.shared }

    var body: some View {
        List {
            Section {
                if !directory.access.toolServersEnabled, directory.access != .unknown {
                    Label("Tool servers are off on \(directory.host). Turn them on in Open WebUI › Admin › Settings › External Tools; connections below stay unused until then.", systemImage: "exclamationmark.triangle")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .listRowBackground(Palette.surface.color)
                }
                switch shared.state {
                case .idle, .loading where shared.connections.isEmpty:
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Palette.surface.color)
                case .failed(let message):
                    VStack(spacing: Spacing.s) {
                        ConnectorsEmptyState(pose: .peek, title: "Couldn't load connections", message: message)
                        Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Palette.surface.color)
                default:
                    if shared.connections.isEmpty {
                        SharedEmptyState(host: directory.host, canAdd: true) { flow.form = ConnectorForm(kind: .shared) }
                            .listRowBackground(Palette.surface.color)
                    } else {
                        ForEach(shared.connections) { connection in
                            row(connection)
                        }
                        AddSharedConnectorButton { flow.form = ConnectorForm(kind: .shared) }
                    }
                }
            } header: {
                AdministrationHeader(host: directory.host)
            } footer: {
                if !shared.connections.isEmpty {
                    Text("People turn these on per chat under + › Connectors. OAuth 2.1 servers ask each person to connect once. Python workspace tools are managed in the web admin.")
                }
            }
        }
        .connectorsList()
        .safeAreaInset(edge: .bottom) {
            if let notice = shared.notice ?? directory.notice {
                ConnectorsNotice(message: notice) {
                    shared.notice = nil
                    directory.notice = nil
                }
            }
        }
        .navigationTitle("Connectors")
        .connectorsInlineTitle()
        .connectionFlow($flow, directory: directory)
        .refreshable { await reload() }
        .task { await reload() }
        .tint(Palette.textPrimary.color)
        .accessibilityIdentifier("administration.connectors")
    }

    private func reload() async {
        await directory.loadAccess()
        await shared.load()
    }

    private func row(_ connection: ToolServerConnection) -> some View {
        Button {
            flow.form = ConnectorForm(kind: .shared, existing: connection, hasStoredKey: !connection.key.isEmpty)
        } label: {
            ConnectionRow(
                connection: connection,
                scope: .audience(shared.audienceLabel(connection)),
                status: status(connection),
                isBusy: shared.busy == connection.id
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.surface.color)
        .contextMenu { SharedConnectionActions(connection: connection, flow: $flow, shared: shared) }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { flow.removing = (connection, false) }
            Button(connection.isEnabled ? "Turn off" : "Turn on", systemImage: connection.isEnabled ? "pause.circle" : "play.circle") {
                Task { await shared.setEnabled(connection, !connection.isEnabled) }
            }
        }
        .accessibilityIdentifier("administration.connectors.\(connection.serverID.isEmpty ? connection.displayName : connection.serverID)")
    }

    private func status(_ connection: ToolServerConnection) -> String {
        var parts: [String] = [connection.isEnabled ? "On" : "Off"]
        switch connection.authType {
        case .none: parts.append("no sign-in")
        case .bearer: parts.append(connection.key.isEmpty ? "key missing" : "key •••• set")
        case .oauth21, .oauth21Static: parts.append("each person connects")
        default: parts.append(connection.authType.label.lowercased())
        }
        return parts.joined(separator: " · ")
    }
}
