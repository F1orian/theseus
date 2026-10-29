import ChatDomain
import Foundation

/// One entry of the model picker (`GET /api/models` → `data[]`, `B/utils/models.py`).
public struct Model: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// `"openai"`, `"ollama"` or `"arena"`.
    public let ownedBy: String?
    public let description: String?
    public let tags: [String]
    public let capabilities: ModelCapabilities
    /// Feature toggles that start switched on for this model (e.g. `["web_search"]`).
    public let defaultFeatureIDs: [String]
    /// Hidden by the admin (`info.meta.hidden`): keep out of the picker.
    public let isHidden: Bool
    /// Admin-approved option menus (`info.params.model_controls`), in the admin's order.
    public var controls: [ModelControl] = []
    /// Connectors the model preset enables by default (`info.meta.toolIds`, CONN-02).
    public var toolIDs: [String] = []
    /// The terminal server that backs this model's sandbox by default (`info.meta.terminalId`,
    /// Open Terminal, #132). Clients send it as `terminal_id`; the server never applies it itself.
    public var terminalID: String?

    public init(
        id: String,
        name: String,
        ownedBy: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        capabilities: ModelCapabilities = ModelCapabilities(raw: [:]),
        defaultFeatureIDs: [String] = [],
        isHidden: Bool = false,
        controls: [ModelControl] = []
    ) {
        self.id = id
        self.name = name
        self.ownedBy = ownedBy
        self.description = description
        self.tags = tags
        self.capabilities = capabilities
        self.defaultFeatureIDs = defaultFeatureIDs
        self.isHidden = isHidden
        self.controls = controls
    }

    /// Served through an OpenAI-compatible connection, which accepts `reasoning_effort`.
    public var isOpenAICompatible: Bool { ownedBy == "openai" }
}

/// One admin-defined control of a model (`ModelControl` in `B/models/models.py`): a labelled menu
/// or slider whose options the server expands into request parameters. The client only ever
/// sends option keys (`params.model_controls = {model_id: {control_id: option_id}}`).
public struct ModelControl: Sendable, Equatable, Identifiable {
    public enum Display: String, Sendable, Equatable {
        case menu
        case slider
    }

    public struct Option: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let id: String
    public let label: String
    public let description: String?
    /// The option the server applies when the client sends none.
    public let defaultOptionID: String?
    public let display: Display
    /// In the admin's order.
    public let options: [Option]

    public init(id: String, label: String, description: String? = nil, defaultOptionID: String? = nil, display: Display = .menu, options: [Option]) {
        self.id = id
        self.label = label
        self.description = description
        self.defaultOptionID = defaultOptionID
        self.display = display
        self.options = options
    }

    public func option(id: String?) -> Option? {
        guard let id else { return nil }
        return options.first { $0.id == id }
    }
}

/// `info.meta.capabilities`. The web client treats a **missing key as supported**
/// (`capabilities?.vision ?? true`), and so does `supports(_:)`.
public struct ModelCapabilities: Sendable, Equatable {
    public let raw: [String: Bool]

    public init(raw: [String: Bool]) {
        self.raw = raw
    }

    public func supports(_ key: String) -> Bool {
        raw[key] ?? true
    }
}

extension Model: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, tags, info
        case ownedBy = "owned_by"
    }

    private struct Tag: Decodable { let name: String }
    private struct Info: Decodable {
        let meta: Meta?
        let params: Params?
    }
    private struct Meta: Decodable {
        let description: String?
        let capabilities: [String: JSONValue]?
        let hidden: Bool?
        let defaultFeatureIds: [String]?
        let toolIds: [String]?
        let terminalId: String?
    }
    private struct Params: Decodable {
        let modelControls: [String: ControlWire]?
        enum CodingKeys: String, CodingKey { case modelControls = "model_controls" }
    }
    private struct ControlWire: Decodable {
        let label: String?
        let description: String?
        let `default`: String?
        let display: String?
        let options: [String: OptionWire]?
    }
    private struct OptionWire: Decodable { let label: String? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = ServerDisplay.modelName(id: id, name: try container.decodeIfPresent(String.self, forKey: .name) ?? id)
        ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
        tags = (try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []).map(\.name)
        let info = try? container.decodeIfPresent(Info.self, forKey: .info)
        let meta = info?.meta
        description = meta?.description
        capabilities = ModelCapabilities(raw: (meta?.capabilities ?? [:]).compactMapValues(\.boolValue))
        defaultFeatureIDs = meta?.defaultFeatureIds ?? []
        isHidden = meta?.hidden ?? false
        toolIDs = meta?.toolIds ?? []
        terminalID = meta?.terminalId.flatMap { $0.isEmpty ? nil : $0 }
        // Key order is restored by `ModelList` from the raw document; sort for determinism here.
        controls = (info?.params?.modelControls ?? [:]).sorted { $0.key < $1.key }.compactMap { key, wire in
            let options = (wire.options ?? [:]).sorted { $0.key < $1.key }.map { optionKey, option in
                ModelControl.Option(id: optionKey, label: option.label ?? optionKey)
            }
            guard !options.isEmpty else { return nil }
            return ModelControl(
                id: key,
                label: wire.label ?? key,
                description: wire.description,
                defaultOptionID: wire.default,
                display: ModelControl.Display(rawValue: wire.display ?? "menu") ?? .menu,
                options: options
            )
        }
    }

    /// Puts controls and their options back into the admin's order.
    func orderingControls(by order: JSONKeyOrder, index: Int) -> Model {
        guard !controls.isEmpty else { return self }
        let base: [JSONKeyOrder.PathComponent] = ["data", .index(index), "info", "params", "model_controls"]
        let controlOrder = order.keys(at: base)
        var copy = self
        copy.controls = controls
            .sorted { (controlOrder.firstIndex(of: $0.id) ?? .max) < (controlOrder.firstIndex(of: $1.id) ?? .max) }
            .map { control in
                let optionOrder = order.keys(at: base + [.key(control.id), "options"])
                let options = control.options.sorted {
                    (optionOrder.firstIndex(of: $0.id) ?? .max) < (optionOrder.firstIndex(of: $1.id) ?? .max)
                }
                return ModelControl(
                    id: control.id,
                    label: control.label,
                    description: control.description,
                    defaultOptionID: control.defaultOptionID,
                    display: control.display,
                    options: options
                )
            }
        return copy
    }
}

/// `{"data": [Model]}`.
struct ModelList: Decodable {
    let data: [Model]

    /// Decodes the list and restores the admin's order of model controls.
    static func decode(_ data: Data) throws -> [Model] {
        let models = try WireCoding.decoder.decode(ModelList.self, from: data).data
        guard models.contains(where: { !$0.controls.isEmpty }), let order = JSONKeyOrder(data) else { return models }
        return models.enumerated().map { index, model in model.orderingControls(by: order, index: index) }
    }
}
