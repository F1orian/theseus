import ArtCollection
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The Memory summary's type: New York for titles (brand.md §2), SF Pro for the entries.
private enum MemoryType {
    static let sectionTitle = Font.system(.title3, design: .serif).weight(.semibold)
    static let prose = Typography.body
}

// MARK: Memory settings (PERS-03)

/// The Memory section of the Capabilities page (PERS-03): the "Remember things from my chats"
/// switch and "View your memory", which opens the Memory summary sheet (PERS-04).
public struct MemorySettingsSection: View {
    @State private var model: MemorySettingsModel
    @State private var isShowingSummary = false

    public init(model: MemorySettingsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } })) {
                Text("Remember things from my chats")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
            }
            .hapticFeedback(.selection, trigger: model.isOn)
            .cardRowBackground()
            .accessibilityIdentifier("memory.toggle")
            .task { await model.load() }

            Button {
                isShowingSummary = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("View your memory")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary.color)
                        Text(model.summary.updatedText() ?? "Nothing remembered yet")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary.color)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .cardRowBackground()
            .accessibilityIdentifier("memory.view")
            .sheet(isPresented: $isShowingSummary) {
                MemorySummarySheet(model: model.summary)
            }
        } header: {
            Text("Memory")
        } footer: {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.destructive.color)
            } else {
                Text("Models use what this Server remembers about you and add to it as you chat. Turning this off keeps what's already remembered.")
            }
        }
    }
}

/// A Memory settings page for entry points outside the Capabilities page.
public struct MemorySettingsPage: View {
    private let model: MemorySettingsModel

    public init(model: MemorySettingsModel) {
        self.model = model
    }

    public var body: some View {
        List {
            MemorySettingsSection(model: model)
        }
        .groupedCardList()
        .inlineNavigationTitle("Memory")
        .accessibilityIdentifier("personalization.memory")
    }
}

// MARK: Memory summary (PERS-04)

/// The Memory summary sheet (PERS-04): a header with the reading mouse ("What Theseus remembers",
/// BRAND-04) and an "Updated … ago" line, then Memory entries as cards with an `ADDED 12 OCT`
/// plaque, in sections by topic. The floating pencil switches to editing: add, edit, delete and
/// forget all. Empty, it shows Dürer's *St. Jerome in his Study*.
public struct MemorySummarySheet: View {
    @Bindable var model: MemorySummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorTarget: MemoryEditorTarget?
    @State private var isConfirmingForgetAll = false

