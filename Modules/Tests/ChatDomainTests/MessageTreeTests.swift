import ChatDomain
import Foundation
import Testing

/// Builds Messages with increasing timestamps so creation order is deterministic.
private func message(
    _ id: String,
    parent: String?,
    children: [String] = [],
    role: Message.Role = .user,
    at second: TimeInterval
) -> Message {
    Message(
        id: id,
        parentID: parent,
        childIDs: children,
        role: role,
        content: "content of \(id)",
        createdAt: Date(timeIntervalSince1970: second)
    )
}

/// ```
/// u1 ─ a1 ─ u2 ─ a2
///    └ a1b         (retry of a1)
/// u1b              (edit of the first message: a sibling root)
/// ```
private func sampleTree(currentID: String? = "a2") -> MessageTree {
    MessageTree(
        messages: [
            message("u1", parent: nil, children: ["a1", "a1b"], at: 1),
            message("a1", parent: "u1", children: ["u2"], role: .assistant, at: 2),
            message("u2", parent: "a1", children: ["a2"], at: 3),
            message("a2", parent: "u2", role: .assistant, at: 4),
            message("a1b", parent: "u1", role: .assistant, at: 5),
            message("u1b", parent: nil, at: 6),
        ],
        currentID: currentID
    )
}

@Suite("MessageTree")
struct MessageTreeTests {
    @Test func emptyTree() {
        let tree = MessageTree()
        #expect(tree.isEmpty)
        #expect(tree.currentID == nil)
        #expect(tree.activePath.isEmpty)
    }

    @Test func activePathRunsFromRootToCurrentLeaf() {
        #expect(sampleTree().activePath.map(\.id) == ["u1", "a1", "u2", "a2"])
    }

    @Test func pathToAnyMessage() {
        let tree = sampleTree()
        #expect(tree.path(to: "u2").map(\.id) == ["u1", "a1", "u2"])
        #expect(tree.path(to: "a1b").map(\.id) == ["u1", "a1b"])
        #expect(tree.path(to: nil).isEmpty)
        #expect(tree.path(to: "nope").isEmpty)
    }

    @Test func annotationIsPayload() throws {
        var tree = sampleTree()
        try tree.update("a2") { $0.annotation = MessageAnnotation(rating: .bad, comment: "Too long") }
        #expect(tree["a2"]?.annotation?.rating == .bad)
        #expect(MessageAnnotation.Rating.good.rawValue == 1)
    }

    @Test func branchPositions() {
        let tree = sampleTree()
        #expect(tree.branchPosition(of: "a1") == .init(index: 0, count: 2))
        #expect(tree.branchPosition(of: "a1b") == .init(index: 1, count: 2))
        #expect(tree.branchPosition(of: "u2") == .init(index: 0, count: 1))
        #expect(tree.branchPosition(of: "u1b") == .init(index: 1, count: 2), "roots are siblings")
        #expect(tree.branchPosition(of: "missing") == nil)
        let first = tree.branchPosition(of: "a1")
        #expect(first?.hasPrevious == false)
        #expect(first?.hasNext == true)
    }

    @Test func selectingASiblingShowsItsNewestLeaf() throws {
        var tree = sampleTree()
        let shown = try tree.selectSibling(of: "a1", offset: 1)
        #expect(shown == "a1b")
        #expect(tree.activePath.map(\.id) == ["u1", "a1b"])

        try tree.selectSibling(of: "a1b", offset: -1)
        #expect(tree.activePath.map(\.id) == ["u1", "a1", "u2", "a2"], "follows the newest child down")
    }

    @Test func selectingPastTheEndIsANoOp() throws {
        var tree = sampleTree()
        #expect(try tree.selectSibling(of: "a1", offset: -1) == nil)
        #expect(tree.currentID == "a2")
    }

    @Test func switchingRootBranch() throws {
        var tree = sampleTree()
        try tree.selectSibling(of: "u1", offset: 1)
        #expect(tree.activePath.map(\.id) == ["u1b"])
    }

