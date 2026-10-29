import DesignSystem
import OpenWebUIKit
import SwiftUI

/// Whose a connector is (#186): personal ones carry "Only you", shared ones "Everyone on <host>"
/// or their groups, so the two are never confused.
enum ConnectorScope: Equatable {
    case personal
    /// Shared on the Server, audience unknown (non-admins can't see it).
    case shared(String)
    /// Shared with a known audience: "Everyone on <host>", group names, "Only admins".
    case audience(String)

    var text: String {
        switch self {
        case .personal: "Only you"
        case .shared(let host): "Shared on \(host)"
        case .audience(let label): label
        }
    }

    var systemImage: String {
        switch self {
        case .personal: "person.fill"
        case .shared, .audience: "person.3.fill"
        }
    }
}

/// A small plaque naming a connector's scope.
struct ScopeBadge: View {
    let scope: ConnectorScope

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: scope.systemImage)
                .imageScale(.small)
            Text(scope.text)
                .lineLimit(1)
        }
        .plaqueStyle(color: scope == .personal ? Palette.accent : Palette.textSecondary)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 3)
        .background(scope == .personal ? Palette.accentSoft.color : Palette.recessedSurface.color, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scope.text)
    }
}

/// A row for a personal connector or a shared connection: initial tile, name, type, a status
/// line and the scope badge.
struct ConnectionRow: View {
    let connection: ToolServerConnection
    let scope: ConnectorScope
    let status: String?
    var statusIsError = false
    var isBusy = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            ConnectorInitialTile(name: connection.displayName, isDimmed: !connection.isEnabled)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(connection.displayName)
                        .font(Typography.body)
                        .foregroundStyle(connection.isEnabled ? Palette.textPrimary.color : Palette.textSecondary.color)
                        .lineLimit(1)
                    Text(connection.type.label)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary.color)
                }
                if let status {
                    Text(status)
                        .font(Typography.callout)
                        .foregroundStyle(statusIsError ? Palette.destructive.color : Palette.textSecondary.color)
                        .lineLimit(2)
                }
                ScopeBadge(scope: scope)
            }
            Spacer(minLength: Spacing.s)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The initial-on-a-tile mark for a connection (no logos exist in Open WebUI).
struct ConnectorInitialTile: View {
    let name: String
    var isDimmed = false
    var size: CGFloat = 30

    var body: some View {
        Text(name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•")
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(isDimmed ? Palette.textTertiary.color : Palette.textPrimary.color)
            .frame(width: size, height: size)
            .background(Palette.surface.color, in: .rect(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(Palette.separator.color))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The Remove confirmation (#186): names the effect before anything is deleted.
    func removeConnectionAlert(
        _ connection: Binding<ToolServerConnection?>,
        personal: Bool,
        host: String,
        remove: @escaping @MainActor (ToolServerConnection) async -> Void
    ) -> some View {
        alert(
            "Remove \(connection.wrappedValue?.displayName ?? "connector")?",
            isPresented: Binding(get: { connection.wrappedValue != nil }, set: { if !$0 { connection.wrappedValue = nil } }),
            presenting: connection.wrappedValue
        ) { target in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await remove(target) }
            }
            .accessibilityIdentifier("connectors.remove.confirm")
        } message: { target in
            if personal {
                Text("Chats will lose its tools, here and in the Open WebUI web app.")
            } else {
                Text("Chats will lose its tools, for everyone on \(host) who uses \(target.displayName).")
            }
        }
    }
}
