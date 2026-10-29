public import ChatDomain
public import Foundation

/// The Artifacts of one Chat's active path, with versions numbered (ART-03, ADR 0060): Artifacts
/// with the same kind and title are versions of one Artifact, counted in path order.
public struct ArtifactCatalog: Sendable, Hashable {
    /// One Response's input to the catalog.
    public struct Response: Sendable, Hashable {
        public let messageID: String
        public let text: String
        public let embeds: [String]
        public let isStreaming: Bool
        /// When the Response was written (for the library's sort order).
        public let date: Date
        /// The Response's tool steps: Claude's `artifacts` calls in imported Chats (#180).
        public let toolCalls: [ToolActivity]

        public init(
            messageID: String,
            text: String,
            embeds: [String] = [],
            isStreaming: Bool = false,
            date: Date = .distantPast,
            toolCalls: [ToolActivity] = []
        ) {
            self.messageID = messageID
            self.text = text
            self.embeds = embeds
            self.isStreaming = isStreaming
            self.date = date
            self.toolCalls = toolCalls
        }
    }

    /// Every Artifact on the path, in order (all versions).
    public let artifacts: [Artifact]
    /// When each Response was written, by Message id.
    public let dates: [String: Date]

    public init(artifacts: [Artifact], dates: [String: Date] = [:]) {
        var counts: [String: Int] = [:]
        self.artifacts = artifacts.map { artifact in
            var numbered = artifact
            counts[artifact.groupKey, default: 0] += 1
            numbered.version = counts[artifact.groupKey] ?? 1
            return numbered
        }
        self.dates = dates
    }

    /// Detects the Artifacts of `responses` (in path order) with `detect`, which may cache, then
    /// replays the `artifacts` tool calls of imported Chats across the path (#180).
    public init(
        responses: [Response],
        detect: (Response) -> [Artifact] = { response in
            ArtifactDetector.artifacts(messageID: response.messageID, text: response.text, embeds: response.embeds, isStreaming: response.isStreaming)
        }
    ) {
        let detected = responses.map(detect)
        var imported: [String: [Artifact]] = [:]
        if responses.contains(where: { $0.toolCalls.contains { $0.name == ToolActivity.artifactsName } }) {
            let counts = Dictionary(zip(responses.map(\.messageID), detected.map(\.count)), uniquingKeysWith: { first, _ in first })
            imported = ImportedArtifacts.resolve(responses) { counts[$0] ?? 0 }
        }
        self.init(
            artifacts: zip(responses, detected).flatMap { response, own in own + (imported[response.messageID] ?? []) },
            dates: Dictionary(responses.map { ($0.messageID, $0.date) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// The assistant Messages of an active path as catalog input. `response` supplies live
    /// (streaming) state where it differs from the stored Message.
    public static func responses(
        thread: [Message],
        response: (Message) -> ResponseState = { $0.response },
        streamingMessageID: String? = nil
    ) -> [Response] {
        thread.filter { $0.role == .assistant }.map { message in
            let state = response(message)
            return Response(
                messageID: message.id,
                text: state.text,
                embeds: state.embeds,
                isStreaming: message.id == streamingMessageID || !state.isFinished,
                date: message.createdAt,
                toolCalls: state.toolSteps(named: ToolActivity.artifactsName)
            )
        }
    }

    public var isEmpty: Bool { artifacts.isEmpty }
    /// What the "N artifacts" pill counts: every Artifact, all versions included.
    public var count: Int { artifacts.count }

    public func artifact(id: String) -> Artifact? {
        artifacts.first { $0.id == id }
    }

    /// All versions of `artifact`'s group, oldest first.
    public func versions(of artifact: Artifact) -> [Artifact] {
        let key = artifact.groupKey
        return artifacts.filter { $0.groupKey == key }
    }

    /// The newest version of each Artifact, newest Artifact first (the Chat's Artifacts list).
    public var latestVersions: [Artifact] {
        var seen: Set<String> = []
        var result: [Artifact] = []
        for artifact in artifacts.reversed() where seen.insert(artifact.groupKey).inserted {
            result.append(artifact)
        }
        return result
    }

    /// The Artifact an imported `artifacts` tool call of `messageID` wrote (#180).
    public func artifact(messageID: String, callID: String) -> Artifact? {
        artifacts.first { $0.messageID == messageID && $0.origin == .importedTool && $0.callID == callID }
    }

    /// The Artifact a rendered code block of `messageID` shows: the same code, else (while the
    /// text streams) the Response's open one of the same kind.
    public func artifact(messageID: String, language: String?, code: String) -> Artifact? {
        let candidates = artifacts.filter { $0.messageID == messageID && $0.origin == .codeBlock }
        if let exact = candidates.first(where: { $0.content == code }) { return exact }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.first { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
            ?? candidates.last { !$0.isComplete && ($0.content.hasPrefix(code) || code.hasPrefix($0.content)) }
    }
}
