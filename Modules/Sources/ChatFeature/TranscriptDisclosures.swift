public import Observation
public import SwiftUI

/// Which disclosures in a transcript are open (a Thinking step, a run of tool steps, the code of
/// a run, a run's output), kept by the screen rather than by the rows. Rows of older Messages are
/// built lazily and dropped once they're scrolled far away (#197), and a step the user opened must
/// still be open when they scroll back.
@MainActor
@Observable
public final class TranscriptDisclosures {
    private var open: Set<String> = []

    public init() {}

    public func isOpen(_ key: String) -> Bool {
        open.contains(key)
    }

    public func setOpen(_ key: String, _ isOpen: Bool) {
        if isOpen { open.insert(key) } else { open.remove(key) }
    }
}

extension EnvironmentValues {
    /// The transcript's disclosures; `nil` outside a transcript (previews, other screens).
    @Entry public var transcriptDisclosures: TranscriptDisclosures? = nil
    /// The Message whose row this is, which scopes its disclosure keys.
    @Entry public var transcriptRowID: String? = nil
}

/// A view's open-or-closed disclosures, by key: in the transcript's `TranscriptDisclosures` (scoped
/// to the row's Message) when there is one, else in the view's own state.
///
/// ```swift
/// private let disclosures = TranscriptDisclosureScope()
/// ...
/// DisclosureGroup("Output", isExpanded: disclosures.binding("output-\(run.id)")) { … }
/// ```
@MainActor
public struct TranscriptDisclosureScope: @MainActor DynamicProperty {
    @Environment(\.transcriptDisclosures) private var environmentStore
    @Environment(\.transcriptRowID) private var environmentRow
    @State private var local: Set<String> = []
    /// Read from the environment before each body, so actions and bindings (which run outside
    /// it, where the environment isn't available) use the same store.
    private var store: TranscriptDisclosures?
    private var row: String?

    public init() {}

    public mutating func update() {
        store = environmentStore
        row = environmentRow
    }

    public func isOpen(_ key: String) -> Bool {
        guard let store, let row else { return local.contains(key) }
        return store.isOpen("\(row)|\(key)")
    }

    public func setOpen(_ key: String, _ isOpen: Bool) {
        guard let store, let row else {
            if isOpen { local.insert(key) } else { local.remove(key) }
            return
        }
        store.setOpen("\(row)|\(key)", isOpen)
    }

    public func binding(_ key: String) -> Binding<Bool> {
        Binding { isOpen(key) } set: { setOpen(key, $0) }
    }
}
