import ChatDomain
import DesignSystem
import LibraryFeature
import OpenWebUIKit
import SwiftUI

/// One Project (PROJ-03): back, title, star (PROJ-07) and the `...` menu (PROJ-08) in the header;
/// the cover as a short hero (BRAND-04); an info card with the description, the Instructions summary and "Archived"; "Add files"
/// (PROJ-05) and "Instructions" (PROJ-04) buttons; the Project's Chats; and a "+ New chat" pill
/// that starts a Chat inside the Project.
struct ProjectDetailView: View {
    let library: ProjectLibrary
    let projectID: String

    @Environment(\.libraryNavigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingInstructions = false
    @State private var isShowingFiles = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isConfirmingDelete = false
    @State private var isChangingCover = false
    /// The Project being deleted. Its screen stays as it was (title, toolbar) until the pop back
    /// to the list has finished; swapping in "Project not found" mid-pop left the list's toolbar
    /// without its drawer button (#153).
    @State private var departing: Project?

    var body: some View {
        Group {
            if let project = library.project(id: projectID) ?? departing {
                content(project)
            } else {
                ProjectsEmptyState(title: "Project not found", message: "It may have been deleted.")
            }
        }
        .themedBackground()
        .navigationBarTitleDisplayModeInline()
        .task {
            async let details: Void = library.loadDetails(projectID)
            async let chats: Void = library.loadChats(in: projectID)
            _ = await (details, chats)
        }
        .refreshable {
            async let details: Void = library.loadDetails(projectID)
            async let chats: Void = library.loadChats(in: projectID)
            _ = await (details, chats)
        }
        // A container, so the identifier doesn't replace its children's (the New chat pill's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.detail")
    }

    // MARK: Content

    private func content(_ project: Project) -> some View {
        List {
            ProjectCoverHero(cover: library.covers.cover(for: project.id))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Group {
                header(project)
                chatRows(project)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                starButton(project)
                menu(project)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            NewChatPill(projectID: project.id, identifier: "project.newChat")
                .padding(.trailing, Spacing.l)
                .padding(.bottom, Spacing.l)
        }
        .sheet(isPresented: $isEditingInstructions) {
            InstructionsSheet(library: library, project: project)
        }
        .sheet(isPresented: $isChangingCover) {
            ChangeCoverSheet(covers: library.covers, project: project)
        }
        .sheet(isPresented: $isShowingFiles) {
            ProjectFilesSheet(library: library, projectID: project.id)
        }
        .alert("Rename project", isPresented: $isRenaming) {
            TextField("Project name", text: $renameDraft)
                .accessibilityIdentifier("project.rename.field")
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let name = renameDraft
                Task { await library.rename(project.id, to: name) }
            }
            .accessibilityIdentifier("project.rename.ok")
        } message: {
            Text("Enter a new name")
        }
    }

    @ViewBuilder
    private func header(_ project: Project) -> some View {
        VStack(spacing: Spacing.m) {
            infoCard(project)
            HStack(spacing: Spacing.m) {
                outlinedButton(
                    project.knowledge.isEmpty ? "Add files" : project.knowledge.count == 1 ? "1 file" : "\(project.knowledge.count) files",
                    symbol: project.knowledge.isEmpty ? nil : "doc.on.doc",
                    identifier: "project.files"
                ) { isShowingFiles = true }
                outlinedButton("Instructions", symbol: nil, identifier: "project.instructions") {
                    isEditingInstructions = true
                }
            }
        }
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    private func infoCard(_ project: Project) -> some View {
        let description = project.metadata.description
        let instructions = project.instructions
        if !description.isEmpty || !instructions.isEmpty || project.isArchived {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if !description.isEmpty {
                    infoRow(description, symbol: "info.circle", identifier: "project.description")
                }
                if !instructions.isEmpty {
                    infoRow(instructions, symbol: "text.alignleft", identifier: "project.instructionsSummary")
                        .onTapGesture { isEditingInstructions = true }
                }
                if project.isArchived {
                    infoRow("Archived", symbol: "archivebox", identifier: "project.archived")
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large, style: .continuous))
        }
    }

    private func infoRow(_ text: String, symbol: String, identifier: String) -> some View {
        Label {
            Text(text)
                .lineLimit(2)
        } icon: {
            Image(systemName: symbol)
        }
        .font(Typography.body)
        .foregroundStyle(Palette.textSecondary.color)
        .accessibilityIdentifier(identifier)
    }

    private func outlinedButton(_ title: String, symbol: String?, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(Typography.headline)
            .foregroundStyle(Palette.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(Capsule().stroke(Palette.separator.color, lineWidth: 1.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Chats

    @ViewBuilder
    private func chatRows(_ project: Project) -> some View {
        let page = library.chatPage(for: project.id)
        if page.chats.isEmpty {
            if page.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.xl)
            } else {
                ProjectsEmptyState(
                    title: "This project is quiet.",
                    message: "Chats you start here stay together here."
                )
                .padding(.top, Spacing.xxl)
            }
        } else {
            ForEach(page.chats) { chat in
                Button {
                    navigate(.chat(id: chat.id))
                } label: {
                    TitleTimeRow(title: chat.title, date: chat.updatedAt)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        Task { await library.moveChat(chat, to: nil) }
                    } label: {
                        Label("Remove from project", systemImage: "folder.badge.minus")
                    }
                }
                .accessibilityIdentifier("project.chat.\(chat.id)")
                .onAppear {
                    if chat.id == page.chats.last?.id {
                        Task { await library.loadMoreChats(in: project.id) }
                    }
                }
            }
            if page.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Header actions

    private func starButton(_ project: Project) -> some View {
        Button {
            Task { await library.setStarred(project.id, !project.isStarred) }
        } label: {
            Image(systemName: project.isStarred ? "star.fill" : "star")
                .foregroundStyle(project.isStarred ? Palette.accent.color : Palette.textPrimary.color)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(project.isStarred ? "Unstar project" : "Star project")
        }
        .disabled(!project.hasDetails)
        .accessibilityIdentifier("project.star")
    }

    private func menu(_ project: Project) -> some View {
        Menu {
            Button {
                renameDraft = project.name
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .accessibilityIdentifier("project.menu.rename")
            // BRAND-04: a cover from The Collection, kept on this device.
            Button {
                isChangingCover = true
            } label: {
                Label("Change cover", systemImage: "photo.artframe")
            }
            .accessibilityIdentifier("project.menu.changeCover")
            Divider()
            Button {
                Task { await library.setArchived(project.id, !project.isArchived) }
            } label: {
                Label(project.isArchived ? "Unarchive" : "Archive", systemImage: project.isArchived ? "archivebox.fill" : "archivebox")
            }
            .disabled(!project.hasDetails)
            .accessibilityIdentifier("project.menu.archive")
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("project.menu.delete")
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityLabel("Project options")
        }
        .accessibilityIdentifier("project.menu")
        // #154: on the menu button itself, so the confirmation is anchored to the `...` that
        // opened it (a popover pointing at it on iPhone and iPad), like the Chat menu's.
        .confirmationDialog(
            "Delete “\(project.name)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            if library.canDeleteChats {
                Button("Delete project and its chats", role: .destructive) { delete(project, chats: true) }
                    .accessibilityIdentifier("project.delete.withChats")
            }
            Button("Delete project, keep chats", role: .destructive) { delete(project, chats: false) }
                .accessibilityIdentifier("project.delete.keepChats")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kept chats move back to your chat list. This can't be undone.")
        }
    }

    private func delete(_ project: Project, chats: Bool) {
        departing = project
        Task {
            if await library.delete(project.id, deleteChats: chats) {
                dismiss()
            } else {
                departing = nil
            }
        }
    }
}
