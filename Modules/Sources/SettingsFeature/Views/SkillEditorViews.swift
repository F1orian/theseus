import DesignSystem
import OpenWebUIKit
import SwiftUI

// The Skill sheets (#187): create/edit with a Markdown editor, read a shared Skill, add from a
// link, and review an import.

/// Create or edit a Skill: name, description, and the `SKILL.md` instructions in a Markdown
/// editor (write / preview, with a formatting bar). In administration a new Skill also picks
/// who it's shared with.
struct SkillEditorSheet: View {
    @Bindable var model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var isPreviewing = false
    @State private var selection: TextSelection?
    @State private var isConfirmingDelete = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, description, content }

    var body: some View {
        NavigationStack {
            if let draft = model.editor {
                form(draft)
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }

    private func form(_ draft: SkillEditorDraft) -> some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name), prompt: Text("Meeting notes"))
                    .font(Typography.body)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .description }
                    .accessibilityIdentifier("skillEditor.name")
                TextField("Description", text: binding(\.description), prompt: Text("When the model should use it"), axis: .vertical)
                    .font(Typography.body)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .description)
                    .accessibilityIdentifier("skillEditor.description")
            } header: {
                Text("Skill")
            } footer: {
                Text("The description tells the model when the skill fits, so it can pick it on its own.")
            }
            .listRowBackground(Palette.surface.color)

            Section {
                Picker("Mode", selection: $isPreviewing) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("skillEditor.mode")

                if isPreviewing {
                    SkillMarkdownPreview(markdown: draft.content)
                        .listRowBackground(Palette.surface.color)
                } else {
                    TextEditor(text: binding(\.content), selection: $selection)
                        .font(Typography.code)
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .content)
                        .overlay(alignment: .topLeading) {
                            if draft.content.isEmpty {
                                Text("# Steps\n\n1. Read the notes.\n2. List decisions and owners.")
                                    .font(Typography.code)
                                    .foregroundStyle(Palette.textTertiary.color)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .listRowBackground(Palette.surface.color)
                        .accessibilityLabel("Instructions")
                        .accessibilityIdentifier("skillEditor.content")
                }
            } header: {
                HStack {
                    Text("Instructions")
                    Spacer()
                    Text(ui: "SKILL.md · Markdown").plaqueStyle()
                }
            }

            if model.mode == .administration, draft.isNew {
                SkillSharingSection(model: model, sharing: binding(\.sharing))
            }

            if !draft.isNew {
                Section {
                    Toggle("Enabled", isOn: binding(\.isActive))
                        .accessibilityIdentifier("skillEditor.enabled")
                    Button("Delete skill", role: .destructive) { isConfirmingDelete = true }
                        .accessibilityIdentifier("skillEditor.delete")
                } footer: {
                    Text("A skill that's off isn't offered in chats.")
                }
                .listRowBackground(Palette.surface.color)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .themedBackground()
        .navigationTitle(draft.isNew ? "New skill" : "Edit skill")
        .settingsInlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.editor = nil }
                    .tint(Palette.textPrimary.color)
                    .accessibilityIdentifier("skillEditor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.isNew ? "Add" : "Save") {
                    Task { await model.saveEditor() }
                }
                .disabled(!draft.canSave || model.isWorking)
                .accessibilityIdentifier("skillEditor.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField == .content {
                    MarkdownFormatBar(insert: { prefix, suffix in insert(prefix, suffix) }, done: { focusedField = nil })
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                SettingsErrorBanner(message: message) { model.errorMessage = nil }
            }
        }
        .confirmationDialog("Delete this skill?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let id = draft.existingID, let skill = model.skills.first(where: { $0.id == id }) else { return }
                model.editor = nil
                Task { await model.delete(skill) }
            }
            .accessibilityIdentifier("skillEditor.delete.confirm")
        } message: {
            Text("Chats that use it won't have it any more. This can't be undone.")
        }
        .onAppear { if draft.isNew, draft.name.isEmpty { focusedField = .name } }
        .accessibilityIdentifier("skillEditor")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SkillEditorDraft, Value>) -> Binding<Value> {
        Binding(
            get: { model.editor?[keyPath: keyPath] ?? SkillEditorDraft()[keyPath: keyPath] },
            set: { model.editor?[keyPath: keyPath] = $0 }
        )
    }

    /// Wraps the selection in `prefix`/`suffix` (or inserts them at the cursor; at the end
    /// without a cursor).
    private func insert(_ prefix: String, _ suffix: String) {
        guard var text = model.editor?.content else { return }
        if case .selection(let range) = selection?.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            let selected = String(text[range])
            text.replaceSubrange(range, with: prefix + selected + suffix)
            let cursor = text.index(range.lowerBound, offsetBy: prefix.count + selected.count)
            model.editor?.content = text
            selection = TextSelection(insertionPoint: cursor)
        } else {
            let needsBreak = !text.isEmpty && !text.hasSuffix("\n") && prefix.hasPrefix("#")
            text += (needsBreak ? "\n" : "") + prefix + suffix
            model.editor?.content = text
        }
    }
}

