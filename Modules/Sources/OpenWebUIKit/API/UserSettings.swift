import Foundation

/// The Account's free-form Open WebUI user settings (`GET /api/v1/users/user/settings`).
///
/// The web client keeps its own keys under `ui`. Theseus never writes those: everything that should
/// roam across a user's devices lives under the **`theseus`** top-level namespace (ADR 0010).
/// The server merges top-level keys on update, so writing only `theseus` can't clobber the web
/// client's settings. Use `OpenWebUIClient.updateTheseusSettings(_:)` to change it.
public struct UserSettings: Sendable, Equatable, Decodable {
    /// The top-level key Theseus owns.
    public static let namespace = "theseus"

    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        // Users who never saved settings get `null`.
        raw = try decoder.singleValueContainer().decode(JSONValue.self).objectValue ?? [:]
    }

    /// The `theseus` namespace (empty when nothing was written yet).
    public var theseus: [String: JSONValue] {
        raw[Self.namespace]?.objectValue ?? [:]
    }

    /// Decodes the value at `theseus.<key>` as `T`, or `nil` when missing or malformed.
    public func theseusValue<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let value = theseus[key], let data = try? WireCoding.encoder.encode(value) else { return nil }
        return try? WireCoding.decoder.decode(T.self, from: data)
    }

    /// Defaults for new Chats chosen on the Capabilities page (SET-05), stored at `theseus.capabilities`.
    public var capabilityDefaults: CapabilityDefaults {
        theseusValue(CapabilityDefaults.self, forKey: CapabilityDefaults.namespaceKey) ?? CapabilityDefaults()
    }

    /// Whether the user ever saved Capability defaults (otherwise each model's own defaults apply).
    public var hasCapabilityDefaults: Bool {
        theseus[CapabilityDefaults.namespaceKey] != nil
    }

    /// Model choices for new Chats (MODEL-04), stored at `theseus.models`.
    public var modelPreferences: ModelPreferences {
        theseusValue(ModelPreferences.self, forKey: ModelPreferences.namespaceKey) ?? ModelPreferences()
    }

    /// The web client's default model(s) for new chats (`ui.models`). Read-only for Theseus.
    public var webClientDefaultModelIDs: [String] {
        uiStrings("models")
    }

    /// The web client's pinned models (`ui.pinnedModels`). Read-only for Theseus.
    public var pinnedModelIDs: [String] {
        uiStrings("pinnedModels")
    }

    private func uiStrings(_ key: String) -> [String] {
        (raw["ui"]?[path: key]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
    }
}

/// Which model new Chats start with (MODEL-04), stored at `theseus.models` so it roams.
public struct ModelPreferences: Sendable, Equatable, Codable {
    public static let namespaceKey = "models"

    /// A fixed model for new Chats; `nil` means "the last model I used".
    public var defaultModelID: String?

    public init(defaultModelID: String? = nil) {
        self.defaultModelID = defaultModelID
    }

    public func jsonValue() throws -> JSONValue {
        try WireCoding.decoder.decode(JSONValue.self, from: WireCoding.encoder.encode(self))
    }
}

/// Which optional Capabilities new Chats start with (SET-05). Stored per Account in the user
/// settings at `theseus.capabilities` so the choice roams across devices. A Capability the
/// Server or the Account's permissions don't allow stays off regardless (ADR 0006).
public struct CapabilityDefaults: Sendable, Equatable, Codable {
    /// The key inside the `theseus` namespace.
    public static let namespaceKey = "capabilities"

    /// Show substantial content (documents, code, HTML, diagrams) as Artifacts. Client-side only.
    public var artifacts: Bool
    /// Let the model search the web (`features.web_search`).
    public var webSearch: Bool
    /// Let the model run code (`features.code_interpreter`).
    public var codeInterpreter: Bool
    /// Let the model create images (`features.image_generation`).
    public var imageGeneration: Bool
    /// Let the model use the Server's sandbox to run code and create files (`terminal_id`, #132).
    /// On unless the user turned it off (the Code execution switch).
    public var sandbox: Bool
    /// Ask before tools run (`params.tool_approval_mode: "ask"`, OT-06), where the Server allows it.
    public var askBeforeTools: Bool

    public init(
        artifacts: Bool = true,
        webSearch: Bool = false,
        codeInterpreter: Bool = false,
        imageGeneration: Bool = false,
        sandbox: Bool = true,
        askBeforeTools: Bool = false
    ) {
        self.artifacts = artifacts
        self.webSearch = webSearch
        self.codeInterpreter = codeInterpreter
        self.imageGeneration = imageGeneration
        self.sandbox = sandbox
        self.askBeforeTools = askBeforeTools
    }

    // Missing keys fall back to their default one by one, so older or partial values stay usable.
    public init(from decoder: any Decoder) throws {
        let defaults = CapabilityDefaults()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifacts = try container.decodeIfPresent(Bool.self, forKey: .artifacts) ?? defaults.artifacts
        webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch) ?? defaults.webSearch
        codeInterpreter = try container.decodeIfPresent(Bool.self, forKey: .codeInterpreter) ?? defaults.codeInterpreter
        imageGeneration = try container.decodeIfPresent(Bool.self, forKey: .imageGeneration) ?? defaults.imageGeneration
        sandbox = try container.decodeIfPresent(Bool.self, forKey: .sandbox) ?? defaults.sandbox
        askBeforeTools = try container.decodeIfPresent(Bool.self, forKey: .askBeforeTools) ?? defaults.askBeforeTools
    }

    /// The value as stored in the `theseus` namespace.
    public func jsonValue() throws -> JSONValue {
        try WireCoding.decoder.decode(JSONValue.self, from: WireCoding.encoder.encode(self))
    }
}

extension Endpoint where Response == UserSettings {
    /// `GET /api/v1/users/user/settings?raw=true`: the stored settings, without the admin's default
    /// interface settings merged in (so a write-back never persists those defaults).
    public static var userSettings: Self {
        Endpoint(
            method: .get,
            path: "api/v1/users/user/settings",
            query: [URLQueryItem(name: "raw", value: "true")],
            authentication: .required
        )
    }

    /// `POST /api/v1/users/user/settings/update` with only `{"theseus": namespace}`. The server
    /// merges top-level keys, so the web client's `ui` settings are left untouched. Prefer
    /// `OpenWebUIClient.updateTheseusSettings(_:)`, which reads the current namespace first.
    public static func updateTheseusSettings(_ namespace: [String: JSONValue]) -> Self {
        let body = try? WireCoding.encoder.encode(JSONValue.object([UserSettings.namespace: .object(namespace)]))
        return Endpoint(
            method: .post,
            path: "api/v1/users/user/settings/update",
            body: body ?? Data(),
            authentication: .required
        )
    }
}

extension OpenWebUIClient {
    /// Read-modify-write of the `theseus` namespace: fetches the current settings, applies
    /// `change` to the namespace and writes back only the namespace. Keys Theseus doesn't touch
    /// (inside or outside the namespace) survive. Returns the settings the server stored.
    @discardableResult
    public func updateTheseusSettings(
        _ change: @Sendable (inout [String: JSONValue]) -> Void
    ) async throws(OpenWebUIError) -> UserSettings {
        var namespace = try await send(.userSettings).theseus
        change(&namespace)
        return try await send(.updateTheseusSettings(namespace))
    }
}
