/// `GET /api/config`. Unauthenticated callers get the public subset (name, version, OAuth
/// providers, sign-in flags); with a Session token the server adds every `features.enable_*`
/// flag, default models, audio and file limits (`B/main.py:2280-2560`).
public struct ServerConfig: Sendable, Equatable, Decodable {
    public let name: String
    public let version: String
    /// `true` when the Server has no users yet; the next sign-up creates the admin.
    public let isOnboarding: Bool
    /// OAuth provider ids → display names (e.g. `"oidc": "Company SSO"`).
    public let oauthProviders: [String: String]
    public let features: ServerFeatures
    /// Model ids the admin configured as defaults (`default_models` is a comma-separated string).
    public let defaultModelIDs: [String]
    /// Models the admin pins for everyone (`default_pinned_models`, comma-separated); the picker's
    /// primary list when the user has no pins of their own (MODEL-03).
    public var defaultPinnedModelIDs: [String] = []
    /// Attachment limits (`file`; authenticated only).
    public var fileLimits = FileLimits()
    /// The admin's message for Accounts awaiting approval (`ui.pending_user_overlay_*`). Only sent
    /// to authenticated callers, including pending ones.
    public let pendingApprovalTitle: String?
    public let pendingApprovalMessage: String?

    enum CodingKeys: String, CodingKey {
        case name, version, onboarding, oauth, features, file, ui, code
        case defaultModels = "default_models"
        case defaultPinnedModels = "default_pinned_models"
    }

    private struct OAuth: Decodable {
        let providers: [String: String]?
    }

    private struct Code: Decodable {
        let interpreterEngine: String?
        enum CodingKeys: String, CodingKey { case interpreterEngine = "interpreter_engine" }
    }

    private struct UI: Decodable {
        let pendingUserOverlayTitle: String?
        let pendingUserOverlayContent: String?

        enum CodingKeys: String, CodingKey {
            case pendingUserOverlayTitle = "pending_user_overlay_title"
            case pendingUserOverlayContent = "pending_user_overlay_content"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Open WebUI"
        version = try container.decode(String.self, forKey: .version)
        isOnboarding = try container.decodeIfPresent(Bool.self, forKey: .onboarding) ?? false
        oauthProviders = try container.decodeIfPresent(OAuth.self, forKey: .oauth)?.providers ?? [:]
        var features = try container.decodeIfPresent(ServerFeatures.self, forKey: .features) ?? ServerFeatures(raw: [:])
        // CONN-08: only some engines run without a browser (authenticated config only).
        features.codeInterpreterEngine = (try? container.decodeIfPresent(Code.self, forKey: .code))?.interpreterEngine
        self.features = features
        // Lenient: an unexpected `ui` shape must never break connecting to a Server.
        let ui = try? container.decodeIfPresent(UI.self, forKey: .ui)
        pendingApprovalTitle = ui?.pendingUserOverlayTitle.flatMap { $0.isEmpty ? nil : $0 }
        pendingApprovalMessage = ui?.pendingUserOverlayContent.flatMap { $0.isEmpty ? nil : $0 }
        defaultModelIDs = Self.list(try container.decodeIfPresent(String.self, forKey: .defaultModels))
        defaultPinnedModelIDs = Self.list((try? container.decodeIfPresent(String.self, forKey: .defaultPinnedModels)) ?? nil)
        fileLimits = (try? container.decodeIfPresent(FileLimits.self, forKey: .file)) ?? FileLimits()
    }

    private static func list(_ commaSeparated: String?) -> [String] {
        (commaSeparated ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// `config.file`: per-Message Attachment limits and the admin's image compression bound.
public struct FileLimits: Sendable, Equatable, Decodable {
    /// Largest upload in megabytes (`nil`: no limit).
    public var maxSizeMB: Double?
    /// Most files per Message (`nil`: no limit).
    public var maxCount: Int?
    /// Images are scaled down to fit these (pixels, `nil`: unbounded).
    public var imageMaxWidth: Int?
    public var imageMaxHeight: Int?

    public init(maxSizeMB: Double? = nil, maxCount: Int? = nil, imageMaxWidth: Int? = nil, imageMaxHeight: Int? = nil) {
        self.maxSizeMB = maxSizeMB
        self.maxCount = maxCount
        self.imageMaxWidth = imageMaxWidth
        self.imageMaxHeight = imageMaxHeight
    }

    enum CodingKeys: String, CodingKey {
        case maxSize = "max_size"
        case maxCount = "max_count"
        case imageCompression = "image_compression"
    }

    private struct Compression: Decodable {
        let width: JSONValue?
        let height: JSONValue?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The admin UI stores these as numbers or numeric strings; empty means unset.
        func number(_ value: JSONValue?) -> Double? {
            switch value {
            case .number(let number)?: number > 0 ? number : nil
            case .string(let text)?: Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
            default: nil
            }
        }
        maxSizeMB = number(try? container.decodeIfPresent(JSONValue.self, forKey: .maxSize))
        maxCount = number(try? container.decodeIfPresent(JSONValue.self, forKey: .maxCount)).map { Int($0) }
        let compression = try? container.decodeIfPresent(Compression.self, forKey: .imageCompression)
        imageMaxWidth = number(compression?.width).map { Int($0) }
        imageMaxHeight = number(compression?.height).map { Int($0) }
    }
}

/// The admin-controlled `features` object of `/api/config`. Unknown keys are preserved in `raw`.
public struct ServerFeatures: Sendable, Equatable, Decodable {
    public let raw: [String: JSONValue]
    /// The code interpreter engine (`code.interpreter_engine`: `pyodide` or `jupyter`), when the
    /// Server reported it. `ServerConfig` fills it in; `nil` means unknown.
    public var codeInterpreterEngine: String?

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    /// The boolean flag `key` (e.g. `"enable_web_search"`). Missing or non-boolean values are `false`.
    public func isEnabled(_ key: String) -> Bool {
        raw[key]?.boolValue ?? false
    }

    /// `false` when the Server runs with `WEBUI_AUTH=false` (single-user mode).
    public var requiresAuth: Bool { raw["auth"]?.boolValue ?? true }
    public var allowsPasswordSignIn: Bool { raw["enable_login_form"]?.boolValue ?? true }
    public var allowsSignUp: Bool { isEnabled("enable_signup") }
    public var allowsLDAP: Bool { isEnabled("enable_ldap") }
    public var usesTrustedHeaderAuth: Bool { isEnabled("auth_trusted_header") }
    public var supportsWebSocket: Bool { isEnabled("enable_websocket") }

    /// Whether code the model writes can run for a native client (CONN-08). Pyodide runs in the
    /// web client's browser (`execute:python`), so only the server-side engine (Jupyter) counts.
    /// When the engine wasn't reported (unauthenticated or older config), the flags decide alone.
    public var runsCodeServerSide: Bool {
        guard let engine = codeInterpreterEngine?.lowercased(), !engine.isEmpty else { return true }
        return engine == "jupyter"
    }

    /// The consent text to show before web search, when the admin requires one
    /// (`enable_web_search_confirmation`, CONN-01).
    public var webSearchConfirmation: String? {
        guard isEnabled("enable_web_search_confirmation") else { return nil }
        let text = raw["web_search_confirmation_content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Your search will be sent to the web search provider this Server uses." : text
    }
}
