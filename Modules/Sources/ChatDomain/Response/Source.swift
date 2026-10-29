public import Foundation

/// One Source attached to a Response: a web page, a Knowledge document or a tool result
/// (server shape `{source, document[], metadata[]}`, docs/research/open-webui-api.md §7.4).
public struct Source: Sendable, Hashable {
    /// Per-chunk metadata; `document[i]` pairs with `metadata[i]`.
    public struct Chunk: Sendable, Hashable {
        public var text: String
        public var name: String?
        public var title: String?
        /// A URL or a file id.
        public var source: String?
        public var url: String?
        public var page: Int?

        public init(text: String, name: String? = nil, title: String? = nil, source: String? = nil, url: String? = nil, page: Int? = nil) {
            self.text = text
            self.name = name
            self.title = title
            self.source = source
            self.url = url
            self.page = page
        }
    }

    /// `source.id`: a URL for web results, a file id for Knowledge.
    public var id: String?
    public var name: String
    /// `source.type`, e.g. `"file"`, `"web_search"`, `"tool"`.
    public var kind: String?
    public var url: String?
    public var chunks: [Chunk]

    public init(id: String?, name: String, kind: String? = nil, url: String? = nil, chunks: [Chunk] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.chunks = chunks
    }

    /// The best link to open for this Source, if it's a web page.
    public var link: URL? {
        for candidate in [url, chunks.first?.url, chunks.first?.source, id] {
            if let candidate, let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        return nil
    }
}

/// A numbered entry of the Sources list. The model cites `[n]`; `n` counts the flattened chunks
/// of all Sources in order, deduplicated by their underlying document (as the web client does).
public struct Citation: Sendable, Hashable, Identifiable {
    public let number: Int
    public let title: String
    public let link: URL?
    /// The host for web links (e.g. `github.com`), shown as a subtitle.
    public let host: String?
    public let snippet: String

    public var id: Int { number }

    public init(number: Int, title: String, link: URL?, snippet: String) {
        self.number = number
        self.title = title
        self.link = link
        self.host = ServerDisplay.linkHost(link?.host())?.replacingOccurrences(of: "www.", with: "")
        self.snippet = snippet
    }

    /// Flattens `sources` into numbered citations.
    public static func list(from sources: [Source]) -> [Citation] {
        var citations: [Citation] = []
        var seen: [String: Int] = [:]
        for source in sources {
            let chunks = source.chunks.isEmpty ? [Source.Chunk(text: "")] : source.chunks
            for chunk in chunks {
                let key = chunk.source ?? chunk.url ?? source.id ?? source.name
                if seen[key] != nil { continue }
                let link = [chunk.url, chunk.source, source.url, source.id]
                    .compactMap { $0.flatMap(URL.init(string:)) }
                    .first { ["http", "https"].contains($0.scheme?.lowercased()) }
                let title = [chunk.title, chunk.name, source.name]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? link?.absoluteString ?? "Source"
                let number = citations.count + 1
                seen[key] = number
                citations.append(Citation(
                    number: number,
                    title: title,
                    link: link,
                    snippet: Self.snippet(chunk.text)
                ))
            }
        }
        return citations
    }

    private static func snippet(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 280 ? String(collapsed.prefix(280)) + "…" : collapsed
    }
}

extension Source: Codable {
    private enum Keys: String, CodingKey {
        case source, document, metadata
    }

    private struct Info: Codable {
        var id: String?
        var name: String?
        var type: String?
        var url: String?
    }

    private struct Metadata: Decodable {
        var name: String?
        var title: String?
        var source: String?
        var url: String?
        var page: Int?

        enum CodingKeys: String, CodingKey { case name, title, source, url, page }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
            name = text(.name)
            title = text(.title)
            source = text(.source)
            url = text(.url)
            page = (try? container.decodeIfPresent(Int.self, forKey: .page)) ?? nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let info = (try? container.decodeIfPresent(Info.self, forKey: .source)) ?? nil
        let documents = ((try? container.decodeIfPresent([String].self, forKey: .document)) ?? nil) ?? []
        let metadata = ((try? container.decodeIfPresent([Metadata?].self, forKey: .metadata)) ?? nil) ?? []
        id = info?.id
        name = info?.name ?? info?.id ?? "Source"
        kind = info?.type
        url = info?.url
        chunks = documents.enumerated().map { index, text in
            let meta = index < metadata.count ? metadata[index] : nil
            return Chunk(text: text, name: meta?.name, title: meta?.title, source: meta?.source, url: meta?.url, page: meta?.page)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Info(id: id, name: name, type: kind, url: url), forKey: .source)
        try container.encode(chunks.map(\.text), forKey: .document)
    }
}

/// A progress line such as "Searching the web" (`status` events, `message.statusHistory`).
public struct StatusUpdate: Sendable, Hashable, Codable {
    public var action: String?
    public var description: String
    public var isDone: Bool
    public var isHidden: Bool
    public var urls: [String]

    public init(action: String? = nil, description: String, isDone: Bool = false, isHidden: Bool = false, urls: [String] = []) {
        self.action = action
        self.description = description
        self.isDone = isDone
        self.isHidden = isHidden
        self.urls = urls
    }

    private enum Keys: String, CodingKey { case action, description, done, hidden, urls }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        action = (try? container.decodeIfPresent(String.self, forKey: .action)) ?? nil
        description = ((try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil) ?? ""
        isDone = ((try? container.decodeIfPresent(Bool.self, forKey: .done)) ?? nil) ?? false
        isHidden = ((try? container.decodeIfPresent(Bool.self, forKey: .hidden)) ?? nil) ?? false
        urls = ((try? container.decodeIfPresent([String].self, forKey: .urls)) ?? nil) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encode(description, forKey: .description)
        try container.encode(isDone, forKey: .done)
        try container.encode(isHidden, forKey: .hidden)
        try container.encode(urls, forKey: .urls)
    }
}
