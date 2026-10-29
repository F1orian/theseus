import DesignSystem
import OpenWebUIKit
import SwiftUI

/// "Create a project" (PROJ-02): what the user is working on (the name) and what they're trying
/// to achieve (the description, kept in `meta.theseus`), with a round X and a round check.
struct CreateProjectSheet: View {
    let library: ProjectLibrary
    /// Called with the new Project after the Server created it.
    var onCreated: (Project) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    private var canCreate: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    LabelledField(label: "Name") {
                        SingleLineField(placeholder: "Give it a name", text: $name, identifier: "createProject.name")
                            .focused($isNameFocused)
                            .submitLabel(.next)
                    }
                    LabelledField(label: "What's it for?") {
                        MultilineField(
                            placeholder: "The goal, the subject, anything every chat here should know…",
                            text: $description,
                            identifier: "createProject.description"
                        )
                    }
                    if let error = library.errorMessage, !isSaving {
                        Text(error)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.destructive.color)
                            .padding(.horizontal, Spacing.l)
                            .accessibilityIdentifier("createProject.error")
                    }
                }
                .padding(Spacing.l)
            }
            .themedBackground()
            .sheetChrome(
                title: "Create a project",
                canConfirm: canCreate,
                confirmIdentifier: "createProject.confirm",
                onClose: { dismiss() },
                onConfirm: create
            )
            .onAppear {
                library.dismissError()
                isNameFocused = true
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func create() {
        isSaving = true
        library.dismissError()
        Task {
            let project = await library.create(name: name, description: description)
            isSaving = false
            if let project {
                dismiss()
                onCreated(project)
            }
        }
    }
}