/// Heading, bold, italic, list, checklist, code: the Markdown a Skill usually needs.
private struct MarkdownFormatBar: View {
    let insert: (_ prefix: String, _ suffix: String) -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: Spacing.l) {
            button("Heading", "number") { insert("## ", "") }
            button("Bold", "bold") { insert("**", "**") }
            button("Italic", "italic") { insert("_", "_") }
            button("List", "list.bullet") { insert("- ", "") }
            button("Numbered list", "list.number") { insert("1. ", "") }
            button("Code", "chevron.left.forwardslash.chevron.right") { insert("`", "`") }
            Spacer()
            button("Hide keyboard", "keyboard.chevron.compact.down", action: done)
        }
        .tint(Palette.textPrimary.color)
    }

    private func button(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: image, action: action)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("skillEditor.format.\(image)")
    }
}

/// A light Markdown preview: inline styles, with headings and lists kept on their lines.
struct SkillMarkdownPreview: View {
    let markdown: String

    var body: some View {
        Group {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing to preview yet.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary.color)
            } else {
                Text(Self.attributed(markdown))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(.vertical, Spacing.xs)
        .accessibilityIdentifier("skillEditor.preview")
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// Who a new Skill is shared with (administration): everyone, some groups, or only you.
struct SkillSharingSection: View {
    let model: SkillsModel
    @Binding var sharing: SkillSharing

    var body: some View {
        Section {
            choice("Everyone on \(model.host)", systemImage: "person.3", selected: sharing == .everyone) { sharing = .everyone }
                .accessibilityIdentifier("skillEditor.sharing.everyone")
            ForEach(model.groups) { group in
                choice(group.name, systemImage: "person.2", selected: selectedGroups.contains(group.id)) {
                    toggle(group.id)
                }
                .accessibilityIdentifier("skillEditor.sharing.group.\(group.id)")
            }
            choice("Only you", systemImage: "lock", selected: sharing == .onlyOwner) { sharing = .onlyOwner }
                .accessibilityIdentifier("skillEditor.sharing.onlyOwner")
        } header: {
            Text("Share with")
        } footer: {
            Text("Everyone you share it with can pick it in their chats. Only you and other admins can change it.")
        }
        .listRowBackground(Palette.surface.color)
    }

    private var selectedGroups: [String] {
        if case .groups(let ids) = sharing { ids } else { [] }
    }

    private func toggle(_ id: String) {
        var ids = selectedGroups
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        sharing = ids.isEmpty ? .onlyOwner : .groups(ids)
    }

    private func choice(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                SettingsRowLabel(title: title, systemImage: systemImage)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent.color)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A shared Skill, read-only: who made it, who it's shared with, and its instructions.
struct SkillDetailSheet: View {
    let model: SkillsModel
    let detail: SkillDetail

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(ui: SkillsModel.displayName(detail.skill))
                            .font(Typography.title)
                            .foregroundStyle(Palette.textPrimary.color)
                        SkillPlaque(text: "By \(model.ownerName(detail.skill)) · \(model.sharingText(detail.skill))")
                        if let description = detail.skill.description {
                            Text(ui: description)
                                .font(Typography.callout)
                                .foregroundStyle(Palette.textSecondary.color)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .listRowBackground(Palette.surface.color)
                Section {
                    Text(detail.content)
                        .font(Typography.code)
                        .foregroundStyle(Palette.textPrimary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    HStack {
                        Text("Instructions")
                        Spacer()
                        Text(ui: "SKILL.md").plaqueStyle()
                    }
                } footer: {
                    Text("Only its owner and Server admins can change this skill.")
                }
                .listRowBackground(Palette.surface.color)
            }
            .settingsList()
            .navigationTitle("Skill")
            .settingsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.viewing = nil }
                        .accessibilityIdentifier("skillDetail.done")
                }
            }
        }
        .accessibilityIdentifier("skillDetail")
    }
}

