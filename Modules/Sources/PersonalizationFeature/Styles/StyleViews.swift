public import ComposerFeature
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// Plugs Choose style into the Add to Chat sheet (PERS-05). The sheet shows the row when the
/// `instructions` Capability resolves (ADR 0006, 0111).
public enum StylesRegistration {
    @MainActor
    public static func register(in extensions: inout AddToChatExtensions, library: StyleLibrary) {
        extensions.style = { AnyView(StylePickerPage(library: library)) }
        extensions.styleValue = { library.selected.name }
    }
}

/// "Choose style" (PERS-05): the presets with a one-line summary, the user's own Styles, a
/// checkmark on the chosen one, and Create style. Choosing applies to the next Message.
struct StylePickerPage: View {
    let library: StyleLibrary
    @State private var editing: StyleDraft?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Style.presets) { style in row(style) }
            }
            .listRowBackground(Palette.recessedSurface.color)
            Section {
                ForEach(library.customStyles) { style in
                    row(style)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await library.delete(style.id) }
                            }
                            Button("Edit", systemImage: "pencil") { editing = StyleDraft(style) }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = StyleDraft(style) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await library.delete(style.id) }
                            }
                        }
                }
                Button {
                    editing = StyleDraft()
                } label: {
                    Label("Create style", systemImage: "plus")
                        .foregroundStyle(Palette.textPrimary.color)
                }
                .accessibilityIdentifier("styles.create")
            } header: {
                Text("Your styles")
            } footer: {
                if let error = library.errorMessage {
                    Text(error).foregroundStyle(Palette.destructive.color)
                } else {
                    Text("A style adds its instructions to every Chat after your Instructions.")
                }
            }
            .listRowBackground(Palette.recessedSurface.color)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.color)
        .navigationTitle("Choose style")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { draft in
            StyleEditorSheet(library: library, draft: draft)
        }
        .accessibilityIdentifier("styles.page")
    }

    private func row(_ style: Style) -> some View {
        let isSelected = library.selected.id == style.id
        return Button {
            Task { await library.select(style) }
        } label: {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(style.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                    if !style.summary.isEmpty {
                        Text(style.summary)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.s)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.accent.color)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("styles.row.\(style.id)")
    }
}

/// A Style being written or edited.
struct StyleDraft: Identifiable {
    let id = UUID()
    var styleID: String?
    var name = ""
    var instructions = ""

    init() {}

    init(_ style: Style) {
        styleID = style.id
        name = style.name
        instructions = style.instructions
    }
}

/// Create or edit a Style: a name and the instructions the model follows (PERS-05).
struct StyleEditorSheet: View {
    let library: StyleLibrary
    @State var draft: StyleDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusesName: Bool
    @State private var isSaving = false

    init(library: StyleLibrary, draft: StyleDraft) {
        self.library = library
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool { StyleLibrary.canSave(name: draft.name, instructions: draft.instructions) && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Plain English", text: $draft.name)
                        .focused($focusesName)
                        .accessibilityIdentifier("styleEditor.name")
                }
                Section {
                    TextField("How should responses read?", text: $draft.instructions, axis: .vertical)
                        .lineLimit(5...12)
                        .accessibilityIdentifier("styleEditor.instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("For example: “Use short sentences and everyday words. Avoid jargon.”")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.color)
            .navigationTitle(draft.styleID == nil ? "Create style" : "Edit style")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("styleEditor.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        isSaving = true
                        Task {
                            let id = await library.save(id: draft.styleID, name: draft.name, instructions: draft.instructions)
                            // A new Style is the one the user wants next.
                            if draft.styleID == nil, library.errorMessage == nil,
                               let created = library.customStyles.first(where: { $0.id == id }) {
                                await library.select(created)
                            }
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("styleEditor.save")
                }
            }
            .onAppear { focusesName = draft.styleID == nil }
        }
        .presentationDetents([.large])
    }
}

/// The chosen Style under the header on the new-chat home ("✎ Concise"), when it isn't Normal.
public struct StyleChip: View {
    let library: StyleLibrary

    public init(library: StyleLibrary) {
        self.library = library
    }

    public var body: some View {
        let style = library.selected
        if !style.isDefault {
            Label(style.name, systemImage: "pencil.and.scribble")
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(1)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Style: \(style.name)")
                .accessibilityIdentifier("styles.chip")
                .transition(.opacity)
        }
    }
}

#Preview("Choose style") {
    NavigationStack {
        StylePickerPage(library: StyleLibrary(client: OpenWebUIClient(server: URL(fileURLWithPath: "/"), transport: URLSessionTransport())))
    }
}

#Preview("Style chip") {
    StyleChip(library: StyleLibrary(client: OpenWebUIClient(server: URL(fileURLWithPath: "/"), transport: URLSessionTransport())))
        .padding()
}