    @Test func selectingUnknownMessageThrows() {
        var tree = sampleTree()
        #expect(throws: MessageTree.Failure.unknownMessage("nope")) { try tree.select("nope") }
        #expect(throws: MessageTree.Failure.unknownMessage("nope")) { try tree.selectSibling(of: "nope", offset: 1) }
    }

    @Test func appendingExtendsThePathAndCreatesBranches() throws {
        var tree = sampleTree()
        try tree.append(message("u3", parent: "a2", at: 7))
        #expect(tree.currentID == "u3")
        #expect(tree.activePath.last?.id == "u3")

        // Retrying a2's parent turn: a second child of u2 is a new Branch, shown immediately.
        try tree.append(message("a2b", parent: "u2", role: .assistant, at: 8))
        #expect(tree.branchPosition(of: "a2b") == .init(index: 1, count: 2))
        #expect(tree.activePath.map(\.id) == ["u1", "a1", "u2", "a2b"])
    }

    @Test func appendingValidates() {
        var tree = sampleTree()
        #expect(throws: MessageTree.Failure.duplicateMessage("a1")) { try tree.append(message("a1", parent: "u1", at: 9)) }
        #expect(throws: MessageTree.Failure.unknownParent("ghost")) { try tree.append(message("x", parent: "ghost", at: 9)) }
    }

    @Test func appendingIgnoresCallerSuppliedChildren() throws {
        var tree = MessageTree()
        try tree.append(message("r", parent: nil, children: ["bogus"], at: 1))
        #expect(tree["r"]?.childIDs == [])
        #expect(tree.rootIDs == ["r"])
    }

    @Test func updateChangesPayloadButNotStructure() throws {
        var tree = sampleTree()
        try tree.update("a2") { message in
            message.content = "streamed"
            message.isDone = false
            message.parentID = "hijack"
            message.childIDs = ["x"]
        }
        #expect(tree["a2"]?.content == "streamed")
        #expect(tree["a2"]?.isDone == false)
        #expect(tree["a2"]?.parentID == "u2")
        #expect(tree["a2"]?.childIDs == [])
    }

    @Test func unknownCurrentIDFallsBackToNewestLeaf() {
        #expect(sampleTree(currentID: "missing").currentID == "u1b")
        #expect(sampleTree(currentID: nil).currentID == "u1b")
    }

    @Test func repairsInconsistentServerData() {
        let tree = MessageTree(
            messages: [
                // Parent lists a missing child and omits a real one.
                message("p", parent: nil, children: ["ghost", "c2"], at: 1),
                message("c1", parent: "p", at: 2),
                message("c2", parent: "p", at: 3),
                // Orphan: its parent is missing, so it becomes a root.
                message("orphan", parent: "deleted", at: 4),
                // Duplicate ids: the first wins.
                message("c1", parent: nil, at: 9),
            ],
            currentID: "c1"
        )
        #expect(tree["p"]?.childIDs == ["c2", "c1"], "declared order first, then creation order")
        #expect(tree.rootIDs == ["p", "orphan"])
        #expect(tree["orphan"]?.parentID == nil)
        #expect(tree.activePath.map(\.id) == ["p", "c1"])
    }

    @Test func cyclicDataDoesNotHang() {
        let tree = MessageTree(
            messages: [
                message("a", parent: "b", children: ["b"], at: 1),
                message("b", parent: "a", children: ["a"], at: 2),
            ],
            currentID: "a"
        )
        #expect(tree.activePath.count <= 2)
        #expect(tree.leaf(from: "a") != nil)
    }
}

@Suite("ChatSummary")
struct ChatSummaryTests {
    @Test func unreadWhenUpdatedAfterLastRead() {
        let read = Date(timeIntervalSince1970: 100)
        var summary = ChatSummary(id: "c", title: "T", createdAt: read, updatedAt: read, lastReadAt: read)
        #expect(!summary.isUnread)
        summary.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(summary.isUnread)
        summary.lastReadAt = nil
        #expect(!summary.isUnread)
    }
}
