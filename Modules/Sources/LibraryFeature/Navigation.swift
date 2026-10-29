public import ChatDomain
public import SwiftUI

/// Where the Chats library asks the app to go. The app shell maps these onto its own route
/// (`AppFeature.AppRoute`); the library never navigates by itself.
public enum LibraryDestination: Hashable, Sendable {
    /// The new-chat home (CHATS-10). `projectID` starts the Chat inside a Project (server: folder).
    case newChat(projectID: String? = nil)
    case chat(id: String)
    case chatsList
    case projects
    case artifacts
    case settings
}

/// Asks the app shell to show a `LibraryDestination`. Read it with
/// `@Environment(\.libraryNavigate)` and call it like a function.
public struct LibraryNavigateAction: Sendable {
    private let handler: @MainActor @Sendable (LibraryDestination) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (LibraryDestination) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ destination: LibraryDestination) {
        handler(destination)
    }
}

/// Opens or closes the navigation drawer. `DrawerContainer` provides it to its content.
public struct DrawerAction: Sendable {
    private let handler: @MainActor @Sendable (Bool?) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (Bool?) -> Void) {
        self.handler = handler
    }

    @MainActor public func open() { handler(true) }
    @MainActor public func close() { handler(false) }
    @MainActor public func toggle() { handler(nil) }
}

/// Optional Chat menu entries that other Feature areas back: Share (MSG-08) and Add to project
/// (PROJ-06). A `nil` handler hides the entry, as does a missing Capability.
public struct ChatMenuExtras: Sendable {
    public var share: (@MainActor @Sendable (ChatSummary) -> Void)?
    public var addToProject: (@MainActor @Sendable (ChatSummary) -> Void)?
    /// The Chat's sandbox files (OT-04, Open Terminal). Set only when the Account has a sandbox.
    public var files: (@MainActor @Sendable (ChatSummary) -> Void)?

    public init(
        share: (@MainActor @Sendable (ChatSummary) -> Void)? = nil,
        addToProject: (@MainActor @Sendable (ChatSummary) -> Void)? = nil,
        files: (@MainActor @Sendable (ChatSummary) -> Void)? = nil
    ) {
        self.share = share
        self.addToProject = addToProject
        self.files = files
    }
}

extension EnvironmentValues {
    @Entry public var libraryNavigate = LibraryNavigateAction { _ in }
    @Entry public var drawer = DrawerAction { _ in }
    @Entry public var chatMenuExtras = ChatMenuExtras()
}
