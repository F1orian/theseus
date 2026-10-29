import DesignSystem
import OpenWebUIKit
import SwiftUI

/// Settings > Server & usage (SET-09), in place of a billing page.
struct ServerUsageView: View {
    @State private var model: ServerUsageModel

    init(model: ServerUsageModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section("Server") {
                SettingsValueRow(title: "Name", value: model.account.server.name)
                SettingsValueRow(title: "Address", value: model.serverHost)
                SettingsValueRow(title: "Open WebUI", value: model.serverVersion ?? "—")
                    .accessibilityIdentifier("serverUsage.version")
                if let role = model.role {
                    SettingsValueRow(title: "Your role", value: role)
                }
            }
            Section {
                if let usage = model.usage {
                    UsageTiles(usage: usage)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else if let error = model.usageError {
                    Text(error)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .settingsRowBackground()
                } else {
                    ProgressView().frame(maxWidth: .infinity).settingsRowBackground()
                }
            } header: {
                Text("Your usage")
            } footer: {
                Text("This Server has no plans or usage limits. These are your own statistics\(periodSuffix).")
            }
            if let models = model.usage?.topModels, !models.isEmpty {
                Section("Most used models") {
                    ForEach(models.prefix(5)) { item in
                        SettingsValueRow(
                            title: item.modelID,
                            value: "\(item.messages.formatted()) messages"
                        )
                    }
                }
            }
        }
        .settingsList()
        .navigationTitle("Server & usage")
        .settingsInlineTitle()
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("settings.serverUsage")
    }

    private var periodSuffix: String {
        guard let days = model.usage?.periodDays, days > 0 else { return "" }
        return days % 365 == 0 ? " for the last \(days / 365 == 1 ? "year" : "\(days / 365) years")" : " for the last \(days) days"
    }
}

/// Four headline numbers as tiles.
private struct UsageTiles: View {
    let usage: UsageStats

    var body: some View {
        Grid(horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
            GridRow {
                tile("Chats", usage.totals.chats.formatted())
                tile("Messages", usage.totals.messages.formatted())
            }
            GridRow {
                tile("Tokens", ServerUsageModel.compact(usage.totals.lifetimeTokens))
                tile("Active days", usage.totals.activeDays.formatted())
            }
        }
        .accessibilityIdentifier("serverUsage.tiles")
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(value)
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary.color)
            Text(title)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .accessibilityElement(children: .combine)
    }
}
