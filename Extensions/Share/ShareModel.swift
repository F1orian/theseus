import AppIntentsFeature
import Foundation
import Observation
import Persistence

/// The Share extension's state (PLAT-04): load what was shared, let the user add a message, then
/// leave it in the App Group's `ShareInbox` and open Theseus on a new Chat holding it (ADR 0100).
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// Nothing Theseus can take (e.g. a contact card).
        case unsupported
        case tooLarge
        /// No Account on this device yet.
        case signedOut
        /// Sharing to Theseus is part of Theseus Pro (ADR 0173).
        case needsPro
        /// Stored, but Theseus couldn't be opened from here: it opens the next time it's active.
        case saved
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var contents: [SharedContent] = []
    var note = ""
    /// The active Account, from the app's snapshot.
    let snapshot: SharedSnapshot?

    private let inbox: ShareInbox?
    /// Opens a `theseus://` URL in the app; returns whether it worked.
    var openApp: (URL) async -> Bool = { _ in false }
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    init(snapshot: SharedSnapshot?, inbox: ShareInbox?) {
        self.snapshot = snapshot
        self.inbox = inbox
    }

    /// The extension running in an app that shares Theseus's App Group.
    static func live() -> ShareModel {
        ShareModel(snapshot: SharedSnapshotStore.appGroup()?.read(), inbox: ShareInbox.appGroup())
    }

    var canSend: Bool { phase == .ready && !contents.isEmpty }

    func load(_ items: [NSExtensionItem]) async {
        guard let snapshot, inbox != nil else {
            phase = .signedOut
            return
        }
        guard snapshot.isProUnlocked else {
            phase = .needsPro
            return
        }
        let loaded = await SharedContentLoader.load(items.map(SharedContentLoader.Item.init))
        show(loaded)
    }

    /// Shows already-loaded contents (also used by previews).
    func show(_ loaded: [SharedContent]) {
        contents = loaded
        if loaded.isEmpty {
            phase = .unsupported
        } else if loaded.map(\.byteCount).reduce(0, +) > SharedContentLoader.maxTotalBytes {
            phase = .tooLarge
        } else {
            phase = .ready
        }
    }

    /// Opens the Theseus Pro paywall in the app (ADR 0173).
    func openPaywall() async {
        if await openApp(DeepLink.pro.url) { finish() }
    }

    /// Stores the share and opens Theseus on it.
    func send() async {
        guard canSend, let inbox else { return }
        let entry: ShareInbox.Entry
        do {
            entry = try inbox.add(contents.map(\.inboxItem), note: note, accountID: snapshot?.accountID)
        } catch {
            phase = .failed("Theseus couldn't save what you shared. Try again.")
            return
        }
        if await openApp(DeepLink.sharedItems(entry.id).url) {
            finish()
        } else {
            phase = .saved
        }
    }
}
