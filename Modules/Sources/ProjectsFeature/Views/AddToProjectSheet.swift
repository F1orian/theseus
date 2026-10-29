public import ChatDomain
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// "Add to project" (PROJ-06): a picker sheet with search, "+" (create a Project and add the Chat
/// to it) and the Project list. Picking a Project moves the Chat there; the library confirms it
/// with a "Chat moved to …" notice.
public struct AddToProjectSheet: View {
    private let library: ProjectLibrary
    private let chat: ChatSummary
    private let onMoved: @MainActor (ChatSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isCreating = false
    @State private var isMoving = false

    /// - Parameter onMoved: called with the moved Chat (its `projectID` set) after the Server confirmed.
    public init(library: ProjectLibrary, chat: ChatSummary, onMoved: @escaping @MainActor (ChatSummary) -> Void) {
        self.library = library
        self.chat = chat
        self.onMoved = onMoved
    }

    public var body: some View {
        NavigationStack {
            content
                .themedBackground()
                .searchable(text: $query, prompt: "Search")
                .navigationTitle("Add to project")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("addToProject.close")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isCreating = true
                        } label: {
                            Image(systemName: "plus").accessibilityLabel("New project")
                        }
                        .accessibilityIdentifier("addToProject.new")
                    }
                }
                .task { if library.state == .idle { await library.refresh() } }
                .sheet(isPresented: $isCreating) {
                    CreateProjectSheet(library: library) { project in
                        move(to: project.id)
                    }
                }
                .disabled(isMoving)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("addToProject.sheet")
    }

    @ViewBuilder
    private var content: some View {
        let projects = library.visibleProjects(filter: .all, query: query)
        if projects.isEmpty {
            if library.state == .loading && library.projects.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ProjectsEmptyState(
                    title: "No projects yet",
                    message: "Create a project first, then add chats to it."
                )
            } else {
                ProjectsEmptyState(title: "No matching projects", message: "Try a different word.")
            }
        } else {
            List(projects) { project in
                Button {
                    move(to: project.id)
                } label: {
                    TitleTimeRow(
                        title: project.name,
                        date: project.updatedAt,
                        isStarred: project.isStarred,
                        showsChevron: false,
                        isSelected: project.id == chat.projectID
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("addToProject.row.\(project.id)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func move(to projectID: String) {
        guard projectID != chat.projectID else {
            dismiss()
            return
        }
        isMoving = true
        Task {
            let moved = await library.moveChat(chat, to: projectID)
            isMoving = false
            if let moved {
                onMoved(moved)
                dismiss()
            }
        }
    }
}
