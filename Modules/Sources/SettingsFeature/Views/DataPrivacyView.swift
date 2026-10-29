import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// Settings > Data & privacy (SET-07): where the data lives, who runs the Server, the local cache,
/// and the Account's device and deletion options (SET-10).
struct DataPrivacyView: View {
    @State private var model: DataPrivacyModel
    @State private var isConfirmingClear = false

    init(model: DataPrivacyModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label("Your data lives on \(model.serverHost)", systemImage: "server.rack")
                        .font(Typography.headline)
                        .foregroundStyle(Palette.textPrimary.color)
                    Text(
                        "Chats, Projects, Memory and files are stored on this Server and handled by the models "
                            + "its admin connected. Theseus talks only to this Server and collects no analytics."
                    )
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.xs)
                .settingsRowBackground()
                .accessibilityIdentifier("dataPrivacy.where")
                Link(destination: PublicLinks.privacyPolicy) {
                    SettingsRowLabel(title: "Privacy policy", systemImage: "hand.raised")
                }
                .settingsRowBackground()
                .accessibilityIdentifier("dataPrivacy.policy")
            }
            Section {
                AdminContactRow(contact: model.adminContact, emailURL: model.adminEmailURL)
            } header: {
                Text("Server admin")
            } footer: {
                Text("Questions about how your data is kept, shared or deleted go to the admin of this Server.")
            }
            Section {
                SettingsValueRow(title: "Cached on this device", value: cacheLabel)
                    .accessibilityIdentifier("dataPrivacy.cacheSize")
                Button {
                    isConfirmingClear = true
                } label: {
                    HStack {
                        SettingsRowLabel(title: "Clear cache", systemImage: "trash")
                        if model.isClearingCache { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isClearingCache)
                .settingsRowBackground()
                .accessibilityIdentifier("dataPrivacy.clearCache")
            } header: {
                Text("On this device")
            } footer: {
                Text(model.didClearCache
                    ? "Cache cleared. Your chats reload from the Server."
                    : "Theseus keeps a copy of your chat list for fast, offline access. Clearing it doesn't delete anything on the Server.")
            }
            Section("Account") {
                DeleteAccountRow(model: model)
            }
        }
        .settingsList()
        .confirmationDialog("Clear the cache on this device?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear cache", role: .destructive) {
                Task { await model.clearCache() }
            }
        } message: {
            Text("Nothing on the Server is deleted.")
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                SettingsErrorBanner(message: message) { model.dismissError() }
            }
        }
        .navigationTitle("Data & privacy")
        .settingsInlineTitle()
        .task { await model.load() }
        .accessibilityIdentifier("settings.dataPrivacy")
    }

    private var cacheLabel: String {
        guard let size = model.cacheSize else { return "—" }
        return size.formatted(.byteCount(style: .file))
    }
}

private struct AdminContactRow: View {
    let contact: AdminContact?
    let emailURL: URL?

    var body: some View {
        if let contact, contact.name != nil || contact.email != nil {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let name = contact.name {
                    Text(name).font(Typography.body).foregroundStyle(Palette.textPrimary.color)
                }
                if let email = contact.email, let emailURL {
                    Link(email, destination: emailURL).font(Typography.callout)
                }
            }
            .settingsRowBackground()
            .accessibilityIdentifier("dataPrivacy.admin")
        } else {
            Text("This Server doesn't publish its admin's contact details.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .settingsRowBackground()
                .accessibilityIdentifier("dataPrivacy.admin")
        }
    }
}

/// "Remove from this device" and the red "Delete account" row (SET-10). Open WebUI only lets
/// admins delete users, so Delete account explains whom to contact and offers removal instead.
/// Other pages (e.g. Profile, PERS-01) can show it with `SettingsModel.makeDataPrivacyModel()`.
public struct DeleteAccountRow: View {
    let model: DataPrivacyModel
    @State private var isShowingDeleteInfo = false
    @State private var isConfirmingRemoval = false
    @Environment(\.openURL) private var openURL

    public init(model: DataPrivacyModel) {
        self.model = model
    }

    public var body: some View {
        Button {
            isConfirmingRemoval = true
        } label: {
            SettingsRowLabel(title: "Remove from this device", systemImage: "iphone.slash")
        }
        .settingsRowBackground()
        .accessibilityIdentifier("account.removeFromDevice")
        .confirmationDialog(
            "Remove \(model.account.email) from this device?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from this device", role: .destructive) {
                Task { await model.removeAccountFromDevice() }
            }
        } message: {
            Text("You'll be signed out and this device forgets the Account and its cache. Nothing on the Server is deleted.")
        }

        Button(role: .destructive) {
            isShowingDeleteInfo = true
        } label: {
            SettingsRowLabel(title: "Delete account", systemImage: "person.crop.circle.badge.xmark", tint: Palette.destructive.color)
        }
        .settingsRowBackground()
        .accessibilityIdentifier("account.delete")
        .alert("Contact your Server admin", isPresented: $isShowingDeleteInfo) {
            if let emailURL = model.adminEmailURL {
                Button("Email admin") { openURL(emailURL) }
            }
            Button("Remove from this device", role: .destructive) {
                Task { await model.removeAccountFromDevice() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .task {
            if model.adminContact == nil { await model.load() }
        }
    }

    private var deleteMessage: String {
        let admin = [model.adminContact?.name, model.adminContact?.email.map { "(\($0))" }]
            .compactMap(\.self)
            .joined(separator: " ")
        let who = admin.isEmpty ? "the admin of \(model.serverHost)" : admin
        return "Accounts on this Server can only be deleted by its admin. Ask \(who) to delete your account and its data. "
            + "You can also remove the Account from this device."
    }
}
