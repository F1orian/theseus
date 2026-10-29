import Auth
import Foundation
public import OpenWebUIKit

/// Turns what the user typed into a validated Server: normalises the address, reads the public
/// `/api/config`, and checks the version Theseus needs (AUTH-01).
struct ServerConnection {
    /// The oldest Open WebUI release Theseus speaks to (OpenResponses output, server-side turns).
    static let minimumVersion = "0.12.0"

    let transport: any HTTPTransport

    /// - Throws: `ServerConnectionError` with a user-presentable message.
    func connect(to address: String) async throws(ServerConnectionError) -> (ServerProfile, ServerConfig) {
        let url: URL
        do {
            url = try ServerURL.normalize(address)
        } catch {
            throw ServerConnectionError(error)
        }
        let typedScheme = address.contains("://")
        do {
            return try await probe(url)
        } catch .transport(let code) where !typedScheme && Self.mayRetryOverHTTP(code) {
            // Home servers on a LAN IP or .local name often only speak plain HTTP.
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ServerConnectionError(.transport(code))
            }
            components.scheme = "http"
            guard let httpURL = components.url else { throw ServerConnectionError(.transport(code)) }
            do {
                return try await probe(httpURL)
            } catch {
                // Report the original https failure; it's the address the user meant.
                throw ServerConnectionError(.transport(code))
            }
        } catch {
            throw ServerConnectionError(error)
        }
    }

    private func probe(_ url: URL) async throws(OpenWebUIError) -> (ServerProfile, ServerConfig) {
        let config: ServerConfig
        do {
            config = try await OpenWebUIClient(server: url, transport: transport).send(.config)
        } catch .decoding, .server(status: 404, _) {
            throw .notOpenWebUI
        }
        guard ServerVersion(version: config.version).isAtLeast(Self.minimumVersion) else {
            throw .unsupported("Open WebUI \(config.version)")
        }
        return (ServerProfile(url: url, name: config.name), config)
    }

    /// Connection-level failures only; TLS trust problems must never silently downgrade to HTTP.
    private static func mayRetryOverHTTP(_ code: URLError.Code) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .secureConnectionFailed]
            .contains(code)
    }
}

/// A Server connection failure with its user-facing message.
struct ServerConnectionError: Error, Equatable {
    let underlying: OpenWebUIError

    init(_ underlying: OpenWebUIError) {
        self.underlying = underlying
    }

    var message: String {
        switch underlying {
        case .unsupported(let what):
            "This server runs \(what). Theseus needs Open WebUI 0.12 or newer."
        default:
            underlying.message
        }
    }
}

/// How a Server lets people sign in, read from its public `/api/config` (ADR 0006: only offer
/// what the Server backs).
public struct SignInMethods: Sendable, Hashable {
    /// One single sign-on provider (`oauth.providers`), e.g. `oidc` → "Company SSO".
    public struct SSOProvider: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Email + password form (`features.enable_login_form`).
    public var password: Bool
    /// LDAP username + password (`features.enable_ldap`).
    public var ldap: Bool
    /// Single sign-on pills, sorted by display name.
    public var ssoProviders: [SSOProvider]
    /// A reverse proxy authenticates (`features.auth_trusted_header`); sign in through the web page.
    public var trustedHeader: Bool
    /// `false` for single-user Servers (`WEBUI_AUTH=false`): no credentials at all.
    public var requiresAuth: Bool
    /// The Server has no users yet (`onboarding`). Theseus doesn't create the first admin (ADR 0170).
    public var isFirstRun: Bool

    public init(
        password: Bool = false,
        ldap: Bool = false,
        ssoProviders: [SSOProvider] = [],
        trustedHeader: Bool = false,
        requiresAuth: Bool = true,
        isFirstRun: Bool = false
    ) {
        self.password = password
        self.ldap = ldap
        self.ssoProviders = ssoProviders
        self.trustedHeader = trustedHeader
        self.requiresAuth = requiresAuth
        self.isFirstRun = isFirstRun
    }

    public init(config: ServerConfig) {
        let features = config.features
        guard features.requiresAuth else {
            self.init(requiresAuth: false)
            return
        }
        let password = features.allowsPasswordSignIn
        self.init(
            password: password,
            ldap: features.allowsLDAP,
            ssoProviders: config.oauthProviders
                .map { SSOProvider(id: $0.key, name: $0.value.isEmpty ? $0.key : $0.value) }
                .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) },
            trustedHeader: features.usesTrustedHeaderAuth,
            isFirstRun: config.isOnboarding
        )
    }

    /// Whether the user can sign in at all with what Theseus supports.
    public var hasAnyMethod: Bool {
        !requiresAuth || password || ldap || trustedHeader || !ssoProviders.isEmpty
    }
}
