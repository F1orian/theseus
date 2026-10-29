import DesignSystem
import OpenWebUIKit
public import SwiftUI
import UniformTypeIdentifiers

/// Settings › Skills (#187): *Yours* to create, edit, enable, delete and import; *From <host>*
/// for Skills others shared. Pick them per Chat in Add to Chat › Skills or with `/`.
public struct SkillsSettingsView: View {
    @State private var model: SkillsModel
    @State private var isAddingURL = false
    @State private var isImportingFile = false
    @State private var confirmingDelete: Skill?

    public init(model: SkillsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            yoursSection
            sharedSection
            if model.permissions.isAdmin {
                Section {
                    NavigationLink(value: SettingsPage.skillsAdministration) {
                        SettingsRowLabel(title: "Every skill on \(model.host)", systemImage: "server.rack")
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("skills.administration")
                } header: {
                    Text("Server administration")
                } footer: {
                    Text("Share skills with everyone or with groups, and see who owns each one.")
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
            if model.permissions.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    SkillAddMenu(
                        canImportFiles: model.permissions.canImportFiles,
                        write: { model.startCreating() },
                        fromURL: { isAddingURL = true },
                        fromFile: { isImportingFile = true }
                    )
                }
            }
        }
        .modifier(SkillSheets(model: model, isAddingURL: $isAddingURL, isImportingFile: $isImportingFile))
        .confirmationDialog(
            "Delete this skill?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { skill in
            Button("Delete \(SkillsModel.displayName(skill))", role: .destructive) {
                Task { await model.delete(skill) }
            }
            .accessibilityIdentifier("skills.delete.confirm")
        } message: { _ in
            Text("Chats that use it won't have it any more. This can't be undone.")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("settings.skills")
    }

    // MARK: Yours

    @ViewBuilder
    private var yoursSection: some View {
        Section {
            if model.showsNoPermission {
                SkillsNoPermissionRow(isAdmin: model.permissions.isAdmin)
            }
            ForEach(model.yours) { skill in
                SkillRow(model: model, skill: skill, showsOwner: false) {
                    Task { await model.open(skill) }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = skill }
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { Task { await model.open(skill) } }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = skill }
                }
                .accessibilityIdentifier("skills.yours.\(skill.id)")
            }
            if model.hasLoaded, model.yours.isEmpty, model.permissions.canCreate {
                Button {
                    model.startCreating()
                } label: {
                    SettingsRowLabel(title: "Write a skill", systemImage: "square.and.pencil", tint: Palette.accent.color)
                }
                .settingsRowBackground()
                .accessibilityIdentifier("skills.yours.empty")
            }
        } header: {
            Text("Yours")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Instructions the model follows when you pick the skill for a chat. Your skills are private unless they're shared.")
                if model.showsUserPermissionsHint {
                    Text("Others on \(model.host) can't create skills. Allow it in Server administration › User permissions.")
                        .accessibilityIdentifier("skills.adminHint")
                }
            }
        }
    }

    // MARK: Shared

    @ViewBuilder
    private var sharedSection: some View {
        Section {
            if model.hasLoaded, model.shared.isEmpty {
                Text("Nothing is shared with you yet.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .settingsRowBackground()
                    .accessibilityIdentifier("skills.shared.empty")
            }
            ForEach(model.shared) { skill in
                SkillRow(model: model, skill: skill, showsOwner: true) {
                    Task { await model.open(skill) }
                }
                .accessibilityIdentifier("skills.shared.\(skill.id)")
            }
        } header: {
            Text("From \(model.host)")
        } footer: {
            Text("Skills others on this Server shared with you. Their owners keep them up to date.")
        }
    }
}

/// "Your Server admin hasn't allowed creating skills", with the admin's way to change it.
struct SkillsNoPermissionRow: View {
    let isAdmin: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: "lock")
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Your Server admin hasn't allowed creating skills")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(isAdmin
                    ? "Allow it for everyone in Server administration › User permissions."
                    : "You can still use the skills shared with you. Ask your Server admin to turn on Skills in the workspace permissions.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .settingsRowBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills.noPermission")
    }
}

