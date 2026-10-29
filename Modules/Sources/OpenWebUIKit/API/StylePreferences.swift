import Foundation

/// Styles (PERS-05, not in Open WebUI itself; ADR 0111): the chosen Style and the user's own, stored at
/// `theseus.styles` so they roam across the Account's devices. The presets (Normal, Concise, …)
/// are client-side and never stored.
public struct StylePreferences: Sendable, Equatable, Codable {
    /// The key inside the `theseus` namespace.
    public static let namespaceKey = "styles"

    /// The chosen Style's id (a preset's or a custom one). `nil` is Normal.
    public var selected: String?
    /// Styles the user created, in the order they were added.
    public var custom: [CustomStyle]

    public init(selected: String? = nil, custom: [CustomStyle] = []) {
        self.selected = selected
        self.custom = custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selected = try container.decodeIfPresent(String.self, forKey: .selected)
        custom = (try? container.decodeIfPresent([CustomStyle].self, forKey: .custom)) ?? []
    }

    /// The value as stored in the `theseus` namespace.
    public func jsonValue() throws -> JSONValue {
        try WireCoding.decoder.decode(JSONValue.self, from: WireCoding.encoder.encode(self))
    }
}

/// A Style the user wrote: a name and the instructions added to the system prompt.
public struct CustomStyle: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var instructions: String

    public init(id: String, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }
}

extension UserSettings {
    /// Styles at `theseus.styles` (PERS-05); defaults when missing or malformed.
    public var stylePreferences: StylePreferences {
        theseusValue(StylePreferences.self, forKey: StylePreferences.namespaceKey) ?? StylePreferences()
    }
}
