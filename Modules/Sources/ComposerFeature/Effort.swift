public import OpenWebUIKit

/// How a model's Effort is offered and sent (MODEL-02, ADR 0040).
///
/// 1. **Admin model controls** (`info.params.model_controls`) win: an effort-like control becomes
///    the Effort list, an on/off "thinking" control becomes the Thinking switch, and any other
///    controls are offered as extra option lists. Picks go out as `params.model_controls`.
///    Needs the `modelControls` Capability (`chat.controls` + `chat.params`).
/// 2. Otherwise, on OpenAI-compatible connections, with the `modelParams` Capability
///    (`chat.params`), Effort maps to `params.reasoning_effort`: Default (not sent), Low, Medium, High.
/// 3. Otherwise there is no Effort: the row, the switch and the chip suffix are hidden.
public struct EffortConfiguration: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case modelControls
        case reasoningEffort
    }

    public struct Level: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let detail: String?
    }

    public let source: Source
    /// The control the Effort list writes (`reasoning_effort` for the fallback).
    public let effortKey: String?
    public let levels: [Level]
    /// The level used when the user picked none.
    public let defaultLevelID: String?
    /// An on/off control shown as the Thinking switch.
    public let thinking: ModelControl?
    /// Further admin controls, each shown as its own option list.
    public let extras: [ModelControl]

    /// The `reasoning_effort` key and its levels.
    public static let reasoningEffortKey = "reasoning_effort"
    static let reasoningDefault = "default"

    /// The Effort list for `model`, or `nil` when it has none (ADR 0040).
    public static func resolve(for model: Model, capabilities: Capabilities) -> EffortConfiguration? {
        if !model.controls.isEmpty, capabilities.contains(.modelControls) {
            return fromControls(model.controls)
        }
        if model.isOpenAICompatible, capabilities.contains(.modelParams) {
            return EffortConfiguration(
                source: .reasoningEffort,
                effortKey: reasoningEffortKey,
                levels: [
                    Level(id: reasoningDefault, label: "Default", detail: "The model's own setting"),
                    Level(id: "low", label: "Low", detail: "Fast answers to simple questions"),
                    Level(id: "medium", label: "Medium", detail: "A balance of speed and depth"),
                    Level(id: "high", label: "High", detail: "Thorough work on hard problems"),
                ],
                defaultLevelID: reasoningDefault,
                thinking: nil,
                extras: []
            )
        }
        return nil
    }

    private static func fromControls(_ controls: [ModelControl]) -> EffortConfiguration? {
        let effort = controls.first { $0.matches(["effort", "reasoning"]) }
            ?? controls.first { $0.matches(["think"]) && $0.options.count > 2 }
            ?? controls.first { $0.looksLikeLevels }
        let thinking = controls.first { $0.id != effort?.id && $0.isSwitch && $0.matches(["think", "extended", "reason"]) }
        let extras = controls.filter { $0.id != effort?.id && $0.id != thinking?.id }
        guard effort != nil || thinking != nil || !extras.isEmpty else { return nil }
        return EffortConfiguration(
            source: .modelControls,
            effortKey: effort?.id,
            levels: effort?.options.map { Level(id: $0.id, label: $0.label, detail: nil) } ?? [],
            defaultLevelID: effort?.defaultOptionID,
            thinking: thinking,
            extras: extras
        )
    }

    public var hasEffortLevels: Bool { !levels.isEmpty }

    /// The current level: the user's pick, else the default.
    public func level(in selection: EffortSelection) -> Level? {
        guard let effortKey else { return nil }
        let id = selection.picks[effortKey] ?? defaultLevelID
        return levels.first { $0.id == id }
    }

    /// The chip's suffix ("Low"), or `nil` when there's nothing worth showing.
    public func chipLabel(for selection: EffortSelection) -> String? {
        guard let level = level(in: selection) else { return nil }
        if source == .reasoningEffort, level.id == Self.reasoningDefault { return nil }
        return level.label
    }

    public func isThinkingOn(in selection: EffortSelection) -> Bool {
        guard let thinking, let id = selection.picks[thinking.id] ?? thinking.defaultOptionID else { return false }
        return id == thinking.onOption?.id
    }

    /// The request parameters for the selection (`params`).
    public func params(for selection: EffortSelection, modelID: String) -> [String: JSONValue] {
        switch source {
        case .reasoningEffort:
            guard let level = level(in: selection), level.id != Self.reasoningDefault else { return [:] }
            return [Self.reasoningEffortKey: .string(level.id)]
        case .modelControls:
            let known = Set([effortKey, thinking?.id].compactMap { $0 } + extras.map(\.id))
            let picks = selection.picks.filter { known.contains($0.key) }
            guard !picks.isEmpty else { return [:] }
            return ["model_controls": .object([modelID: .object(picks.mapValues(JSONValue.string))])]
        }
    }
}

/// The user's Effort picks for one model: control id → option id (`reasoning_effort` → level).
public struct EffortSelection: Sendable, Equatable, Codable {
    public var picks: [String: String]

    public init(picks: [String: String] = [:]) {
        self.picks = picks
    }
}

extension ModelControl {
    fileprivate func matches(_ words: [String]) -> Bool {
        let haystack = (id + " " + label).lowercased()
        return words.contains { haystack.contains($0) }
    }

    /// Two options, one of which means "off".
    var isSwitch: Bool {
        options.count == 2 && offOption != nil
    }

    var offOption: Option? {
        options.first { option in
            ["off", "none", "disabled", "false", "no"].contains(option.id.lowercased())
                || ["off", "none", "disabled", "no"].contains(option.label.lowercased())
        }
    }

    var onOption: Option? {
        guard let off = offOption else { return nil }
        return options.first { $0.id != off.id }
    }

    /// Options named like reasoning levels (low / medium / high …).
    fileprivate var looksLikeLevels: Bool {
        let levelWords = ["minimal", "low", "medium", "high", "max", "xhigh"]
        let hits = options.filter { option in
            levelWords.contains(option.id.lowercased()) || levelWords.contains(option.label.lowercased())
        }
        return hits.count >= 2
    }
}
