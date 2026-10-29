import Foundation

/// Whether an Account agreed to send its data to its Server and that Server's AI providers
/// (App Review 5.1.2(i), ADR 0171). Kept per Account on this device, like the welcome (ADR 0112).
struct AIDataConsentRecord {
    /// The disclosure's version. Bump it when what's shared, or with whom, changes: everyone is asked again.
    static let version = 1
    /// UI tests that aren't about the consent skip it, like the welcome.
    static let skipArgument = "-theseus-skip-consent"

    let defaults: UserDefaults
    let arguments: [String]

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.arguments = arguments
    }

    private func key(_ accountID: String) -> String { "theseus.aiDataConsent.\(accountID)" }

    func isNeeded(accountID: String) -> Bool {
        if arguments.contains(Self.skipArgument) || arguments.contains(WelcomeRecord.skipArgument) { return false }
        return defaults.integer(forKey: key(accountID)) < Self.version
    }

    func record(accountID: String) {
        defaults.set(Self.version, forKey: key(accountID))
    }

    func remove(accountID: String) {
        defaults.removeObject(forKey: key(accountID))
    }
}
