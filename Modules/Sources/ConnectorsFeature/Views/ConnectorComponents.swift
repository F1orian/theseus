import DesignSystem
import OpenWebUIKit
import SwiftUI

/// A Connector's mark: its initial on a tile (Open WebUI has no Connector logos).
struct ConnectorIcon: View {
    let connector: ToolEntry
    var size: CGFloat = 30

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textPrimary.color)
            .frame(width: size, height: size)
            .background(Palette.surface.color, in: .rect(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(Palette.separator.color))
            .accessibilityHidden(true)
    }

    private var initial: String {
        connector.name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

extension ToolEntry {
    /// A short, user-facing tag for the kind of Connector.
    var kindLabel: String {
        switch kind {
        case .workspaceTool: "Tool"
        case .toolServer: "Tool server"
        case .mcpServer: "MCP"
        }
    }
}

/// A Connector row: icon, name with its kind tag, and a one-line description.
struct ConnectorLabel: View {
    let connector: ToolEntry
    var descriptionLines = 1

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            ConnectorIcon(connector: connector)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(connector.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(1)
                    Text(connector.kindLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary.color)
                }
                if let description = connector.description {
                    Text(description)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(descriptionLines)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The black "Connect" pill of the directory and Add to Chat rows (CONN-03).
struct ConnectPill: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small).tint(Palette.background.color)
                } else {
                    Text("Connect")
                }
            }
            .font(Typography.callout.weight(.semibold))
            .foregroundStyle(Palette.background.color)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 34)
            .background(Palette.textPrimary.color, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

/// The "Connected" mark once a Connector is signed in (CONN-03), in the verdigris accent (live state).
struct ConnectedMark: View {
    var body: some View {
        Label("Connected", systemImage: "checkmark.circle.fill")
            .font(Typography.callout.weight(.semibold))
            .foregroundStyle(Palette.accent.color)
            .labelStyle(.titleAndIcon)
    }
}

/// A centred empty or error state with the pixel mouse (brand.md §3, BRAND-04; no painting here):
/// `.sleep` when there's nothing yet, `.sit` for a quiet directory, `.peek` when loading failed.
struct ConnectorsEmptyState: View {
    var pose: PixelMouse.Pose = .sleep
    let title: String
    let message: String

    var body: some View {
        MouseEmptyState(pose: pose, title: Text(title), message: Text(message))
            .frame(maxWidth: .infinity)
    }
}

/// A dismissible problem line docked at the bottom of a Connectors page.
struct ConnectorsNotice: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.destructive.color)
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
        .accessibilityIdentifier("connectors.notice")
    }
}

extension View {
    /// Inset-grouped cards on the warm canvas, like the Settings sheet.
    func connectorsList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .themedBackground()
        #else
        scrollContentBackground(.hidden)
            .themedBackground()
        #endif
    }

    func connectorsInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Presents the connect sheet (CONN-03) for `authorization`.
    func connectSheet(
        _ authorization: Binding<ConnectorAuthorization?>,
        directory: ConnectorDirectory,
        onConnected: @escaping @MainActor (String) -> Void = { _ in }
    ) -> some View {
        modifier(ConnectSheetModifier(authorization: authorization, directory: directory, onConnected: onConnected))
    }
}

private struct ConnectSheetModifier: ViewModifier {
    @Binding var authorization: ConnectorAuthorization?
    let directory: ConnectorDirectory
    let onConnected: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: $authorization) { authorization in
            ConnectorConnectSheet(authorization: authorization) { event in
                self.authorization = nil
                Task {
                    if await directory.connectionFinished(authorization.connectorID, result: event) {
                        onConnected(authorization.connectorID)
                    }
                }
            }
            .interactiveDismissDisabled()
        }
        #else
        content
        #endif
    }
}
