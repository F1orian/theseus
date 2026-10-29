/// The branching structure of a Chat's Messages.
///
/// Editing or retrying a Message adds a sibling (a Branch). `currentID` is the selected leaf, and
/// the visible thread (`activePath`) is the path from a root to that leaf. This mirrors Open
/// WebUI's `chat.history` (`messages` keyed by id, `currentId`).
public struct MessageTree: Sendable, Hashable {
    public enum Failure: Error, Sendable, Equatable {
        case unknownMessage(String)
        case duplicateMessage(String)
        case unknownParent(String)
    }

    /// One Branch among its siblings, for the "2 / 3" switcher. `index` is zero-based.
    public struct BranchPosition: Sendable, Hashable {
        public let index: Int
        public let count: Int

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }

        public var hasPrevious: Bool { index > 0 }
        public var hasNext: Bool { index < count - 1 }
    }

    public private(set) var messages: [String: Message]
    /// The selected leaf, or `nil` for an empty tree.
    public private(set) var currentID: String?
    /// Root Messages (no parent) in creation order. Editing the first Message creates a sibling root.
    public private(set) var rootIDs: [String]

    public init() {
        messages = [:]
        currentID = nil
        rootIDs = []
    }

    /// Builds a tree from server data, repairing what the server tolerates: child lists are
    /// rebuilt from `parentID` (keeping the given order, then creation order), Messages whose
    /// parent is missing become roots, and an unknown `currentID` falls back to the newest leaf.
    public init(messages list: [Message], currentID: String?) {
        var byID: [String: Message] = [:]
        for message in list where byID[message.id] == nil {
            byID[message.id] = message
        }
        for id in byID.keys {
            if let parentID = byID[id]?.parentID, byID[parentID] == nil {
                byID[id]?.parentID = nil
            }
        }
        var children: [String: [String]] = [:]
        for message in byID.values {
            if let parentID = message.parentID {
                children[parentID, default: []].append(message.id)
            }
        }
        for (parentID, actual) in children {
            guard let parent = byID[parentID] else { continue }
            let declared = parent.childIDs.filter(actual.contains)
            let missing = actual.filter { !declared.contains($0) }.sorted { Self.isOrdered(byID[$0], byID[$1]) }
            byID[parentID]?.childIDs = declared + missing
        }
        for id in byID.keys where children[id] == nil {
            byID[id]?.childIDs = []
        }

        messages = byID
        rootIDs = byID.values.filter { $0.parentID == nil }.sorted { Self.isOrdered($0, $1) }.map(\.id)
        if let currentID, byID[currentID] != nil {
            self.currentID = currentID
        } else if let newestRoot = rootIDs.last {
            self.currentID = Self.leaf(from: newestRoot, in: byID)
        } else {
            self.currentID = nil
        }
    }

    public var isEmpty: Bool { messages.isEmpty }

    public subscript(id: String) -> Message? { messages[id] }

    /// The visible thread: root → … → `currentID`.
    public var activePath: [Message] { path(to: currentID) }

    /// The Messages from a root down to `id` (inclusive); empty for `nil` or an unknown id.
    public func path(to id: String?) -> [Message] {
        var path: [Message] = []
        var cursor = id.flatMap { messages[$0] }
        var visited: Set<String> = []
        while let message = cursor, visited.insert(message.id).inserted {
            path.append(message)
            cursor = message.parentID.flatMap { messages[$0] }
        }
        return path.reversed()
    }

    /// The ids of `id` and its siblings, in Branch order.
    public func siblingIDs(of id: String) -> [String] {
        guard let message = messages[id] else { return [] }
        guard let parentID = message.parentID, let parent = messages[parentID] else { return rootIDs }
        return parent.childIDs
    }

    public func branchPosition(of id: String) -> BranchPosition? {
        let siblings = siblingIDs(of: id)
        guard let index = siblings.firstIndex(of: id) else { return nil }
        return BranchPosition(index: index, count: siblings.count)
    }

    /// The leaf reached from `id` by always following the newest child, as the web client does.
    public func leaf(from id: String) -> String? {
        guard messages[id] != nil else { return nil }
        return Self.leaf(from: id, in: messages)
    }

    /// Shows the Branch containing `id`: the active path becomes root → `id` → its newest leaf.
    public mutating func select(_ id: String) throws(Failure) {
        guard let leaf = leaf(from: id) else { throw .unknownMessage(id) }
        currentID = leaf
    }

    /// Moves the Branch at `id` by `offset` siblings (−1 = previous, +1 = next). Returns the newly
    /// shown sibling, or `nil` when there is none in that direction.
    @discardableResult
    public mutating func selectSibling(of id: String, offset: Int) throws(Failure) -> String? {
        guard messages[id] != nil else { throw .unknownMessage(id) }
        let siblings = siblingIDs(of: id)
        guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + offset) else { return nil }
        let target = siblings[index + offset]
        try select(target)
        return target
    }

    /// Adds `message` under its `parentID` (or as a new root) and makes it the current leaf.
    /// Adding a second child to a parent creates a new Branch.
    public mutating func append(_ message: Message) throws(Failure) {
        guard messages[message.id] == nil else { throw .duplicateMessage(message.id) }
        var message = message
        message.childIDs = []
        if let parentID = message.parentID {
            guard messages[parentID] != nil else { throw .unknownParent(parentID) }
            messages[parentID]?.childIDs.append(message.id)
        } else {
            rootIDs.append(message.id)
        }
        messages[message.id] = message
        currentID = message.id
    }

    /// Replaces the content of an existing Message (e.g. while a Response streams in).
    public mutating func update(_ id: String, _ change: (inout Message) -> Void) throws(Failure) {
        guard var message = messages[id] else { throw .unknownMessage(id) }
        let identity = (message.id, message.parentID, message.childIDs)
        change(&message)
        // Tree structure is owned by the tree; edits may only touch the payload.
        message.parentID = identity.1
        message.childIDs = identity.2
        messages[identity.0] = message
    }

    private static func leaf(from id: String, in messages: [String: Message]) -> String {
        var cursor = id
        var visited: Set<String> = [cursor]
        while let next = messages[cursor]?.childIDs.last, !visited.contains(next) {
            visited.insert(next)
            cursor = next
        }
        return cursor
    }

    private static func isOrdered(_ lhs: Message?, _ rhs: Message?) -> Bool {
        guard let lhs, let rhs else { return lhs != nil }
        return (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }
}