    public init(model: MemorySummaryModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    if !model.entries.isEmpty {
                        MemoryHeader(serverName: model.serverName, updated: model.updatedText())
                    }
                    if model.isEditing {
                        addButton
                    }
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                    if model.isEditing, !model.entries.isEmpty {
                        forgetAllButton
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.s)
                .padding(.bottom, 96)
                .animation(.default, value: model.isEditing)
                .animation(.default, value: model.entries)
            }
            .accessibilityIdentifier("memory.summary")
            .themedBackground()
            .overlay { placeholder }
            .overlay(alignment: .bottomTrailing) { editButton }
            .errorBanner(model.errorMessage) { model.dismissError() }
            .inlineNavigationTitle("Memory summary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("memory.close")
                }
            }
            .sheet(item: $editorTarget) { target in
                MemoryEditorSheet(target: target, model: model)
            }
        }
        .task {
            if !model.isLoaded { await model.load() }
        }
    }

    private func sectionView(_ section: MemorySection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(section.title)
                .font(MemoryType.sectionTitle)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(section.entries) { entry in
                MemoryEntryRow(
                    entry: entry,
                    isEditing: model.isEditing,
                    edit: { editorTarget = .entry(entry) },
                    delete: { Task { await model.delete(entry) } }
                )
            }
        }
    }

    private var addButton: some View {
        Button {
            editorTarget = .new
        } label: {
            Label("Add memory", systemImage: "plus.circle.fill")
                .font(Typography.headline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textPrimary.color)
        .accessibilityIdentifier("memory.add")
    }

    private var forgetAllButton: some View {
        Button(role: .destructive) {
            isConfirmingForgetAll = true
        } label: {
            Label("Forget all memory", systemImage: "trash")
                .font(Typography.body)
                .foregroundStyle(Palette.destructive.color)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.surface.color, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memory.forgetAll")
        .confirmationDialog("Forget all memory?", isPresented: $isConfirmingForgetAll, titleVisibility: .visible) {
            Button("Forget all memory", role: .destructive) {
                Task { await model.forgetAll() }
            }
            .accessibilityIdentifier("memory.forgetAll.confirm")
        } message: {
            Text("Everything this Server remembers about you is deleted, for Theseus and the web app. This can't be undone.")
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.entries.isEmpty {
            if model.isLoading, !model.isLoaded {
                ProgressView()
            } else if model.isLoaded {
                MemoryEmptyState { editorTarget = .new }
            }
        }
    }

    @ViewBuilder
    private var editButton: some View {
        if !model.entries.isEmpty {
            Button {
                model.isEditing.toggle()
            } label: {
                Image(systemName: model.isEditing ? "checkmark" : "pencil")
                    .font(.title3)
                    .frame(width: 56, height: 56)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(Palette.textPrimary.color)
            .padding(Spacing.xl)
            .accessibilityLabel(model.isEditing ? "Done editing" : "Edit memory")
            .accessibilityIdentifier("memory.edit")
        }
    }
}

/// One Memory entry as a card with its `ADDED 12 OCT` plaque. While editing it gets a delete button
/// and opens the editor on tap; otherwise a long press offers Edit and Delete.
private struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let isEditing: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if isEditing {
                Button(action: delete) {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.destructive.color)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("memory.entry.delete")
                .motionSafeTransition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(entry.content)
                    .font(MemoryType.prose)
                    .lineSpacing(2)
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(MemorySummaryModel.addedText(entry.createdAt)).plaqueStyle()
            }
            if isEditing {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary.color)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Palette.separator.color, lineWidth: 1)
        }
        .contentShape(.rect)
        .onTapGesture {
            if isEditing { edit() }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: edit)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

/// No Memory yet: Dürer's *St. Jerome in his Study* and the reading mouse (brand.md §4).
private struct MemoryEmptyState: View {
    let add: () -> Void

    var body: some View {
        ArtworkEmptyState(
            .memory,
            pose: .read,
            title: Text("Nothing remembered yet"),
            message: Text("Add facts you want models to know about you, or keep chatting with memory on.")
        ) {
            Button("Add memory", systemImage: "plus", action: add)
                .buttonStyle(.glass)
                .accessibilityIdentifier("memory.empty.add")
        }
    }
}

/// The top of a non-empty Memory summary: the reading mouse, "What Theseus remembers" in New York,
/// where it's kept and when it last changed.
private struct MemoryHeader: View {
    let serverName: String
    let updated: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PixelMouse(pose: .read, scale: 3)
                .mouseBackdrop()
                .padding(.bottom, Spacing.xs)
            Text("What Theseus remembers")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Text(ui: "Saved on \(serverName). Edit or forget anything.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            if let updated {
                Text(updated)
                    .plaqueStyle()
                    .accessibilityIdentifier("memory.updated")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Editor

enum MemoryEditorTarget: Identifiable, Hashable {
    case new
    case entry(MemoryEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .entry(let entry): entry.id
        }
    }
}

/// Adds or edits one Memory entry: what to remember and an optional topic (`path`).
private struct MemoryEditorSheet: View {
    let target: MemoryEditorTarget
    let model: MemorySummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var topic: String
    @FocusState private var isContentFocused: Bool

    init(target: MemoryEditorTarget, model: MemorySummaryModel) {
        self.target = target
        self.model = model
        switch target {
        case .new:
            _content = State(initialValue: "")
            _topic = State(initialValue: "")
        case .entry(let entry):
            _content = State(initialValue: entry.content)
            _topic = State(initialValue: entry.path ?? "")
        }
    }

    private var original: (content: String, topic: String) {
        switch target {
        case .new: ("", "")
        case .entry(let entry): (entry.content, entry.path ?? "")
        }
    }

    private var hasChanges: Bool {
        !content.trimmed.isEmpty && (content.trimmed != original.content || topic.trimmed != original.topic)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Memory", text: $content, prompt: Text("Something to remember about you"), axis: .vertical)
                        .lineLimit(3...10)
                        .font(MemoryType.prose)
                        .focused($isContentFocused)
                        .cardRowBackground()
                        .accessibilityIdentifier("memory.editor.content")
                }
                Section {
                    TextField("Topic", text: $topic, prompt: Text("Optional, for example work/projects"))
                        .autocorrectionDisabled()
                        .cardRowBackground()
                        .accessibilityIdentifier("memory.editor.topic")
                } footer: {
                    Text("Topics group your memory. Use / for subtopics.")
                }
            }
            .groupedCardList()
            .inlineNavigationTitle(target == .new ? "Add memory" : "Edit memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(hasChanges: hasChanges, isSaving: model.isWorking) {
                        Task { await save() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { isContentFocused = true }
    }

    private func save() async {
        switch target {
        case .new: await model.add(content: content, path: topic)
        case .entry(let entry): await model.update(entry, content: content, path: topic)
        }
        if model.errorMessage == nil { dismiss() }
    }
}
