import Foundation

/// Who shows a live Response's status, so it's shown once (#195): the step that's running is
/// either drawn **by** the tail mouse (a step row at the tail), or it shows the status itself and
/// the tail mouse goes without a plaque (a rich card, or a step that isn't the tail), or there's
/// no live step and the tail's plaque names the work (#173, #185).
///
/// ```swift
/// let live = LiveStep(parts: parts, activity: ResponseActivity(state)) { part in hasCustomView(part) }
/// ForEach(parts.filter { $0.id != live.absorbedPartID }) { … }   // the tail draws that one
/// WorkingIndicator(work: …, plaque: live.plaque(for: work))
/// ```
public enum LiveStep: Sendable, Hashable {
    /// No step is live (waiting for the first token, between parts, a stall, Your turn): the
    /// tail's plaque names the work.
    case none
    /// A live step row is the Response's tail: the tail mouse draws it, with the row's own title
    /// as its plaque and the row's details on tap. The row itself isn't drawn until it finishes.
    case row(partID: String, title: String)
    /// A live rich card (an Open Terminal run, a code run, a hook's view) or a live step that
    /// isn't the tail: it shows the status itself (without a spinner while the tail mouse
    /// works), and the tail mouse shows no plaque.
    case card(partID: String)

    /// - Parameters:
    ///   - parts: The parts as shown.
    ///   - activity: The Response's activity; only `.working` has a live step.
    ///   - isCard: Whether a part draws as a rich card (a hook's view) rather than a step row.
    public init(parts: [ResponsePart], activity: ResponseActivity, isCard: (ResponsePart) -> Bool) {
        guard case .working = activity, let last = parts.last else {
            self = .none
            return
        }
        if let index = Self.runningIndex(in: parts) {
            let part = parts[index]
            if index == parts.count - 1, !isCard(part), let title = Self.rowTitle(of: part) {
                self = .row(partID: part.id, title: title)
            } else {
                self = .card(partID: part.id)
            }
            return
        }
        if case .thinking(let id, _, _, true, _) = last {
            self = .row(partID: id, title: "Thinking")
            return
        }
        self = .none
    }

    /// The part the tail draws in place of its row.
    public var absorbedPartID: String? {
        if case .row(let id, _) = self { return id }
        return nil
    }

    /// Whether a step shows the status itself, so the tail mouse goes without a plaque.
    public var stepShowsStatus: Bool {
        if case .card = self { return true }
        return false
    }

    /// The tail's plaque for `work`: the absorbed row's title, nothing while a card shows the
    /// status, or the work's own plaque.
    public func plaque(for work: ResponseActivity.Work) -> String? {
        switch self {
        case .none: work.plaque
        case .row(_, let title): title.hasSuffix("…") ? title : title + "…"
        case .card: nil
        }
    }

    /// The latest running step (the one `ResponseActivity` names the work after).
    static func runningIndex(in parts: [ResponsePart]) -> Int? {
        parts.indices.reversed().first { index in
            switch parts[index] {
            case .tools(_, let tools):
                // (Clarifying questions never show as steps: they're cards, `.answers`.)
                return tools.contains(where: \.isRunning)
            case .code(_, let execution):
                let hasOutput = [execution.stdout, execution.result, execution.stderr].contains { !($0 ?? "").isEmpty }
                return execution.status?.isActive ?? !hasOutput
            case .status(_, let update):
                return !update.isDone
            case .thinking, .text, .answers:
                return false
            }
        }
    }

    /// The title a step row shows while it runs, or `nil` for a part that draws as a card.
    static func rowTitle(of part: ResponsePart) -> String? {
        switch part {
        case .tools(_, let tools): tools.last(where: \.isRunning)?.title
        case .status(_, let update): update.description
        case .thinking: "Thinking"
        case .code, .text, .answers: nil
        }
    }
}