/// One Skill: name, description, a plaque with its sharing (and owner), and, when this Account
/// may change it, an on/off switch.
struct SkillRow: View {
    let model: SkillsModel
    let skill: Skill
    let showsOwner: Bool
    var showsToggle = true
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Button(action: open) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Palette.textSecondary.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(ui: SkillsModel.displayName(skill))
                            .font(Typography.body)
                            .foregroundStyle(skill.isActive ? Palette.textPrimary.color : Palette.textSecondary.color)
                        if let description = skill.description {
                            Text(ui: description)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary.color)
                                .lineLimit(2)
                        }
                        SkillPlaque(text: plaque, highlighted: skill.sharing == .onlyOwner && !showsOwner)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(model.canEdit(skill) ? "Edits the skill" : "Shows the skill's instructions")

            if showsToggle, model.canEdit(skill), !showsOwner {
                Toggle(
                    "Enabled",
                    isOn: Binding(get: { skill.isActive }, set: { on in Task { await model.setEnabled(skill, on) } })
                )
                .labelsHidden()
                .accessibilityLabel("\(SkillsModel.displayName(skill)) enabled")
                .accessibilityIdentifier("skills.toggle.\(skill.id)")
            }
        }
        // Keep the open button and the switch separate elements under the row's identifier.
        .accessibilityElement(children: .contain)
        .settingsRowBackground()
    }

    private var plaque: String {
        var parts: [String] = []
        if showsOwner { parts.append("By \(model.ownerName(skill))") }
        parts.append(model.sharingText(skill))
        if !skill.isActive { parts.append("Off") }
        return parts.joined(separator: " · ")
    }
}

/// A small Departure Mono label ("ONLY YOU", "BY ADA · EVERYONE ON …").
struct SkillPlaque: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(ui: text)
            .plaqueStyle(color: highlighted ? Palette.accent : Palette.textTertiary)
            .lineLimit(1)
            .padding(.top, Spacing.xxs)
    }
}

/// The + menu: write a skill, add from a link or from a file.
struct SkillAddMenu: View {
    let canImportFiles: Bool
    let write: () -> Void
    let fromURL: () -> Void
    let fromFile: () -> Void

    var body: some View {
        Menu {
            Button("Write a skill", systemImage: "square.and.pencil", action: write)
                .accessibilityIdentifier("skills.add.write")
            Button("Add from a link", systemImage: "link", action: fromURL)
                .accessibilityIdentifier("skills.add.url")
            Button(canImportFiles ? "Add from a file" : "Add a SKILL.md file", systemImage: "doc.badge.plus", action: fromFile)
                .accessibilityIdentifier("skills.add.file")
        } label: {
            Label("Add skill", systemImage: "plus")
        }
        .tint(Palette.textPrimary.color)
        .accessibilityIdentifier("skills.add")
    }
}

/// The sheets both Skills pages share: the editor, the read-only view, the link prompt, the
/// Files importer and the import review.
struct SkillSheets: ViewModifier {
    @Bindable var model: SkillsModel
    @Binding var isAddingURL: Bool
    @Binding var isImportingFile: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.editor) { _ in
                SkillEditorSheet(model: model)
            }
            .sheet(item: $model.viewing) { detail in
                SkillDetailSheet(model: model, detail: detail)
            }
            .sheet(item: $model.importSession) { _ in
                SkillImportSheet(model: model)
            }
            .sheet(isPresented: $isAddingURL) {
                SkillLinkSheet(model: model)
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: Self.fileTypes(canImport: model.permissions.canImportFiles)
            ) { result in
                guard case .success(let url) = result else { return }
                Task { await importFile(url) }
            }
    }

    static func fileTypes(canImport: Bool) -> [UTType] {
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        guard canImport else { return [markdown, .plainText] }
        let skill = UTType(filenameExtension: "skill") ?? .zip
        return [skill, .zip, markdown, .json, .plainText]
    }

    private func importFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        _ = await model.addFromFile(SkillImportFile(filename: url.lastPathComponent, contentType: type, data: data))
    }
}

#Preview("Skills") {
    NavigationStack {
        SkillsSettingsView(model: SkillsModel(
            client: OpenWebUIClient(server: URL(fileURLWithPath: "/"), transport: URLSessionTransport()),
            host: "chat.example.com"
        ))
    }
}
