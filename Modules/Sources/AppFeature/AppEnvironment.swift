public import Auth
public import Entitlements
public import Foundation
import Persistence
public import OpenWebUIKit
public import SettingsFeature

/// Everything the app talks to outside its own memory. `live()` for the app, `ephemeral(…)` for
/// tests, previews and UI-test launches.
public struct AppEnvironment: Sendable {
    public var transport: any HTTPTransport
    public var credentials: any CredentialStore
    public var registry: AccountRegistry
    /// Where per-Account databases live; `nil` keeps them in memory.
    public var databaseDirectory: URL?
    /// The `UserDefaults` suite for per-Account on-device preferences (Settings: appearance,
    /// haptics, notifications); `nil` uses the standard defaults.
    public var preferencesSuiteName: String?
    /// Creates the notification center for Response notifications (SET-06), once per launch.
    public var makeNotificationCenter: @MainActor @Sendable () -> any NotificationScheduling
    /// The App Group state shared with the widgets and Share extension (ADR 0100); `nil` keeps
    /// the extensions out of it (tests, UI-test launches, unsigned builds).
    public var sharedState: SharedStateStore?
    /// Asks each Account once, before its first message, to agree to send its data to its Server
    /// and the AI providers behind it (App Review 5.1.2(i), ADR 0171). Unit tests turn it off; UI
    /// tests skip it with `-theseus-skip-consent` (or `-theseus-skip-welcome`).
    public var asksForAIDataConsent = true
    /// The App Store side of Theseus Pro (ADR 0173): StoreKit live, in memory for tests.
    public var proBackend: any ProStoreBackend

    public init(
        transport: any HTTPTransport,
        credentials: any CredentialStore,
        registry: AccountRegistry,
        databaseDirectory: URL?,
        preferencesSuiteName: String? = nil,
        makeNotificationCenter: @escaping @MainActor @Sendable () -> any NotificationScheduling = { InertNotificationCenter() },
        sharedState: SharedStateStore? = nil,
        proBackend: any ProStoreBackend = InMemoryProBackend(entitled: true)
    ) {
        self.sharedState = sharedState
        self.proBackend = proBackend
        self.transport = transport
        self.credentials = credentials
        self.registry = registry
        self.databaseDirectory = databaseDirectory
        self.preferencesSuiteName = preferencesSuiteName
        self.makeNotificationCenter = makeNotificationCenter
    }

    /// Keychain, Application Support and a real network transport.
    /// - Parameter reset: Forget every Account first (used by `-theseus-reset` launches).
    public static func live(reset: Bool = false) -> AppEnvironment {
        let root = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "Theseus", directoryHint: .isDirectory)
        let registryURL = root.appending(path: "accounts.json")
        let databaseDirectory = root.appending(path: "Accounts", directoryHint: .isDirectory)
        let credentials = KeychainCredentialStore()

        if reset {
            for account in AccountRegistry(fileURL: registryURL).accounts {
                try? credentials.deleteCredential(for: account.id)
            }
            try? FileManager.default.removeItem(at: registryURL)
            try? FileManager.default.removeItem(at: databaseDirectory)
            SharedContainer.appGroup().map(SharedStateStore.init(container:))?.clear()
        }
        return AppEnvironment(
            transport: URLSessionTransport(),
            credentials: credentials,
            registry: AccountRegistry(fileURL: registryURL),
            databaseDirectory: databaseDirectory,
            makeNotificationCenter: { UserNotificationCenter() },
            sharedState: SharedContainer.appGroup().map(SharedStateStore.init(container:)),
            proBackend: StoreKitProBackend()
        )
    }

    /// Nothing persists beyond the process.
    /// - Parameter pro: Theseus Pro in memory: unlocked by default, so walkthroughs reach every
    ///   feature; UI tests of the free tier pass `InMemoryProBackend()` (`-theseus-pro free`).
    public static func ephemeral(
        transport: any HTTPTransport = URLSessionTransport(),
        pro: any ProStoreBackend = InMemoryProBackend(entitled: true)
    ) -> AppEnvironment {
        AppEnvironment(
            transport: transport,
            credentials: InMemoryCredentialStore(),
            registry: AccountRegistry(fileURL: nil),
            databaseDirectory: nil,
            preferencesSuiteName: "theseus.ephemeral.\(UUID().uuidString)",
            proBackend: pro
        )
    }
}

extension AppEnvironment {
    var preferences: UserDefaults {
        preferencesSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
