import DesignSystem
import OpenWebUIKit
import SwiftUI

/// Project Instructions (PROJ-04): a multiline editor whose text the Server adds to every Chat in
/// the Project (server term: folder system prompt).
struct InstructionsSheet: View {
    let library: ProjectLibrary
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(library: ProjectLibrary, project: Project) {
        self.library = library
        self.project = project
        _draft = State(initialValue: project.instructions)
    }

    private var hasChanges: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != project.instructions
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    MultilineField(
                        placeholder: "Use a friendly tone, keep answers short, you are an expert in astronomy, etc.",
                        text: $draft,
                        minHeight: 180,
                        identifier: "instructions.field"
                    )
                    .focused($isFocused)
                    Text("Tell the model how to behave and respond in every chat in \(project.name).")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(.horizontal, Spacing.l)
                }
                .padding(Spacing.l)
            }
            .themedBackground()
            .sheetChrome(
                title: "Instructions",
                canConfirm: hasChanges && !isSaving,
                confirmIdentifier: "instructions.confirm",
                onClose: { dismiss() },
                onConfirm: save
            )
            .onAppear { isFocused = true }
        }
        .interactiveDismissDisabled(hasChanges)
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await library.updateInstructions(project.id, to: draft)
            isSaving = false
            if saved { dismiss() }
        }
    }
}
