public import OpenWebUIKit

/// Holds an Account's Session token and renews it **single-flight**: however many requests hit
/// a 401 at once, only one renewal runs and every caller awaits its result. Requests that were
/// rejected with an older token simply pick up the already-renewed one.
///
/// Open WebUI has no refresh tokens, so `renew` re-runs a sign-in strategy (e.g. password, if the
/// user opted to store it). When renewal fails the session is *expired*: further renewals fail
/// fast until `restore(token:)` installs a fresh token from an interactive sign-in.
public actor SessionAuthenticator: RequestAuthorizer {
    public typealias Renewal = @Sendable () async throws -> String
    /// Called after every token change; `nil` means the session expired. Persist or react here.
    public typealias TokenObserver = @Sendable (String?) -> Void

    private var token: String?
    private var isExpired = false
    private var inFlight: Task<String, any Error>?
    private let renew: Renewal
    private let observer: TokenObserver

    public init(token: String?, renew: @escaping Renewal, onTokenChange observer: @escaping TokenObserver = { _ in }) {
        self.token = token
        self.renew = renew
        self.observer = observer
    }

    public func currentToken() -> String? {
        isExpired ? nil : token
    }

    public func renewToken(rejected: String) async throws -> String {
        if let token, token != rejected, !isExpired {
            return token
        }
        if let inFlight {
            do {
                return try await inFlight.value
            } catch {
                throw OpenWebUIError.unauthorized(detail: nil)
            }
        }
        if isExpired {
            throw OpenWebUIError.unauthorized(detail: nil)
        }

        let task = Task { try await renew() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let renewed = try await task.value
            token = renewed
            observer(renewed)
            return renewed
        } catch {
            token = nil
            isExpired = true
            observer(nil)
            throw OpenWebUIError.unauthorized(detail: nil)
        }
    }

    /// Installs a token from an interactive sign-in and clears the expired state.
    public func restore(token: String) {
        self.token = token
        isExpired = false
        observer(token)
    }
}
