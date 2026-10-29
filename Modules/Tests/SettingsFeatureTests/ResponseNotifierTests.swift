import Foundation
@testable import SettingsFeature
import Testing

/// A fake notification center: answers permission prompts and records posted notifications.
@MainActor
final class FakeNotificationCenter: NotificationScheduling {
    var status: NotificationAuthorization
    var grantsOnRequest: Bool
    var requests = 0
    var posted: [ResponseNotification] = []

    init(status: NotificationAuthorization = .notDetermined, grantsOnRequest: Bool = true) {
        self.status = status
        self.grantsOnRequest = grantsOnRequest
    }

    func authorizationStatus() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requests += 1
        status = grantsOnRequest ? .authorized : .denied
        return grantsOnRequest
    }

    func post(_ notification: ResponseNotification) async {
        posted.append(notification)
    }
}

@MainActor
@Suite("Response notifications (SET-06)")
struct ResponseNotifierTests {
    let preferences = AccountPreferencesStore(accountID: "a", defaults: makeDefaults())

    func makeNotifier(_ center: FakeNotificationCenter, active: Bool = false) -> ResponseNotifier {
        ResponseNotifier(center: center, preferences: preferences, isAppActive: { active })
    }

    @Test func turningOnAsksForPermissionOnce() async {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        await notifier.setEnabled(true)
        #expect(center.requests == 1)
        #expect(notifier.isEnabled)
        #expect(notifier.authorization == .authorized)
    }

    @Test func deniedPermissionKeepsItOffAndPointsToSystemSettings() async {
        let center = FakeNotificationCenter(status: .denied)
        let notifier = makeNotifier(center)
        await notifier.setEnabled(true)
        #expect(center.requests == 0, "iOS won't ask again; the user must use Settings")
        #expect(!notifier.isEnabled)
        #expect(notifier.needsSystemSettings)
    }

    @Test func aFinishedResponseNotifiesOnlyInTheBackground() async {
        let center = FakeNotificationCenter(status: .authorized)
        preferences.preferences.responseNotifications = true

        await makeNotifier(center, active: true).responseFinished(chatID: "c1", chatTitle: "Trip", excerpt: "Done")
        #expect(center.posted.isEmpty, "no banner while the user is looking at the app")

        await makeNotifier(center, active: false).responseFinished(chatID: "c1", chatTitle: "Trip", excerpt: "Here's the plan")
        #expect(center.posted == [ResponseNotification(chatID: "c1", title: "Trip", body: "Here's the plan")])
    }

    @Test func nothingIsPostedWhenTurnedOffOrNotAllowed() async {
        let allowed = FakeNotificationCenter(status: .authorized)
        await makeNotifier(allowed).responseFinished(chatID: "c", chatTitle: "T", excerpt: "x")
        #expect(allowed.posted.isEmpty, "off by default")

        preferences.preferences.responseNotifications = true
        let revoked = FakeNotificationCenter(status: .denied)
        await makeNotifier(revoked).responseFinished(chatID: "c", chatTitle: "T", excerpt: "x")
        #expect(revoked.posted.isEmpty, "permission revoked in iOS Settings")
    }

    @Test func longExcerptsAreShortenedAndEmptyTitlesGetAFallback() async {
        let center = FakeNotificationCenter(status: .authorized)
        preferences.preferences.responseNotifications = true
        let long = String(repeating: "word ", count: 100)
        await makeNotifier(center).responseFinished(chatID: "c", chatTitle: "", excerpt: long)
        let posted = try? #require(center.posted.first)
        #expect(posted?.title == "Response ready")
        #expect((posted?.body.count ?? 0) <= 180)
    }

    @Test func theOfferShowsOnceUntilAnsweredEitherWay() async {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        #expect(notifier.shouldOfferNotifications)
        notifier.dismissOffer()
        #expect(!notifier.shouldOfferNotifications)

        let other = ResponseNotifier(
            center: center,
            preferences: AccountPreferencesStore(accountID: "b", defaults: makeDefaults()),
            isAppActive: { false }
        )
        await other.acceptOffer()
        #expect(other.isEnabled)
        #expect(!other.shouldOfferNotifications)
    }
}
