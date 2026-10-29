import Auth
import Foundation
import OpenWebUIKit
import Testing

/// Reads the gitignored repo-root `.env`. Integration tests run only when
/// `THESEUS_INTEGRATION=1` **and** the file provides URL, email and password.
enum LiveServer {
    struct Settings {
        let url: URL
        let email: String
        let password: String
    }

    static let settings: Settings? = {
        guard ProcessInfo.processInfo.environment["THESEUS_INTEGRATION"] == "1" else { return nil }
        // Modules/Tests/IntegrationTests/LiveServerTests.swift → repo root.
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appending(path: ".env"), encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[key] = value
        }
        guard let address = values["THESEUS_OWUI_URL"], !address.isEmpty,
              let url = try? ServerURL.normalize(address),
              let email = values["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = values["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { return nil }
        return Settings(url: url, email: email, password: password)
    }()

    static var isConfigured: Bool { settings != nil }
}

/// Read-only checks against the real test Server (never mutates server state).
@Suite(
    "Live Server (opt-in: THESEUS_INTEGRATION=1 + .env)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
struct LiveServerTests {
    @Test func signInAndListModels() async throws {
        let settings = try #require(LiveServer.settings)
        let transport = URLSessionTransport()

        let config = try await OpenWebUIClient(server: settings.url, transport: transport).send(.config)
        #expect(config.features.allowsPasswordSignIn)

        let server = ServerProfile(url: settings.url, name: config.name)
        let outcome = try await PasswordSignIn(server: server, transport: transport)
            .signIn(email: settings.email, password: settings.password)
        guard case .signedIn(let session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }

        let authenticator = SessionAuthenticator(token: session.token) {
            throw OpenWebUIError.unauthorized(detail: nil)
        }
        let client = OpenWebUIClient(server: settings.url, transport: transport, authorizer: authenticator)

        let models = try await client.send(.models)
        #expect(!models.isEmpty)
        let user = try await client.send(.sessionUser)
        #expect(user.id == session.user.id)

        let authenticatedConfig = try await client.send(.config)
        let capabilities = Capabilities.resolve(features: authenticatedConfig.features, user: user, model: models.first)
        #expect(!capabilities.enabled.isEmpty)

        let chats = try await client.send(.chats(page: 1))
        #expect(chats.count <= 60, "the server pages Chats by 60")

        // Revoke the session this test created.
        _ = try await client.send(.signOut)
    }
}
