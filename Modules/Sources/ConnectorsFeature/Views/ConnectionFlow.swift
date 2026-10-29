import DesignSystem
import OpenWebUIKit
import SwiftUI

/// The sheets and alerts around adding, editing and removing connections (#186), shared by
/// Settings › Connectors and Server administration › Connectors.
struct ConnectionFlowState {
    /// The Add / Edit sheet.
    var form: ConnectorForm?
    /// A Remove confirmation: the connection, and whether it's personal.
    var removing: (connection: ToolServerConnection, personal: Bool)?
    /// After saving an OAuth 2.1 MCP server: offer "Connect now".
    var offerConnect: ToolServerConnection?
    /// The Connect sheet (ADR 0090).
    var authorization: ConnectorAuthorization?
}

extension ConnectorForm: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension View {
    func connectionFlow(_ flow: Binding<ConnectionFlowState>, directory: ConnectorDirectory) -> some View {
        modifier(ConnectionFlowModifier(flow: flow, directory: directory))
    }
}

private struct ConnectionFlowModifier: ViewModifier {
    @Binding var flow: ConnectionFlowState
    let directory: ConnectorDirectory

    func body(content: Content) -> some View {
        // Read now: the alert clears `removing` before its button's action runs.
        let removesPersonal = flow.removing?.personal ?? false
        return content
            .sheet(item: $flow.form) { form in
                ConnectorFormSheet(form: form, directory: directory) { saved in
                    guard form.kind == .shared else { return }
                    Task {
                        if form.usesOAuth, !form.isEditing || form.existing?.authType != saved.authType {
                            flow.offerConnect = saved
                        }
                    }
                }
            }
            .removeConnectionAlert(
                Binding(get: { flow.removing?.connection }, set: { if $0 == nil { flow.removing = nil } }),
                personal: removesPersonal,
                host: directory.host
            ) { connection in
                flow.removing = nil
                if removesPersonal {
                    await directory.personal.remove(connection)
                } else {
                    await directory.shared.remove(connection)
                }
            }
            .alert(
                "Connect \(flow.offerConnect?.displayName ?? "it") now?",
                isPresented: Binding(get: { flow.offerConnect != nil }, set: { if !$0 { flow.offerConnect = nil } }),
                presenting: flow.offerConnect
            ) { connection in
                Button("Later", role: .cancel) {}
                Button("Connect now") {
                    Task { await connect(connection) }
                }
                .accessibilityIdentifier("connectors.connectNow")
            } message: { connection in
                Text("\(connection.displayName) signs in with OAuth 2.1. Connect your account now; everyone else connects from their own Settings › Connectors.")
            }
            .connectSheet($flow.authorization, directory: directory)
    }

    private func connect(_ connection: ToolServerConnection) async {
        await directory.load()
        // Let the alert finish dismissing before the Connect sheet comes up.
        try? await Task.sleep(for: .milliseconds(500))
        guard let entry = directory.connector(id: connection.toolID) else {
            directory.notice = "\(connection.displayName) isn't listed yet. Try Connect from the + directory in a moment."
            return
        }
        flow.authorization = await directory.connection(for: entry)
    }
}