/// Add a Skill from a link: a `SKILL.md`, a `.skill` or `.zip` download, or (admins) a GitHub
/// repository or folder.
struct SkillLinkSheet: View {
    let model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isAdding = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link", text: $link, prompt: Text(verbatim: "https://github.com/…/SKILL.md"))
                        .linkFieldStyle()
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit { add() }
                        .accessibilityIdentifier("skillLink.field")
                } footer: {
                    Text(model.permissions.canLoadFromURLOnServer
                        ? "A link to a SKILL.md file, a .skill or .zip download, or a GitHub repository or folder. You'll review the skills before they're added."
                        : "A link to a SKILL.md file or a .skill or .zip download. Theseus downloads it on this device, and you review it before it's added.")
                }
                .listRowBackground(Palette.surface.color)
                if let message = model.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textPrimary.color)
                            .accessibilityIdentifier("skillLink.error")
                    }
                    .listRowBackground(Palette.surface.color)
                }
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Add from a link")
            .settingsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("skillLink.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add") { add() }
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("skillLink.add")
                    }
                }
            }
            .onAppear {
                model.errorMessage = nil
                isFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("skillLink")
    }

    private func add() {
        guard !isAdding else { return }
        isAdding = true
        Task {
            let added = await model.addFromURL(link)
            isAdding = false
            if added { dismiss() }
        }
    }
}

/// Review an import: each Skill found, and whether to add it, add a copy, replace the existing
/// one or skip it.
struct SkillImportSheet: View {
    @Bindable var model: SkillsModel

    var body: some View {
        NavigationStack {
            if let session = model.importSession {
                List {
                    Section {
                        ForEach(Array(session.items.enumerated()), id: \.offset) { index, item in
                            row(session: session, index: index, item: item)
                        }
                    } header: {
                        Text("From \(session.source)")
                    } footer: {
                        Text(model.mode == .administration
                            ? "Imported skills start out private to you. Share them from the list."
                            : "Imported skills are private to you.")
                    }
                    .listRowBackground(Palette.surface.color)
                }
                .settingsList()
                .navigationTitle(session.items.count == 1 ? "Add skill" : "Add \(session.items.count) skills")
                .settingsInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.importSession = nil }
                            .tint(Palette.textPrimary.color)
                            .accessibilityIdentifier("skillImport.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { Task { await model.confirmImport() } }
                            .disabled(session.selectedCount == 0 || model.isWorking)
                            .accessibilityIdentifier("skillImport.confirm")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let message = model.errorMessage {
                        SettingsErrorBanner(message: message) { model.errorMessage = nil }
                    }
                }
            }
        }
        .accessibilityIdentifier("skillImport")
    }

    private func row(session: SkillImportSession, index: Int, item: SkillImportPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(ui: SkillMarkdown.displayName(session.decisions[index].name))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Spacer()
                Picker("Action", selection: Binding(
                    get: { session.decisions[index].action },
                    set: { model.importSession?.choose($0, for: index) }
                )) {
                    ForEach(session.actions(for: index), id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("skillImport.action.\(index)")
            }
            if let description = item.description {
                Text(ui: description)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                    .lineLimit(3)
            }
            SkillPlaque(text: plaque(item, result: session.results?[safe: index]))
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skillImport.item.\(index)")
    }

    private func plaque(_ item: SkillImportPreview, result: SkillImportResult?) -> String {
        if let result {
            switch result.status {
            case .saved: return "Added"
            case .skipped: return "Skipped"
            case .error: return result.error ?? "Couldn't add"
            }
        }
        var parts = [item.fileCount == 1 ? "1 file" : "\(item.fileCount) files"]
        if item.isTaken { parts.append(item.canReplace ? "You have one with this name" : "Name already taken") }
        return parts.joined(separator: " · ")
    }
}

extension SkillImportDecision.Action {
    var title: String {
        switch self {
        case .create: "Add"
        case .copy: "Add a copy"
        case .replace: "Replace"
        case .skip: "Skip"
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {
    /// A field for a web address: URL keyboard, no capitals or corrections.
    fileprivate func linkFieldStyle() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}
