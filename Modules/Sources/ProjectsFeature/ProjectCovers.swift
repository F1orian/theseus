public import ArtCollection
public import Foundation
public import Observation

/// Each Project's cover from The Collection (brand.md §4, BRAND-04). The default is
/// `Artwork.projectCover(for:)`, deterministic from the Project id; "Change cover" picks another
/// `project-cover` work. Open WebUI folders have no field for it, so the choice stays on this
/// device, per Account and Project id, and is never written to the Server.
@MainActor
@Observable
public final class ProjectCovers {
    /// Chosen covers: Project id → artwork id. Only choices that differ from the default.
    private var chosen: [String: String]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String

    /// - Parameters:
    ///   - accountKey: Separates the Accounts on this device.
    ///   - defaults: Where choices persist; `nil` keeps them in memory (tests, previews).
    public init(accountKey: String = "", defaults: UserDefaults? = nil) {
        key = "theseus.projectCovers.\(accountKey)"
        self.defaults = defaults
        chosen = defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// The works a cover can be chosen from, in catalog order.
    public var choices: [Artwork] { Artwork.projectCovers }

    /// The Project's cover: the chosen work, or the deterministic default.
    public func cover(for projectID: String) -> Artwork {
        if let id = chosen[projectID], let artwork = choices.first(where: { $0.id == id }) {
            return artwork
        }
        return Artwork.projectCover(for: projectID)
    }

    /// Whether the Project shows a chosen cover rather than its default.
    public func isChosen(for projectID: String) -> Bool {
        chosen[projectID].map { id in choices.contains { $0.id == id } } ?? false
    }

    /// Picks `artwork` as the Project's cover. Picking the default (or a work that isn't a
    /// `project-cover`) clears the choice, so the default keeps following the id.
    public func setCover(_ artwork: Artwork, for projectID: String) {
        if artwork == Artwork.projectCover(for: projectID) || !choices.contains(artwork) {
            chosen[projectID] = nil
        } else {
            chosen[projectID] = artwork.id
        }
        save()
    }

    /// Forgets a deleted Project's choice.
    public func forget(_ projectID: String) {
        guard chosen.removeValue(forKey: projectID) != nil else { return }
        save()
    }

    private func save() {
        guard let defaults else { return }
        if chosen.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(chosen, forKey: key)
        }
    }
}
