import ArtCollection
import DesignSystem
import LibraryFeature
import OpenWebUIKit
public import SwiftUI

/// The Projects screen (PROJ-01): a grid of Projects, each under its cover from The Collection
/// with the work's plaque (BRAND-04), the All / Starred / Archived filter, bottom search, a
/// floating "+ New project" pill (PROJ-02), and the Project detail pushed on tap (PROJ-03).
public struct ProjectsListView: View {
    private let library: ProjectLibrary

    @State private var filter: ProjectsFilter = .all
    @State private var query = ""
    @State private var isSearching = false
    @State private var isCreating = false
    @State private var path: [String] = []
    @State private var changingCover: Project?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(library: ProjectLibrary) {
        self.library = library
    }

    public var body: some View {
        NavigationStack(path: $path) {
            content
                .themedBackground()
                .navigationTitle("Projects")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    // #153: an explicit leading placement. With `.navigation`, popping back from a
                    // deleted Project re-placed the drawer button into the trailing group.
                    ToolbarItem(placement: .leadingBar) { DrawerButton() }
                    ToolbarItem(placement: .primaryAction) { filterMenu }
                }
                .searchable(text: $query, isPresented: $isSearching, prompt: "Search")
                .overlay(alignment: .bottomTrailing) {
                    if !isSearching {
                        ProjectsPill(title: "New project", symbol: "plus", identifier: "projects.new") {
                            isCreating = true
                        }
                        .padding(.trailing, Spacing.l)
                        .padding(.bottom, Spacing.l)
                        .motionSafeTransition(.pop)
                    }
                }
                .motionSafeAnimation(Motion.snappy, value: isSearching)
                .refreshable { await library.refresh() }
                .task { if library.state == .idle { await library.refresh() } }
                .sheet(isPresented: $isCreating) {
                    CreateProjectSheet(library: library) { project in
                        path = [project.id]
                    }
                }
                .sheet(item: $changingCover) { project in
                    ChangeCoverSheet(covers: library.covers, project: project)
                }
                .navigationDestination(for: String.self) { id in
                    ProjectDetailView(library: library, projectID: id)
                }
        }
        // A container element, so the identifier doesn't replace its children's (it would in the
        // iPad sidebar's detail column, PLAT-05).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.screen")
    }

    // MARK: Content

    private var content: some View {
        let rows = library.visibleProjects(filter: filter, query: query)
        return Group { list(rows) }
            // PROJ-01: new, renamed, starred, archived or deleted Projects move into place, and
            // loading or an empty filter cross-fades (ADR 0130).
            .motionSafeAnimation(Motion.smooth, value: rows.map(\.id))
            .motionSafeAnimation(Motion.smooth, value: filter)
            .motionSafeAnimation(Motion.fade, value: rows.isEmpty)
    }

    @ViewBuilder
    private func list(_ rows: [Project]) -> some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xl) {
                    ForEach(rows) { project in
                        NavigationLink(value: project.id) {
                            ProjectCard(project: project, cover: library.covers.cover(for: project.id))
                        }
                        .buttonStyle(.plain)
                        .pointerHighlight()
                        .contextMenu {
                            Button("Change cover", systemImage: "photo.artframe") { changingCover = project }
                        }
                        .accessibilityIdentifier("project.row.\(project.id)")
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.s)
            }
            // Leave room above the floating pill for the last row.
            .contentMargins(.bottom, isSearching ? Spacing.l : 88, for: .scrollContent)
            .accessibilityIdentifier("projects.list")
        }
    }

    /// Two or more covers a row; one at the accessibility sizes, so titles keep their room.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150), spacing: Spacing.l, alignment: .top)]
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ProjectsEmptyState(title: "No matching projects", message: "Try a different word.")
        } else if library.projects.isEmpty, library.state == .loading || library.state == .idle {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = library.state, library.projects.isEmpty {
            ProjectsEmptyState(pose: .peek, title: "Couldn't load projects", message: message)
        } else {
            switch filter {
            case .all:
                // brand.md §4: Lorrain's Rest on the Flight into Egypt and the sleeping mouse.
                ArtworkEmptyState(
                    .projectsEmpty,
                    title: Text("No projects yet"),
                    message: Text("Create one to keep chats, files and instructions about a topic together.")
                )
                .accessibilityIdentifier("projects.empty")
            case .starred:
                ProjectsEmptyState(title: "No starred projects", message: "Star a project to keep it at the top.")
            case .archived:
                ProjectsEmptyState(title: "No archived projects", message: "Archived projects appear here.")
            }
        }
    }

    // MARK: Filter

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(ProjectsFilter.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if filter == .all {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(Palette.textPrimary.color)
                    .accessibilityLabel("Filter: All projects")
            } else {
                Image(systemName: filter == .starred ? "star.fill" : "archivebox.fill")
                    .foregroundStyle(Palette.onAccent.color)
                    .padding(Spacing.s)
                    .background(Palette.accent.color, in: .circle)
                    .accessibilityLabel("Filter: \(filter.title)")
            }
        }
        .accessibilityIdentifier("projects.filter")
    }
}
