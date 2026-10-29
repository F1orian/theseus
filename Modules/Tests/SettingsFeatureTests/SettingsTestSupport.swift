import Auth
import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature

/// Static token so `.required` endpoints are sent.
struct StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

let testAccount = Account(
    server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
    userID: "00000000-0000-4000-8000-000000000001",
    name: "Test User",
    email: "user@example.com"
)

/// A throwaway `UserDefaults` suite per test, so preference tests never share state.
func makeDefaults() -> UserDefaults {
    let name = "theseus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func makeClient(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
}

func capabilities(_ enabled: Capability...) -> Capabilities {
    Capabilities(enabled: Set(enabled))
}

/// Records what the Settings sheet asked the app to do.
@MainActor
final class ActionLog {
    var events: [String] = []

    var actions: SettingsActions {
        SettingsActions(
            signOut: { [self] in events.append("signOut") },
            removeAccountFromDevice: { [self] in events.append("remove") },
            clearCache: { [self] in events.append("clearCache") },
            cacheSize: { 2_048 }
        )
    }
}
