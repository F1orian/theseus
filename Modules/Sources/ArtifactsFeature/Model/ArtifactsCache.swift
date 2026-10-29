import ChatDomain
import ChatFeature
import Foundation

/// Remembers each Response's detected Artifacts, so transcript updates only re-detect the
/// Response that changed (usually the one streaming).
@MainActor
final class ArtifactsCache {
    static let shared = ArtifactsCache()

    private struct Entry {
        let response: ArtifactCatalog.Response
        let artifacts: [Artifact]
    }

    private var entries: [String: Entry] = [:]
    /// How many catalogs were built (for tests).
    private(set) var catalogBuilds = 0
    private let capacity: Int

    init(capacity: Int = 400) {
        self.capacity = capacity
    }

    func artifacts(for response: ArtifactCatalog.Response) -> [Artifact] {
        if let entry = entries[response.messageID], entry.response == response {
            return entry.artifacts
        }
        let artifacts = ArtifactDetector.artifacts(
            messageID: response.messageID,
            text: response.text,
            embeds: response.embeds,
            isStreaming: response.isStreaming
        )
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[response.messageID] = Entry(response: response, artifacts: artifacts)
        return artifacts
    }

    func hasEntry(for messageID: String) -> Bool {
        entries[messageID] != nil
    }

    /// What a catalog is built from: a Chat's active path and its live Responses.
    private struct CatalogInput: Equatable {
        let thread: [Message]
        let responses: [String: ResponseState]
        let streamingMessageID: String?
    }

    /// The last catalog built, for the many views that read the same one in a render pass
    /// (every Response's tool-embed cards, the header pill).
    private var latest: (input: CatalogInput, catalog: ArtifactCatalog)?

    /// The Artifacts on `model`'s active path. Reading it observes the thread and live Responses.
    /// Incognito chats are never cached, not even here (ADR 0070).
    func catalog(for model: ConversationModel) -> ArtifactCatalog {
        let input = CatalogInput(thread: model.thread, responses: model.responses, streamingMessageID: model.streamingMessageID)
        if !model.isIncognito, let latest, latest.input == input { return latest.catalog }
        catalogBuilds += 1
        let responses = ArtifactCatalog.responses(
            thread: input.thread,
            response: { model.response(for: $0) },
            streamingMessageID: input.streamingMessageID
        )
        if model.isIncognito { return ArtifactCatalog(responses: responses) }
        let catalog = ArtifactCatalog(responses: responses, detect: artifacts(for:))
        latest = (input, catalog)
        return catalog
    }
}
