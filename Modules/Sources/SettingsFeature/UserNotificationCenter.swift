public import Foundation
public import UserNotifications

/// The live `NotificationScheduling`, backed by `UNUserNotificationCenter`. Create one per app
/// launch, early: it becomes the center's delegate so tapping a notification opens its Chat
/// (`onOpenChat`), including on a cold start.
@MainActor
public final class UserNotificationCenter: NSObject, NotificationScheduling {
    /// Opens a Chat after the user tapped its notification. A tap that arrives before this is set
    /// (cold start) is kept and delivered once it is.
    public var onOpenChat: (@MainActor (String) -> Void)? {
        didSet {
            guard let onOpenChat, let pendingChatID else { return }
            self.pendingChatID = nil
            onOpenChat(pendingChatID)
        }
    }

    private var pendingChatID: String?

    override public init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func post(_ notification: ResponseNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.chatID
        content.userInfo = [ResponseNotification.chatIDKey: notification.chatID]
        let request = UNNotificationRequest(
            identifier: "response.\(notification.chatID)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    fileprivate func open(chatID: String) {
        if let onOpenChat {
            onOpenChat(chatID)
        } else {
            pendingChatID = chatID
        }
    }
}

extension UserNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let chatID = response.notification.request.content.userInfo[ResponseNotification.chatIDKey] as? String
        else { return }
        await open(chatID: chatID)
    }

    /// In the foreground the Response is on screen already: no banner.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}

/// A `NotificationScheduling` that never posts (previews, unit tests, UI-test launches).
@MainActor
public final class InertNotificationCenter: NotificationScheduling {
    public init() {}
    public func authorizationStatus() async -> NotificationAuthorization { .notDetermined }
    public func requestAuthorization() async -> Bool { false }
    public func post(_ notification: ResponseNotification) async {}
}
