import Auth
import Entitlements
import Foundation
import SettingsFeature
@testable import Theseus
import Testing

@Suite("App target")
struct TheseusTests {
    @Test func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "dev.unrush.theseus")
    }

    @Test(arguments: [
        ([String](), false, false),
        (["-theseus-ui-testing"], true, false),
        (["-theseus-reset"], false, true),
        (["app", "-theseus-reset", "-theseus-ui-testing"], true, true),
    ])
    func launchArguments(arguments: [String], uiTesting: Bool, reset: Bool) {
        let configuration = LaunchConfiguration(arguments: arguments)
        #expect(configuration.isUITesting == uiTesting)
        #expect(configuration.resetsState == reset)
    }

    /// ADR 0173: `-theseus-pro free|pro`.
    @Test(arguments: [
        ([String](), nil),
        (["-theseus-pro", "free"], LaunchConfiguration.ProOverride.free),
        (["-theseus-ui-testing", "-theseus-pro", "pro"], .pro),
        (["-theseus-pro"], nil),
        (["-theseus-pro", "gold"], nil),
    ] as [([String], LaunchConfiguration.ProOverride?)])
    func proLaunchArgument(arguments: [String], expected: LaunchConfiguration.ProOverride?) {
        #expect(LaunchConfiguration(arguments: arguments).pro == expected)
    }

    /// Runs inside the app host, so this exercises the real iOS Keychain with the app's entitlements.
    @Test func keychainRoundTripOnDevice() throws {
        let store = KeychainCredentialStore(service: "dev.unrush.theseus.tests.\(UUID().uuidString)")
        let id = "https://owui.example.com|\(UUID().uuidString)"
        try store.save(Credential(sessionToken: "jwt"), for: id)
        #expect(try store.credential(for: id) == Credential(sessionToken: "jwt"))
        try store.deleteCredential(for: id)
        #expect(try store.credential(for: id) == nil)
    }
}

/// BRAND-02: actool wrote CFBundleIcons from the build settings, and it lists exactly the icons
/// Settings › App Icon offers.
@Suite("App icons in the bundle")
struct AppIconBundleTests {
    private var icons: [String: Any] {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any] ?? [:]
    }

    @Test func primaryIcon() {
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        #expect(primary?["CFBundleIconName"] as? String == AppIconCatalog.primary.name)
    }

    @Test func alternateIconsMatchTheCatalog() {
        let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        #expect(Set(alternates.keys) == Set(AppIconCatalog.alternateNames))
        #expect(alternates.count == 11)
        // ADR 0173: the paywall's "Choose from 11 more icons" counts the shipped alternates.
        #expect(alternates.count == ProFeature.alternateIconCount)
    }

    @MainActor
    @Test func theSimulatorSupportsAlternateIcons() {
        #expect(SystemAppIconSwitcher().supportsAlternateIcons)
    }
}
