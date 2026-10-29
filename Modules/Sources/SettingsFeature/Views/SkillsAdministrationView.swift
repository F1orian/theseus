import DesignSystem
public import OpenWebUIKit
public import SwiftUI

/// Server administration › Skills (#187, admins only): every Skill on the Server with its owner
/// and sharing. Admins change who a Skill is shared with (everyone, groups, only its owner) and
/// create Skills that are shared from the start. Standalone, so the Server administration section
/// (#186) can push it.
public struct SkillsAdministrationView: View {
    @State private var model: SkillsModel
    @State private var isAddingURL = false
    @State private var isImportingFile = false

    /// - Parameter model: a `SkillsModel` in `.administration` mode.
    public init(model: SkillsModel) {
        _model = State(initialValue: model)
    }

    /// For the Server administration section: builds the model from the Settings sheet's client.
    public init(client: OpenWebUIClient, host: String, user: SessionUser? = nil) {
        self.init(model: SkillsModel(mode: .administration, client: client, host: host, user: user))
    }

    public var body: some View {
        List {
            Section {
                Label {
                    Text("Changes affect everyone on \(model.host)")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textPrimary.color)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(Palette.accent.color)
                }
                .settingsRowBackground()
                .accessibilityIdentifier("adminSkills.header")
            }

            if model.hasLoaded, !model.permissions.isAdmin {
                Section {
                    Text("Only Server admins can manage every skill.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .settingsRowBackground()
                }
            } else {
                Section {
                    if model.hasLoaded, model.all.isEmpty {
                        Text("No skills on this Server yet.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                            .settingsRowBackground()
                    }
                    ForEach(model.all) { skill in
                        HStack(spacing: Spacing.s) {
                            SkillRow(model: model, skill: skill, showsOwner: true, showsToggle: false) {
                                Task { await model.open(skill) }
                            }
                            SkillSharingMenu(model: model, skill: skill)
                        }
                        .settingsRowBackground()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("adminSkills.row.\(skill.id)")
                    }
                } header: {
                    Text("All skills")
                } footer: {
                    Text("Shared skills show up for those people in Settings › Skills and in every chat's skill list. Private skills stay with their owner.")
                }
            }
        }
        .settingsList()
        .overlay {
            if !model.hasLoaded, model.isLoading { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                SettingsErrorBanner(message: message) { model.errorMessage = nil }
            }
        }
        .navigationTitle("Skills")
        .settingsInlineTitle()
        .toolbar {
            if model.permissions.isAdmin {
                ToolbarItem(placement: .primaryAction) {
                    SkillAddMenu(
                        canImportFiles: true,
                        write: { model.startCreating() },
                        fromURL: { isAddingURL = true },
                        fromFile: { isImportingFile = true }
                    )
                    .accessibilityIdentifier("adminSkills.add")
                }
            }
        }
        .modifier(SkillSheets(model: model, isAddingURL: $isAddingURL, isImportingFile: $isImportingFile))
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("settings.serverAdmin.skills")
    }
}

/// The sharing control of one Skill: everyone on the Server, groups, or only its owner.
struct SkillSharingMenu: View {
    let model: SkillsModel
    let skill: Skill

    var body: some View {
        Menu {
            Section("Share with") {
                option("Everyone on \(model.host)", "person.3", selected: skill.sharing == .everyone) {
                    Task { await model.setSharing(skill, .everyone) }
                }
                .accessibilityIdentifier("adminSkills.share.everyone")
                ForEach(model.groups) { group in
                    option(group.name, "person.2", selected: selectedGroups.contains(group.id)) {
                        Task { await model.setSharing(skill, toggled(group.id)) }
                    }
                    .accessibilityIdentifier("adminSkills.share.group.\(group.id)")
                }
                option(skill.isOwned(by: model.user?.id) ? "Only you" : "Only \(model.ownerName(skill))", "lock",
                       selected: skill.sharing == .onlyOwner) {
                    Task { await model.setSharing(skill, .onlyOwner) }
                }
                .accessibilityIdentifier("adminSkills.share.onlyOwner")
            }
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(skill.sharing == .onlyOwner ? Palette.textSecondary.color : Palette.accent.color)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Sharing: \(model.sharingText(skill))")
        .accessibilityHint("Changes who can use \(SkillsModel.displayName(skill))")
        .accessibilityIdentifier("adminSkills.sharing.\(skill.id)")
    }

    private var icon: String {
        switch skill.sharing {
        case .onlyOwner: "lock"
        case .everyone: "person.3.fill"
        case .groups, .people: "person.2.fill"
        }
    }

    private var selectedGroups: [String] {
        if case .groups(let ids) = skill.sharing { ids } else { [] }
    }

    private func toggled(_ id: String) -> SkillSharing {
        var ids = selectedGroups
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        return ids.isEmpty ? .onlyOwner : .groups(ids)
    }

    private func option(_ title: String, _ image: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: image)
            }
        }
    }
}

#Preview("Server administration › Skills") {
    NavigationStack {
        SkillsAdministrationView(
            client: OpenWebUIClient(server: URL(fileURLWithPath: "/"), transport: URLSessionTransport()),
            host: "chat.example.com"
        )
    }
}
