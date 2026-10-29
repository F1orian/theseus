/// Whether an Account may start Incognito chats (server term: temporary chats), and whether the
/// Server makes every Chat one (INCOG-02, ADR 0070).
///
/// - `chat.temporary` grants Incognito chats.
/// - `chat.temporary_enforced` (only together with `chat.temporary`) makes every new Chat
///   Incognito: the Server refuses to save Chats, so the app hides the history UI.
/// - Admins bypass both, like the Server and the web client: they may always choose and are never
///   forced. Pending Accounts get nothing.
public enum IncognitoPolicy: Sendable, Equatable {
    /// No Incognito chats: the ghost button is hidden.
    case unavailable
    /// The user can switch a new Chat to Incognito from the home's ghost button.
    case available
    /// Every new Chat is Incognito and nothing is saved; history and Projects are hidden.
    case enforced

    public init(user: SessionUser) {
        switch user.role {
        case .admin:
            self = .available
        case .pending:
            self = .unavailable
        case .user, .other:
            guard user.permissions.allows("chat.temporary") else {
                self = .unavailable
                return
            }
            self = user.permissions.allows("chat.temporary_enforced") ? .enforced : .available
        }
    }

    /// Whether new Chats can be saved (and so listed, starred or filed in Projects).
    public var savesChats: Bool { self != .enforced }
}
