import Foundation
public import Observation
public import OpenWebUIKit

/// The Add / Edit connector sheet's state (#186): one form for personal connectors and the
/// Server's shared connections, with inline validation and a Verify step that shows what the
/// server (or, for personal connectors, the device) found.
@MainActor
@Observable
public final class ConnectorForm {
    public enum Kind: Equatable, Sendable {
        /// A personal connector (direct tool server): OpenAPI only, key in the user settings like
        /// the web client's.
        case personal
        /// A shared connection in Server administration (admins).
        case shared
    }

    public enum VerifyState: Equatable, Sendable {
        case idle
        case checking
        /// Tool names, when the answer lists them.
        case tools([String], title: String?)
        /// OAuth 2.1 discovery worked: the provider's issuer.
        case signIn(issuer: String)
        case failed(String)
    }

    public let kind: Kind
    /// The entry being edited; `nil` adds a new one.
    public let existing: ToolServerConnection?
    public var draft: ToolServerConnection.Draft {
        didSet { if draft != oldValue { verifyState = .idle } }
    }
    /// The key typed in this sheet. While editing, an untouched key field keeps the stored key.
    public var key = "" {
        didSet { if key != oldValue { verifyState = .idle } }
    }
    /// Editing an entry whose key is already set: the field shows "•••• set" until Replace.
    public var isReplacingKey: Bool
    /// OAuth 2.1 (static): the client secret typed in this sheet. While editing, an untouched
    /// field keeps the stored secret.
    public var clientSecret = "" {
        didSet { if clientSecret != oldValue { verifyState = .idle } }
    }
    /// Editing a static OAuth entry whose secret is set: "•••• set" until Replace.
    public var isReplacingSecret: Bool
    /// Saving failed because the provider doesn't let the Server register itself (#193): the
    /// Server's message, shown with the ways forward. Cleared by switching sign-in.
    public private(set) var registrationUnsupported: String?
    public private(set) var verifyState: VerifyState = .idle
    /// Validation messages show once the user tried to save or verify (or typed in the field).
    public var showsAllErrors = false
    public private(set) var isSaving = false
    let hasStoredKey: Bool

    public init(kind: Kind, existing: ToolServerConnection? = nil, hasStoredKey: Bool = false) {
        self.kind = kind
        self.existing = existing
        self.hasStoredKey = hasStoredKey
        isReplacingKey = !hasStoredKey
        isReplacingSecret = existing?.authType != .oauth21Static || existing?.oauthClientSecret.isEmpty != false
        if let existing {
            draft = existing.draft
        } else {
            draft = ToolServerConnection.Draft(type: kind == .personal ? .openAPI : .mcp, authType: kind == .personal ? .bearer : .none)
        }
        if kind == .personal { draft.type = .openAPI }
    }

    public var isEditing: Bool { existing != nil }

    // MARK: Choices

    /// The types this form offers (personal connectors are OpenAPI only).
    public var types: [ToolServerConnection.ServerType] {
        kind == .personal ? [.openAPI] : [.mcp, .openAPI]
    }

    /// The auth choices for the current type. OAuth 2.1 (dynamic registration or a static app) is
    /// for shared MCP servers; an entry from the web admin with another kind (SSO) keeps it as a
    /// choice.
    public var authTypes: [ToolServerConnection.AuthType] {
        var all: [ToolServerConnection.AuthType] = [.none, .bearer, .session]
        if kind == .shared, draft.type == .mcp { all += [.oauth21, .oauth21Static] }
        if let original = existing?.authType, !all.contains(original) { all.append(original) }
        return all
    }

    /// Switching to OpenAPI drops OAuth 2.1, which only MCP servers use.
    public func typeChanged() {
        if !authTypes.contains(draft.authType) { draft.authType = .none }
    }

    // MARK: Validation

    public var nameError: String? {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give it a name." : nil
    }

    public var urlError: String? {
        let text = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter the server's address." }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host()?.isEmpty == false
        else { return "Enter a full address, like https://tools.example.com." }
        return nil
    }

    /// The entry's spec was pasted in the web app (`spec_type: "json"`), so there's no spec path.
    public var usesPastedSpec: Bool { existing?.hasInlineSpec == true }

    public var specPathError: String? {
        guard draft.type == .openAPI, !usesPastedSpec else { return nil }
        return draft.specPath.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter where the OpenAPI spec is, like openapi.json." : nil
    }

    public var keyError: String? {
        guard draft.authType == .bearer, isReplacingKey else { return nil }
        return key.isEmpty ? "Paste the key, or choose None." : nil
    }

    /// Whether this is an MCP server with a static OAuth app (client id and secret).
    public var usesStaticOAuth: Bool {
        kind == .shared && draft.type == .mcp && draft.authType == .oauth21Static
    }

    public var clientIDError: String? {
        guard usesStaticOAuth else { return nil }
        return draft.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Paste the OAuth app's client ID." : nil
    }

    public var clientSecretError: String? {
        guard usesStaticOAuth, isReplacingSecret else { return nil }
        return clientSecret.isEmpty ? "Paste the OAuth app's client secret." : nil
    }

    public var isValid: Bool {
        nameError == nil && urlError == nil && specPathError == nil && keyError == nil
            && clientIDError == nil && clientSecretError == nil
    }

