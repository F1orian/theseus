import ChatDomain
import Auth
import DesignSystem
import Entitlements
import OpenWebUIKit
public import SwiftUI

/// The Settings sheet (SET-01): close and info buttons, the Account card, the Account and App
/// groups, Appearance and Log out. Pages push inside the sheet.
public struct SettingsView: View {
    @Bindable var model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            SettingsHome(model: model)
                .navigationDestination(for: SettingsPage.self) { page in
                    destination(for: page)
                }
        }
        .inAppBrowser()
        .task { await model.load() }
        .accessibilityIdentifier("settings.sheet")
    }

    @ViewBuilder
    private func destination(for page: SettingsPage) -> some View {
        switch page {
        case .extension(let page):
            if let view = model.extensions.destination(for: page) {
                view
            } else {
                SettingsPlaceholderPage(page: page)
            }
        case .capabilities:
            CapabilitiesSettingsView(
                model: CapabilitiesSettingsModel(client: model.client, capabilities: model.capabilities),
                extensions: model.extensions
            )
        case .skills:
            SkillsSettingsView(model: model.makeSkillsModel())
        case .skillsAdministration:
            SkillsAdministrationView(model: model.makeSkillsAdministrationModel())
        case .sharedLinks:
            SharedLinksView(model: model.sharedLinks)
        case .sharedChat(let link):
            SharedChatView(link: link, model: model.sharedLinks)
        case .serverUsage:
            ServerUsageView(model: ServerUsageModel(account: model.account, client: model.client, user: model.user))
        case .dataPrivacy:
            DataPrivacyView(model: model.makeDataPrivacyModel())
        case .notifications:
            NotificationSettingsView(notifier: model.notifier)
        case .about:
            AboutView(serverName: ServerDisplay.name(model.account.server.name), serverVersion: model.serverVersion)
        case .acknowledgements:
            AcknowledgementsView()
        case .appIcon:
            AppIconPickerView(model: model.appIcons, pro: model.pro)
        case .collection:
            CollectionView()
        case .administration:
            ServerAdministrationView(host: model.serverHost, rows: model.extensions.administrationRows)
        case .administrationRow(let id):
            if let view = model.extensions.administrationDestination(for: id) {
                view
            } else {
                SettingsEmptyState(title: "Not available", message: "This page isn't available on this Server.", pose: .sit)
            }
        case .userPermissions:
            UserPermissionsView(model: model.makeUserPermissionsModel())
        case .pro:
            if let pro = model.pro { ProSettingsView(store: pro) }
        }
    }
}

private struct SettingsHome: View {
    @Bindable var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingLogOut = false
    @State private var paywall: PaywallRequest?

