public import OpenWebUIKit

/// The Select model sheet's two lists (MODEL-01, MODEL-03): the primary models shown first and
/// the rest behind "More models".
///
/// Primary models are the user's pins (`ui.pinnedModels`), else the admin's pins
/// (`default_pinned_models`), in the admin's model order. Without pins, the first
/// `primaryLimit` models of the admin's order are primary (ADR 0041).
public struct ModelCatalog: Sendable, Equatable {
    public let primary: [Model]
    public let more: [Model]

    public static let primaryLimit = 4

    public init(models: [Model], pinnedIDs: [String], primaryLimit: Int = ModelCatalog.primaryLimit) {
        let pinned = Set(pinnedIDs)
        let pinnedModels = models.filter { pinned.contains($0.id) }
        if !pinnedModels.isEmpty {
            primary = pinnedModels
            more = models.filter { !pinned.contains($0.id) }
        } else {
            primary = Array(models.prefix(primaryLimit))
            more = Array(models.dropFirst(primaryLimit))
        }
    }

    public var all: [Model] { primary + more }

    public func contains(_ id: String?) -> Bool {
        guard let id else { return false }
        return all.contains { $0.id == id }
    }

    public func isInMore(_ id: String?) -> Bool {
        guard let id else { return false }
        return more.contains { $0.id == id }
    }
}

extension Model {
    /// The picker's one-line description: the admin's text, else what the model can do.
    public var pickerSubtitle: String? {
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        let traits: [(String, String)] = [
            ("vision", "Sees images"),
            ("file_upload", "Reads files"),
            ("web_search", "Searches the web"),
            ("code_interpreter", "Runs code"),
        ]
        let supported = traits.filter { capabilities.raw[$0.0] == true }.map(\.1)
        return supported.isEmpty ? nil : supported.joined(separator: " · ")
    }
}
