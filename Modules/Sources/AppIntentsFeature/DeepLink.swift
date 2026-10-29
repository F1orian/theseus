public import Foundation

/// A place in Theseus that other apps, Shortcuts, widgets and the Share extension can open
/// (PLAT-03). Its `theseus://` URL form is a public contract: once shipped, a URL keeps working.
///
/// | URL | Opens |
/// |---|---|
/// | `theseus://new` | the new-chat home |
/// | `theseus://new?prompt=Hi&send=1` | a new Chat with "Hi" in the composer (sent right away) |
/// | `theseus://new?start=camera` | a new Chat with the camera open (`photos`, `dictation` too) |
/// | `theseus://voice` | a new Chat in Voice mode |
/// | `theseus://incognito` | a new Incognito chat (optionally `?prompt=`) |
/// | `theseus://chat/<id>` | a saved Chat |
/// | `theseus://chats` | the Chats list |
/// | `theseus://share/<id>` | a new Chat holding what the Share extension stored |
/// | `theseus://pro` | the Theseus Pro paywall (from a locked widget or the Share extension; ADR 0173) |
public enum DeepLink: Hashable, Sendable {
    case newChat(NewChat)
    /// A new Incognito chat (INCOG-01); a new Chat when the Account can't have one.
    case incognitoChat(prompt: String?)
    case chat(id: String)
    case chatsList
    /// A `ShareInbox` entry (PLAT-04).
    case sharedItems(UUID)
    /// The Theseus Pro paywall (ADR 0173). Never gated itself.
    case pro

    /// How a new Chat starts.
    public struct NewChat: Hashable, Sendable {
        /// What a new Chat opens with, besides the keyboard.
        public enum Start: String, Hashable, Sendable, CaseIterable {
            case camera
            case photos
            case dictation
            case voiceMode = "voice"
        }

        /// Text for the composer.
        public var prompt: String?
        /// Send `prompt` as soon as the Chat is ready.
        public var sendsImmediately: Bool
        public var start: Start?

        public init(prompt: String? = nil, sendsImmediately: Bool = false, start: Start? = nil) {
            self.prompt = prompt?.isEmpty == true ? nil : prompt
            self.sendsImmediately = sendsImmediately && self.prompt != nil
            self.start = start
        }
    }

    public static let scheme = "theseus"

    /// Shorthand for the new-chat home.
    public static var newChat: DeepLink { .newChat(NewChat()) }

    /// Parses a `theseus://` URL; `nil` for anything else.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let host = (components.host ?? "").lowercased()
        let path = components.path.split(separator: "/").map(String.init)
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        switch host {
        case "", "new":
            self = .newChat(NewChat(
                prompt: query["prompt"],
                sendsImmediately: ["1", "true", "yes"].contains(query["send"]?.lowercased() ?? ""),
                start: query["start"].flatMap { NewChat.Start(rawValue: $0.lowercased()) }
            ))
        case "voice":
            self = .newChat(NewChat(start: .voiceMode))
        case "incognito":
            self = .incognitoChat(prompt: query["prompt"].flatMap { $0.isEmpty ? nil : $0 })
        case "chat":
            guard let id = path.first, !id.isEmpty else { return nil }
            self = .chat(id: id)
        case "chats":
            self = .chatsList
        case "share":
            guard let id = path.first.flatMap(UUID.init(uuidString:)) else { return nil }
            self = .sharedItems(id)
        case "pro":
            self = .pro
        default:
            return nil
        }
    }

    /// The link's `theseus://` URL.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        var items: [URLQueryItem] = []
        switch self {
        case .newChat(let options):
            if options == NewChat(start: .voiceMode) {
                components.host = "voice"
            } else {
                components.host = "new"
                if let prompt = options.prompt { items.append(URLQueryItem(name: "prompt", value: prompt)) }
                if options.sendsImmediately { items.append(URLQueryItem(name: "send", value: "1")) }
                if let start = options.start { items.append(URLQueryItem(name: "start", value: start.rawValue)) }
            }
        case .incognitoChat(let prompt):
            components.host = "incognito"
            if let prompt { items.append(URLQueryItem(name: "prompt", value: prompt)) }
        case .chat(let id):
            components.host = "chat"
            components.path = "/" + id
        case .chatsList:
            components.host = "chats"
        case .sharedItems(let id):
            components.host = "share"
            components.path = "/" + id.uuidString
        case .pro:
            components.host = "pro"
        }
        components.queryItems = items.isEmpty ? nil : items
        // Every component above is valid, so this can't fail; fall back to the home just in case.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
