public import Foundation
public import Observation

/// Whether iOS lets Theseus post notifications.
public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// A local "your Response is ready" notification.
public struct ResponseNotification: Sendable, Equatable {
    public let chatID: String
    public let title: String
    public let body: String

    /// The `userInfo` key carrying the Chat id, so a tap can open it.
    public static let chatIDKey = "theseus.chatID"

    public init(chatID: String, title: String, body: String) {
        self.chatID = chatID
        self.title = title
        self.body = body
    }
}

/// The system notification center as `ResponseNotifier` needs it. `UserNotificationCenter` is the
/// live implementation; tests use a fake.
@MainActor
public protocol NotificationScheduling: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    /// Shows the system prompt (only possible while `.notDetermined`). Returns whether it was granted.
    func requestAuthorization() async -> Bool
    func post(_ notification: ResponseNotification) async
}

/// Response notifications (SET-06): a local notification when a Response finishes while Theseus is
/// in the background. Open WebUI has no push relay, so there are no notifications after iOS
/// suspends the app (ADR 0013).
///
/// The Chat screen calls `responseFinished(chatID:chatTitle:excerpt:)` when a stream completes
/// (`chat:completion` with `done: true`, or `chat:active` turning false) and shows the one-time
/// offer card (`ResponseNotificationOfferCard`) after the first Response while
/// `shouldOfferNotifications` is true.
@MainActor
@Observable
public final class ResponseNotifier {
    public private(set) var authorization: NotificationAuthorization = .notDetermined

    @ObservationIgnored private let center: any NotificationScheduling
    @ObservationIgnored private let preferences: AccountPreferencesStore
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool

    public init(
        center: any NotificationScheduling,
        preferences: AccountPreferencesStore,
        isAppActive: @escaping @MainActor () -> Bool
    ) {
        self.center = center
        self.preferences = preferences
        self.isAppActive = isAppActive
    }

    /// The user's choice (stays on this device).
    public var isEnabled: Bool {
        preferences.preferences.responseNotifications
    }

    /// iOS has notifications off for Theseus; only the system Settings app can turn them back on.
    public var needsSystemSettings: Bool {
        authorization == .denied
    }

    /// Whether to show the one-time offer after the first Response.
    public var shouldOfferNotifications: Bool {
        !preferences.preferences.hasSeenNotificationOffer && !isEnabled
    }

    /// Re-reads the system permission (e.g. after returning from the Settings app).
    public func refresh() async {
        authorization = await center.authorizationStatus()
    }

    /// Turns notifications on or off. Turning on asks iOS for permission the first time.
    public func setEnabled(_ enabled: Bool) async {
        guard enabled else {
            preferences.preferences.responseNotifications = false
            return
        }
        authorization = await center.authorizationStatus()
        if authorization == .notDetermined {
            _ = await center.requestAuthorization()
            authorization = await center.authorizationStatus()
        }
        preferences.preferences.responseNotifications = authorization == .authorized
    }

    public func acceptOffer() async {
        preferences.preferences.hasSeenNotificationOffer = true
        await setEnabled(true)
    }

    public func dismissOffer() {
        preferences.preferences.hasSeenNotificationOffer = true
    }

    /// Call when a Response finished streaming. Posts a notification only if the user turned them
    /// on, iOS allows them, and Theseus isn't in the foreground.
    public func responseFinished(chatID: String, chatTitle: String, excerpt: String) async {
        guard isEnabled, !isAppActive() else { return }
        authorization = await center.authorizationStatus()
        guard authorization == .authorized else { return }
        let title = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        await center.post(ResponseNotification(
            chatID: chatID,
            title: title.isEmpty ? "Response ready" : title,
            body: Self.shorten(excerpt)
        ))
    }

    nonisolated static func shorten(_ text: String, limit: Int = 180) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