    /// The key to save: `nil` keeps the stored one.
    public var keyToSave: String? {
        guard draft.authType == .bearer else { return nil }
        return isReplacingKey ? key : nil
    }

    /// The OAuth client secret to save: `nil` keeps the stored one.
    public var secretToSave: String? {
        guard usesStaticOAuth else { return nil }
        return isReplacingSecret ? clientSecret : nil
    }

    /// The connection id (`info.id`) the entry is saved under: the existing one, or the one a new
    /// entry gets from its name. The callback URL names it, so it's known before saving.
    public func serverID(in shared: ServerConnections) -> String {
        existing?.serverID ?? shared.plannedServerID(for: draft.name)
    }

    /// The callback URL to register at the provider (OAuth 2.1 static), or `nil` until the entry
    /// has a name to make its id from.
    public func callbackURL(in shared: ServerConnections) -> String? {
        guard usesStaticOAuth else { return nil }
        guard existing != nil || nameError == nil else { return nil }
        return shared.oauthCallbackURL(serverID: serverID(in: shared))
    }

    /// A shared MCP server signing in with one Bearer token for everyone: they all act as the
    /// token's account.
    public var sharesOneAccount: Bool {
        kind == .shared && draft.type == .mcp && draft.authType == .bearer && draft.access.audience == .everyone
    }

    // MARK: When registration isn't supported (#193)

    /// Switches to OAuth 2.1 with the admin's own OAuth app, keeping every other field.
    public func useStaticOAuth() {
        switchAuth(to: .oauth21Static)
    }

    /// Switches to a Bearer token (a personal access token), keeping every other field.
    public func useBearerToken() {
        switchAuth(to: .bearer)
    }

    private func switchAuth(to auth: ToolServerConnection.AuthType) {
        draft.authType = auth
        registrationUnsupported = nil
        showsAllErrors = false
    }

    /// Sign-in changed in the picker: the registration problem was about the old choice.
    public func authChanged() {
        if draft.authType != .oauth21 { registrationUnsupported = nil }
    }

    /// Whether this is an OAuth 2.1 MCP server (users connect after it's saved).
    public var usesOAuth: Bool {
        kind == .shared && draft.type == .mcp && draft.authType.isOAuth21
    }

    // MARK: Verify

    public func verify(personal: PersonalConnectors?, shared: ServerConnections?) async {
        showsAllErrors = true
        guard isValid else { return }
        verifyState = .checking
        switch kind {
        case .personal:
            guard let personal else { return }
            switch await personal.verify(draft, key: keyToSave, existing: existing) {
            case .success(let tools): verifyState = .tools(tools, title: nil)
            case .failure(let error): verifyState = .failed(error.message)
            }
        case .shared:
            guard let shared else { return }
            switch await shared.verify(draft, key: keyToSave, existing: existing) {
            case .success(let result):
                if let issuer = result.oauthIssuer {
                    verifyState = .signIn(issuer: issuer)
                } else {
                    verifyState = .tools(result.tools?.map(\.name) ?? [], title: result.title)
                }
            case .failure(let error):
                verifyState = .failed(error.message)
            }
        }
    }

    // MARK: Save

    /// Saves through `personal` or `shared`. Returns the stored connection (shared), or the
    /// personal entry, or `nil` when it failed.
    public func save(personal: PersonalConnectors?, shared: ServerConnections?) async -> ToolServerConnection? {
        showsAllErrors = true
        guard isValid else { return nil }
        isSaving = true
        defer { isSaving = false }
        switch kind {
        case .personal:
            guard let personal else { return nil }
            let saved: Bool
            if let existing {
                saved = await personal.update(existing, with: draft, key: keyToSave)
            } else {
                saved = await personal.add(draft, key: keyToSave)
            }
            return saved ? (existing?.applying(draft, key: "") ?? ToolServerConnection.personal(draft)) : nil
        case .shared:
            guard let shared else { return nil }
            registrationUnsupported = nil
            let saved = await shared.save(draft, key: keyToSave, clientSecret: secretToSave, existing: existing)
            if saved == nil, case .dynamicRegistrationUnsupported(let detail)? = shared.saveFailure {
                registrationUnsupported = detail
            }
            return saved
        }
    }
}

extension ToolServerConnection.AuthType {
    /// The picker label.
    public var label: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer key"
        case .session: "Session"
        case .systemOAuth: "Single sign-on"
        case .oauth21: "OAuth 2.1"
        case .oauth21Static: "OAuth 2.1 (static)"
        case .other(let value): value
        }
    }

    /// The caption under the picker.
    public var caption: String {
        switch self {
        case .none: "No sign-in. Anyone who can reach the server can use it."
        case .bearer: "Sends a key with every call."
        case .session: "Sends the user's Open WebUI session. Only use it for servers you trust."
        case .systemOAuth: "Forwards the user's single sign-on token (set up in the web admin)."
        case .oauth21: "Each person signs in to the server once, with Connect."
        case .oauth21Static: "Each person signs in with Connect, through an OAuth app you create at the provider."
        case .other: "Set up in the web admin."
        }
    }
}

extension ToolServerConnection.ServerType {
    public var label: String {
        switch self {
        case .mcp: "MCP"
        case .openAPI: "OpenAPI"
        }
    }
}
