import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// Settings › Server administration (#186): admins only. Everything here changes the Server for
/// everyone on it, which the header says up front. Rows come from Feature areas
/// (`SettingsExtensions.registerAdministration`) plus the built-in User permissions.
struct ServerAdministrationView: View {
    let host: String
    let rows: [SettingsAdministrationRow]

    /// The contributed rows plus User permissions and Skills (#187), in `order`.
    private var entries: [Entry] {
        var all = rows.map { Entry.contributed($0) }
        all.append(.userPermissions)
        // #187's view lives in SettingsFeature too; a contributed "skills" row would replace it.
        if !rows.contains(where: { $0.id == "skills" }) { all.append(.skills) }
        return all.sorted { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.page) {
                        AdministrationRowLabel(title: entry.title, systemImage: entry.systemImage, subtitle: entry.subtitle)
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("settings.administration.\(entry.id)")
                }
            } header: {
                AdministrationHeader(host: host)
            } footer: {
                Text("Only admins see this section. People on \(host) see the result, not these controls.")
            }
        }
        .settingsList()
        .navigationTitle("Server administration")
        .settingsInlineTitle()
        .accessibilityIdentifier("settings.administration")
    }

    private enum Entry: Identifiable {
        case contributed(SettingsAdministrationRow)
        case userPermissions
        case skills

        var id: String {
            switch self {
            case .contributed(let row): row.id
            case .userPermissions: "userPermissions"
            case .skills: "skills"
            }
        }

        var title: String {
            switch self {
            case .contributed(let row): row.title
            case .userPermissions: "User permissions"
            case .skills: "Skills"
            }
        }

        var systemImage: String {
            switch self {
            case .contributed(let row): row.systemImage
            case .userPermissions: "person.2.badge.gearshape"
            case .skills: "sparkles"
            }
        }

        var subtitle: String? {
            switch self {
            case .contributed(let row): row.subtitle
            case .userPermissions: "What everyone may add or create"
            case .skills: "Every skill on the Server, and who it's shared with"
            }
        }

        var order: Int {
            switch self {
            case .contributed(let row): row.order
            case .userPermissions: SettingsAdministrationRow.Order.userPermissions
            case .skills: SettingsAdministrationRow.Order.skills
            }
        }

        var page: SettingsPage {
            switch self {
            case .contributed(let row): .administrationRow(row.id)
            case .userPermissions: .userPermissions
            case .skills: .skillsAdministration
            }
        }
    }
}

/// "Changes affect everyone on <host>": the warning every Server administration page starts with.
public struct AdministrationHeader: View {
    let host: String

    public init(host: String) {
        self.host = host
    }

    public var body: some View {
        Label {
            Text("Changes affect everyone on \(host)")
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .font(Typography.callout.weight(.semibold))
        .foregroundStyle(Palette.textSecondary.color)
        .textCase(nil)
        .accessibilityIdentifier("settings.administration.header")
    }
}

private struct AdministrationRowLabel: View {
    let title: String
    let systemImage: String
    let subtitle: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.textSecondary.color)
        }
    }
}

/// Server administration › User permissions (#186): the default permissions' two switches, each
/// confirmed before it's saved.
struct UserPermissionsView: View {
    @State var model: UserPermissionsModel

    var body: some View {
        List {
            Section {
                ForEach(UserPermissionsModel.Permission.all) { permission in
                    SettingsToggleRow(
                        title: permission.title,
                        systemImage: permission.systemImage,
                        caption: permission.caption,
                        isOn: Binding(
                            get: { model.isOn(permission) },
                            set: { model.request(permission, on: $0) }
                        )
                    )
                    .disabled(model.permissions == nil || model.saving != nil)
                    .accessibilityIdentifier("settings.userPermissions.\(permission.id)")
                }
            } header: {
                AdministrationHeader(host: model.host)
            } footer: {
                Text("These are the defaults for everyone who isn't an admin. Groups can allow more in Open WebUI › Admin › Users › Groups. Admins can always do both.")
            }
            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.destructive.color)
                        .settingsRowBackground()
                        .accessibilityIdentifier("settings.userPermissions.notice")
                }
            }
        }
        .settingsList()
        .overlay {
            switch model.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                VStack(spacing: Spacing.m) {
                    SettingsEmptyState(title: "Couldn't load permissions", message: message, pose: .peek)
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
            case .loaded:
                EmptyView()
            }
        }
        .navigationTitle("User permissions")
        .settingsInlineTitle()
        .alert(
            model.pending.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } }),
            presenting: model.pending
        ) { change in
            Button("Cancel", role: .cancel) { model.cancel() }
            Button("Save") { Task { await model.confirm(change) } }
                .accessibilityIdentifier("settings.userPermissions.confirm")
        } message: { change in
            Text(confirmationMessage(change))
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("settings.userPermissions")
    }

    private func confirmationTitle(_ change: UserPermissionsModel.PendingChange) -> String {
        switch (change.permission, change.newValue) {
        case (.personalConnectors, true): "Allow personal connectors?"
        case (.personalConnectors, false): "Turn off personal connectors?"
        case (_, true): "Allow everyone to create skills?"
        case (_, false): "Stop people creating skills?"
        }
    }

    private func confirmationMessage(_ change: UserPermissionsModel.PendingChange) -> String {
        switch (change.permission, change.newValue) {
        case (.personalConnectors, true):
            "Everyone on \(model.host) will be able to connect their own tool servers. Chats then call those servers from their devices."
        case (.personalConnectors, false):
            "Personal connectors stop working in chats for everyone on \(model.host) who isn't an admin. Their settings are kept."
        case (_, true):
            "Everyone on \(model.host) will be able to write their own skills."
        case (_, false):
            "People on \(model.host) can no longer create skills. Existing skills stay."
        }
    }
}
