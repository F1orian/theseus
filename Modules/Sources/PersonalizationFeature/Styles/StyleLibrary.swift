public import Foundation
public import Observation
public import OpenWebUIKit

/// A writing Style for Responses (PERS-05, not in Open WebUI itself; ADR 0111): a preset or one the user
/// wrote. Its instructions go after the Profile Instructions in the system prompt.
public struct Style: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// The grey line under the name in Choose style.
    public let summary: String
    public let instructions: String
    public let isCustom: Bool

    /// Theseus's default: no extra instructions.
    public static let normal = Style(
        id: "normal", name: "Normal", summary: "Theseus’s default responses", instructions: "", isCustom: false
    )

    /// The presets, Normal first. Their ids are stored in `theseus.styles.selected`; never rename them.
    public static let presets: [Style] = [
        normal,
        Style(
            id: "concise", name: "Concise", summary: "Shorter answers that get to the point",
            instructions: "Keep responses brief and direct. Lead with the answer, skip preamble and repetition, and use short paragraphs or lists. Go into detail only when asked.",
            isCustom: false
        ),
        Style(
            id: "explanatory", name: "Explanatory", summary: "Thorough answers that explain the why",
            instructions: "Explain the reasoning and the ideas behind your answers. Define terms, give examples or analogies, and build up from the basics so the user understands, not just knows.",
            isCustom: false
        ),
        Style(
            id: "formal", name: "Formal", summary: "Clear, professional and well structured",
            instructions: "Write in a clear, professional register: complete sentences, precise wording and a logical structure, with headings or numbered points where they help. Avoid slang, emoji and casual asides.",
            isCustom: false
        ),
    ]

    public init(id: String, name: String, summary: String, instructions: String, isCustom: Bool) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.isCustom = isCustom
    }

    init(_ custom: CustomStyle) {
        let firstLine = custom.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        self.init(id: custom.id, name: custom.name, summary: firstLine, instructions: custom.instructions, isCustom: true)
    }

    /// Whether this Style changes the system prompt.
    public var isDefault: Bool { id == Style.normal.id }
}

/// The Account's Styles: the presets, the user's own, and the chosen one (PERS-05). Kept at
/// `theseus.styles` in the user settings (ADR 0111). Changes show at once and are written in the
/// background; a failed write puts the previous state back and says so.
@MainActor
@Observable
public final class StyleLibrary {
    public private(set) var preferences = StylePreferences()
    /// The last write that failed, for the Choose style page.
    public var errorMessage: String?
    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let makeID: @Sendable () -> String

    public init(client: OpenWebUIClient, makeID: @escaping @Sendable () -> String = { "style-" + UUID().uuidString.lowercased() }) {
        self.client = client
        self.makeID = makeID
    }

    /// Every Style: the presets, then the user's own.
    public var styles: [Style] {
        Style.presets + customStyles
    }

    public var customStyles: [Style] {
        preferences.custom.map(Style.init)
    }

    /// The chosen Style; Normal when none is, or the chosen one was deleted elsewhere.
    public var selected: Style {
        styles.first { $0.id == preferences.selected } ?? .normal
    }

    /// The instructions to add to the system prompt, `nil` for Normal.
    public var selectedInstructions: String? {
        let instructions = selected.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return instructions.isEmpty ? nil : instructions
    }

    /// Takes the Styles from freshly loaded user settings.
    public func apply(_ settings: UserSettings) {
        preferences = settings.stylePreferences
    }

    public func load() async {
        if let settings = try? await client.send(.userSettings) { apply(settings) }
    }

    public func select(_ style: Style) async {
        await write { $0.selected = style.isDefault ? nil : style.id }
    }

    /// Adds a new Style (`id` nil) or updates one; returns the saved Style's id.
    @discardableResult
    public func save(id: String?, name: String, instructions: String) async -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = id ?? makeID()
        await write { preferences in
            let style = CustomStyle(id: id, name: name, instructions: instructions)
            if let index = preferences.custom.firstIndex(where: { $0.id == id }) {
                preferences.custom[index] = style
            } else {
                preferences.custom.append(style)
            }
        }
        return id
    }

    /// Deletes one of the user's Styles; deleting the chosen one goes back to Normal.
    public func delete(_ id: String) async {
        await write { preferences in
            preferences.custom.removeAll { $0.id == id }
            if preferences.selected == id { preferences.selected = nil }
        }
    }

    /// Whether `name` and `instructions` make a Style that can be saved.
    public static func canSave(name: String, instructions: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func write(_ change: @escaping @Sendable (inout StylePreferences) -> Void) async {
        let previous = preferences
        change(&preferences)
        errorMessage = nil
        do {
            let stored = try await client.updateTheseusSettings { namespace in
                var styles = UserSettings(raw: [UserSettings.namespace: .object(namespace)]).stylePreferences
                change(&styles)
                if let json = try? styles.jsonValue() { namespace[StylePreferences.namespaceKey] = json }
            }
            preferences = stored.stylePreferences
        } catch {
            preferences = previous
            errorMessage = "Couldn’t save your style. \(error.message)"
        }
    }
}
