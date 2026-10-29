import Foundation

/// Substantial standalone content in a Response (a web page, image, diagram, component or document)
/// that opens in its own viewer (ADR 0060). Theseus finds Artifacts in the Response itself; Open
/// WebUI has no Artifact object.
public struct Artifact: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        /// HTML, run live in the sandboxed viewer.
        case webPage
        /// SVG.
        case image
        /// Mermaid.
        case diagram
        /// React / JSX: shown as source (no bundled runtime, ADR 0060).
        case component
        /// A markdown document.
        case document
        /// Source code in any language, shown as code (Claude's code Artifacts, in imported Chats).
        case code
    }

    /// Where the Artifact came from.
    public enum Origin: String, Sendable, Hashable, Codable {
        /// A fenced code block in the Response text.
        case codeBlock
        /// An HTML view a tool attached to the Response (`message.embeds`).
        case toolEmbed
        /// A call of Claude's `artifacts` tool, in Chats imported from Claude (#180).
        case importedTool
    }

    /// `<message id>/<index>`: stable while the Response grows.
    public let id: String
    /// The assistant Message holding the Artifact.
    public let messageID: String
    /// Position among the Response's Artifacts (code blocks first, then tool embeds).
    public let index: Int
    public let kind: Kind
    public let origin: Origin
    /// The fence's language, as written.
    public let language: String?
    public let title: String
    public let content: String
    /// `false` while the Response is still writing it (an open fence).
    public let isComplete: Bool
    /// 1-based version among Artifacts with the same `groupKey` on the Chat's active path (ART-03).
    public internal(set) var version: Int = 1
    /// The Artifact's own identifier, when its source names one (Claude's `artifacts` tool):
    /// versions are grouped by it instead of by title.
    public let identifier: String?
    /// The tool call that wrote this version (imported Artifacts), to place its card.
    public let callID: String?
    /// An edit of this version couldn't be applied, so the content is the last one Theseus could
    /// rebuild (imported Artifacts).
    public let isStale: Bool

    public init(
        messageID: String,
        index: Int,
        kind: Kind,
        origin: Origin = .codeBlock,
        language: String?,
        title: String,
        content: String,
        isComplete: Bool = true,
        identifier: String? = nil,
        callID: String? = nil,
        isStale: Bool = false
    ) {
        id = "\(messageID)/\(index)"
        self.messageID = messageID
        self.index = index
        self.kind = kind
        self.origin = origin
        self.language = language
        self.title = title
        self.content = content
        self.isComplete = isComplete
        self.identifier = identifier
        self.callID = callID
        self.isStale = isStale
    }

    /// Versions of one Artifact share this key: the kind plus the normalised title.
    public var groupKey: String {
        if let identifier { return "id:\(identifier)" }
        let words = title.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return "\(kind.rawValue):\(words.joined(separator: " "))"
    }

    /// The type line on the card ("Interactive artifact", "Diagram"…).
    public var typeLabel: String {
        switch kind {
        case .webPage: origin == .toolEmbed ? "Tool view" : "Interactive artifact"
        case .image: "Image"
        case .diagram: "Diagram"
        case .component: "Component"
        case .document: "Document"
        case .code: "Code"
        }
    }

    /// Whether the viewer can show a rendered preview (not just the source).
    public var hasPreview: Bool { kind != .component && kind != .code }

    /// The file extension used when sharing or exporting.
    public var fileExtension: String {
        switch kind {
        case .webPage: "html"
        case .image: "svg"
        case .diagram: "mmd"
        case .component: language?.lowercased() == "tsx" ? "tsx" : "jsx"
        case .document: "md"
        case .code: Self.codeExtensions[language?.lowercased() ?? ""] ?? "txt"
        }
    }

    /// File extensions for common code languages.
    static let codeExtensions: [String: String] = [
        "python": "py", "javascript": "js", "typescript": "ts", "jsx": "jsx", "tsx": "tsx", "swift": "swift",
        "json": "json", "yaml": "yml", "bash": "sh", "shell": "sh", "sh": "sh", "css": "css", "html": "html",
        "sql": "sql", "dockerfile": "dockerfile", "go": "go", "rust": "rs", "java": "java", "kotlin": "kt",
        "c": "c", "cpp": "cpp", "csharp": "cs", "ruby": "rb", "php": "php", "markdown": "md", "xml": "xml",
        "handlebars": "hbs", "powershell": "ps1", "text": "txt",
    ]

    /// Whether a web page loads anything from the network (CDN scripts, styles, images), so the
    /// viewer can offer to allow it.
    public var referencesNetwork: Bool {
        guard kind == .webPage else { return false }
        return content.range(of: #"(src|href)\s*=\s*["']?\s*(https?:)?//"#, options: [.regularExpression, .caseInsensitive]) != nil
            || content.range(of: #"url\(\s*["']?(https?:)?//"#, options: [.regularExpression, .caseInsensitive]) != nil
            || content.range(of: #"@import\s+["']?(url\()?\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