    var body: some View {
        @Bindable var preferences = model.preferences
        List {
            // ADR 0173: the upgrade card leads in the free tier.
            if let pro = model.pro, pro.status == .free {
                Section {
                    ProUpgradeCard(store: pro) { paywall = PaywallRequest() }
                }
            }
            Section {
                AccountCard(model: model)
            }
            Section("Account") {
                ForEach(model.accountRows, id: \.self) { row in
                    rowView(row)
                }
            }
            Section("App") {
                if let pro = model.pro {
                    NavigationLink(value: SettingsPage.pro) {
                        LabeledContent {
                            Text(pro.isPro ? "Active" : "Free")
                                .foregroundStyle(Palette.textSecondary.color)
                        } label: {
                            SettingsRowLabel(title: "Theseus Pro", systemImage: "seal")
                        }
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("settings.row.pro")
                }
                ForEach(model.appRows, id: \.self) { row in
                    rowView(row)
                }
            }
            Section("Appearance") {
                AppearancePicker(selection: $preferences.preferences.appearance)
                    .settingsRowBackground()
                // #179: Verdigris, Ultramarine or Oxblood, applied live (ADR 0145).
                AccentPicker(selection: $preferences.preferences.accent)
                    .settingsRowBackground()
                // BRAND-03's "Today in the collection" card on the new-chat home.
                SettingsToggleRow(
                    title: "Show today's artwork",
                    systemImage: "photo.artframe",
                    isOn: $preferences.preferences.showsTodayArtwork
                )
                .accessibilityIdentifier("settings.showTodayArtwork")
                if model.showsAppIconRow {
                    NavigationLink(value: SettingsPage.appIcon) {
                        AppIconRowLabel(current: model.appIcons.current)
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("settings.row.appIcon")
                }
            }
            // #186: Server administration, for admins only ("Changes affect everyone on <host>").
            if model.showsAdministration {
                Section {
                    NavigationLink(value: SettingsPage.administration) {
                        SettingsRowLabel(title: "Server administration", systemImage: "building.columns")
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("settings.row.administration")
                } header: {
                    Text("Server")
                } footer: {
                    Text("You're an admin on \(model.serverHost).")
                }
            }
            Section {
                Button {
                    isConfirmingLogOut = true
                } label: {
                    SettingsRowLabel(
                        title: "Log out",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tint: Palette.destructive.color
                    )
                }
                .accessibilityIdentifier("account.signOut")
                .popover(isPresented: $isConfirmingLogOut, arrowEdge: .bottom) {
                    LogOutConfirmation {
                        isConfirmingLogOut = false
                        Task { await model.logOut() }
                    }
                    .presentationCompactAdaptation(.popover)
                }
                .settingsRowBackground()
            }
        }
        .settingsList()
        .paywall($paywall)
        .navigationTitle("Settings")
        .settingsInlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .tint(Palette.textPrimary.color)
                    .accessibilityIdentifier("settings.close")
            }
            ToolbarItem(placement: .primaryAction) {
                AboutMenu(model: model)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRow) -> some View {
        @Bindable var preferences = model.preferences
        switch row {
        case .hapticFeedback:
            SettingsToggleRow(
                title: "Haptic feedback",
                systemImage: "iphone.radiowaves.left.and.right",
                isOn: $preferences.preferences.hapticFeedback
            )
            .accessibilityIdentifier("settings.haptics")
        default:
            if let page = row.page {
                NavigationLink(value: page) {
                    SettingsRowLabel(title: row.title, systemImage: row.systemImage)
                }
                .settingsRowBackground()
                .accessibilityIdentifier("settings.row.\(row.identifier)")
            }
        }
    }
}

/// The Account's email at the top, with its Server, and the Account switcher slot (AUTH-07).
private struct AccountCard: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            // An address stays on one line: wrapped, it got a hyphen ("example.-com") at the
            // accessibility sizes. It shrinks first and truncates in the middle as a last resort.
            Text(verbatim: model.account.email)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .truncationMode(.middle)
                .accessibilityIdentifier("settings.account.email")
            Text("\(model.account.name) · \(ServerDisplay.host(model.account.server.url, fallback: model.account.server.name))")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(.vertical, Spacing.xs)
        .settingsRowBackground()
        .accessibilityElement(children: .combine)

        if let switchAccount = model.switchAccount {
            Button {
                switchAccount()
            } label: {
                SettingsRowLabel(title: "Switch account", systemImage: "person.2")
            }
            .settingsRowBackground()
            .accessibilityIdentifier("settings.switchAccount")
        }
    }
}

/// The small anchored confirmation with a red Log out pill (SET-04).
private struct LogOutConfirmation: View {
    let confirm: () -> Void

    var body: some View {
        Button(role: .destructive, action: confirm) {
            Text("Log out")
                .font(Typography.headline)
                .foregroundStyle(Palette.destructive.color)
                .frame(minWidth: 200, minHeight: 44)
                .background(Palette.recessedSurface.color, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(Spacing.m)
        .accessibilityIdentifier("account.signOut.confirm")
    }
}

extension SettingsRow {
    var page: SettingsPage? {
        switch self {
        case .profile: .extension(.profile)
        case .instructions: .extension(.instructions)
        case .serverUsage: .serverUsage
        case .notifications: .notifications
        case .dataPrivacy: .dataPrivacy
        case .sharedLinks: .sharedLinks
        case .capabilities: .capabilities
        case .skills: .skills
        case .connectors: .extension(.connectors)
        case .permissions: .extension(.permissions)
        case .voice: .extension(.voice)
        case .styles: .extension(.styles)
        case .models: .extension(.models)
        case .hapticFeedback: nil
        }
    }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .instructions: "Instructions"
        case .serverUsage: "Server & usage"
        case .notifications: "Notifications"
        case .dataPrivacy: "Data & privacy"
        case .sharedLinks: "Shared links"
        case .capabilities: "Capabilities"
        case .skills: "Skills"
        case .connectors: "Connectors"
        case .permissions: "Permissions"
        case .voice: "Voice"
        case .styles: "Styles"
        case .models: "Models"
        case .hapticFeedback: "Haptic feedback"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: "person.crop.circle"
        case .instructions: "text.quote"
        case .serverUsage: "server.rack"
        case .notifications: "bell"
        case .dataPrivacy: "lock.shield"
        case .sharedLinks: "link"
        case .capabilities: "slider.horizontal.3"
        case .skills: "sparkles"
        case .connectors: "square.grid.2x2"
        case .permissions: "switch.2"
        case .voice: "waveform"
        case .styles: "paintbrush"
        case .models: "cpu"
        case .hapticFeedback: "iphone.radiowaves.left.and.right"
        }
    }

    var identifier: String {
        switch self {
        case .profile: "profile"
        case .instructions: "instructions"
        case .serverUsage: "serverUsage"
        case .notifications: "notifications"
        case .dataPrivacy: "dataPrivacy"
        case .sharedLinks: "sharedLinks"
        case .capabilities: "capabilities"
        case .skills: "skills"
        case .connectors: "connectors"
        case .permissions: "permissions"
        case .voice: "voice"
        case .styles: "styles"
        case .models: "models"
        case .hapticFeedback: "haptics"
        }
    }
}
