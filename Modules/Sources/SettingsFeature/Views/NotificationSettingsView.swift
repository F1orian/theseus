import DesignSystem
public import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings > Notifications (SET-06): the Response notifications switch and a shortcut to the
/// app's page in the iOS Settings app.
struct NotificationSettingsView: View {
    let notifier: ResponseNotifier
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                SettingsToggleRow(
                    title: "Response notifications",
                    systemImage: "bell.badge",
                    caption: "Get notified when a response finishes while Theseus is in the background.",
                    isOn: Binding(
                        get: { notifier.isEnabled },
                        set: { on in Task { await notifier.setEnabled(on) } }
                    )
                )
                .accessibilityIdentifier("notifications.responses")
            } footer: {
                if notifier.needsSystemSettings {
                    Text("Notifications are turned off for Theseus. Turn them on in Settings.")
                        .accessibilityIdentifier("notifications.denied")
                } else {
                    Text("Notifications arrive while Theseus is still running in the background. "
                        + "This Server can't send push notifications after iOS closes the app.")
                }
            }
            if let settingsURL {
                Section {
                    Button {
                        openURL(settingsURL)
                    } label: {
                        Text("Open Settings")
                            .font(Typography.body)
                            .foregroundStyle(Palette.accent.color)
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("notifications.openSettings")
                }
            }
        }
        .settingsList()
        .navigationTitle("Notifications")
        .settingsInlineTitle()
        .task { await notifier.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await notifier.refresh() } }
        }
        .accessibilityIdentifier("settings.notifications")
    }

    private var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #else
        nil
        #endif
    }
}

/// The one-time card under the first Response offering to notify when replies finish (SET-06).
/// The Chat screen shows it while `notifier.shouldOfferNotifications` is true.
public struct ResponseNotificationOfferCard: View {
    let notifier: ResponseNotifier

    public init(notifier: ResponseNotifier) {
        self.notifier = notifier
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(Palette.accent.color)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Get notified when responses finish")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
                Text("Leave Theseus while a long response is written; a notification tells you when it's ready.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on") {
                    Task { await notifier.acceptOffer() }
                }
                .font(Typography.headline)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("notificationOffer.accept")
            }
            Spacer(minLength: 0)
            Button("Not now", systemImage: "xmark") { notifier.dismissOffer() }
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.textSecondary.color)
                .accessibilityIdentifier("notificationOffer.dismiss")
        }
        .padding(Spacing.l)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
        .accessibilityIdentifier("notificationOffer")
    }
}
