import ChatDomain
import Foundation

/// Artifacts written by Claude's `artifacts` tool, in Chats imported from Claude (#180). The
/// import keeps each call as a serialized tool step (`SerializedContent`); its arguments say what
/// happened:
///
/// - `create`: `id`, `type` (a MIME type), `title`, `language`, the full `content`;
/// - `update`: `id`, `old_str` → `new_str`, an edit of the latest version;
/// - `rewrite`: `id`, the full new `content` (and optionally a new `title`/`type`).
///
/// Every call is one version. Versions are rebuilt in path order: an edit whose `old_str` isn't in
/// the latest version keeps that version's content and is marked stale, never dropped.
enum ImportedArtifacts {
    /// One call's arguments.
    struct Command: Sendable, Hashable {
        enum Action: String, Sendable { case create, update, rewrite }

        let action: Action
        let identifier: String
        let type: String?
        let title: String?
        let language: String?
        let content: String?
        let oldString: String?
        let newString: String?

        /// `nil` when `step` isn't an `artifacts` call or its arguments can't be read.
        init?(_ step: ToolActivity) {
            guard step.name == ToolActivity.artifactsName,
                  let data = step.arguments.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let action = (object["command"] as? String).flatMap(Action.init(rawValue:)),
                  let identifier = object["id"] as? String, !identifier.isEmpty
            else { return nil }
            func string(_ key: String) -> String? { object[key] as? String }
            self.action = action
            self.identifier = identifier
            type = string("type")
            title = string("title")
            language = string("language")
            content = string("content")
            oldString = string("old_str")
            newString = string("new_str")
        }
    }

    /// The latest state of one Artifact while the path is replayed.
    private struct Current {
        var kind: Artifact.Kind
        var title: String
        var language: String?
        var content: String
    }

    /// The Artifacts the `artifacts` calls of `responses` (in path order) wrote, by Message id.
    /// `firstIndex` gives where each Response's imported Artifacts start (after its own).
    static func resolve(_ responses: [ArtifactCatalog.Response], firstIndex: (String) -> Int) -> [String: [Artifact]] {
        var current: [String: Current] = [:]
        var result: [String: [Artifact]] = [:]
        for response in responses {
            var index = firstIndex(response.messageID)
            for step in response.toolCalls {
                guard let command = Command(step) else { continue }
                var stale = false
                var state: Current
                switch command.action {
                case .create:
                    state = Current(
                        kind: kind(type: command.type, language: command.language, content: command.content ?? ""),
                        title: command.title.flatMap(nonEmpty) ?? "Artifact",
                        language: language(type: command.type, language: command.language),
                        content: command.content ?? ""
                    )
                case .rewrite:
                    let previous = current[command.identifier]
                    let content = command.content ?? previous?.content ?? ""
                    state = Current(
                        kind: command.type.map { kind(type: $0, language: command.language, content: content) } ?? previous?.kind
                            ?? kind(type: nil, language: command.language, content: content),
                        title: command.title.flatMap(nonEmpty) ?? previous?.title ?? "Artifact",
                        language: command.type.map { language(type: $0, language: command.language) } ?? command.language ?? previous?.language,
                        content: content
                    )
                case .update:
                    // An edit of an Artifact this path never created (e.g. made on another Branch)
                    // has nothing to apply to.
                    guard var previous = current[command.identifier] else { continue }
                    if let old = command.oldString, !old.isEmpty, let range = previous.content.range(of: old) {
                        previous.content.replaceSubrange(range, with: command.newString ?? "")
                    } else {
                        stale = true
                    }
                    if let title = command.title.flatMap(nonEmpty) { previous.title = title }
                    state = previous
                }
                current[command.identifier] = state
                result[response.messageID, default: []].append(Artifact(
                    messageID: response.messageID,
                    index: index,
                    kind: state.kind,
                    origin: .importedTool,
                    language: state.language,
                    title: state.title,
                    content: state.content,
                    isComplete: !step.isRunning,
                    identifier: command.identifier,
                    callID: step.id,
                    isStale: stale
                ))
                index += 1
            }
        }
        return result
    }

    /// The Artifact kind for Claude's MIME types.
    static func kind(type: String?, language: String?, content: String) -> Artifact.Kind {
        switch type?.lowercased() {
        case "text/html": .webPage
        case "image/svg+xml": .image
        case "application/vnd.ant.mermaid": .diagram
        case "application/vnd.ant.react": .component
        case "text/markdown": .document
        case "application/vnd.ant.code": .code
        default:
            // No type: judge by the language, else treat it as text.
            language.flatMap { ArtifactDetector.candidateKind(language: $0) } ?? (language == nil ? .document : .code)
        }
    }

    /// The fence language matching the Artifact (for the code view and sharing).
    static func language(type: String?, language: String?) -> String? {
        switch type?.lowercased() {
        case "text/html": "html"
        case "image/svg+xml": "svg"
        case "application/vnd.ant.mermaid": "mermaid"
        case "application/vnd.ant.react": language ?? "jsx"
        case "text/markdown": "markdown"
        default: language
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
