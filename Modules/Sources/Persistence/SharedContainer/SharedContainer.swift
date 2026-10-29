public import Foundation

/// The App Group the app shares with its extensions (widgets, Share extension; ADR 0100). It holds
/// only what extensions need: a `SharedSnapshot` of the active Account and the `ShareInbox`.
/// Credentials and the per-Account databases stay in the app's own sandbox.
public struct SharedContainer: Sendable {
    /// The App Group identifier in every target's entitlements.
    public static let appGroupID = "group.dev.unrush.theseus"

    /// The container's root folder.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The App Group container, or `nil` when the binary lacks the entitlement (e.g. an unsigned
    /// build); then extensions simply have nothing to show.
    public static func appGroup() -> SharedContainer? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map { SharedContainer(directory: $0.appending(path: "Theseus", directoryHint: .isDirectory)) }
    }

    /// A throwaway container for tests and previews.
    public static func temporary() -> SharedContainer {
        SharedContainer(directory: FileManager.default.temporaryDirectory
            .appending(path: "theseus-shared-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    var snapshotURL: URL { directory.appending(path: "snapshot.json") }
    var inboxDirectory: URL { directory.appending(path: "Inbox", directoryHint: .isDirectory) }
}
