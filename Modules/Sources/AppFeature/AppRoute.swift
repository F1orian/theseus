import LibraryFeature

/// What the signed-in shell shows behind the navigation drawer. Feature areas plug their screens
/// into `MainShellView.destination(for:)`; anything can navigate with `MainShellModel.navigate(to:)`
/// (or, from library views, `\.libraryNavigate`).
public enum AppRoute: Hashable, Sendable {
    /// The new-chat home (HOME-01). `projectID` starts the Chat inside a Project (server: folder).
    case newChat(projectID: String? = nil)
    /// A new Incognito chat (INCOG-01): never saved. When the Server enforces Incognito chats
    /// (INCOG-02), `newChat` shows one too.
    case incognitoChat
    /// One Chat (CHAT-*). Until the Chat & streaming epic lands this shows a placeholder.
    case chat(id: String)
    /// The full Chats list (CHATS-02).
    case chatsList
    /// Projects (PROJ-*), only reachable when the `projects` Capability resolves.
    case projects
    /// Artifacts (ART-*).
    case artifacts
    /// Settings (SET-*). Presented as a sheet over the current screen, not as a screen of its own.
    case settings

    init(_ destination: LibraryDestination) {
        switch destination {
        case .newChat(let projectID): self = .newChat(projectID: projectID)
        case .chat(let id): self = .chat(id: id)
        case .chatsList: self = .chatsList
        case .projects: self = .projects
        case .artifacts: self = .artifacts
        case .settings: self = .settings
        }
    }

    /// The drawer row to highlight for this route.
    var drawerSection: DrawerView.Section? {
        switch self {
        case .chatsList: .chats
        case .projects: .projects
        case .artifacts: .artifacts
        case .newChat, .incognitoChat, .chat, .settings: nil
        }
    }

    var chatID: String? {
        if case .chat(let id) = self { id } else { nil }
    }
}
