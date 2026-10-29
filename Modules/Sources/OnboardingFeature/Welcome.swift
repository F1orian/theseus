public import OpenWebUIKit

/// The one-time welcome after an Account's first sign-in on this device (AUTH-08, ADR 0112):
/// what works with this Server, from its Capabilities. Theseus's post-sign-in
/// sheet, without the promotion.
public struct WelcomeSummary: Identifiable, Equatable, Sendable {
    /// One line of the welcome: an SF Symbol and a sentence.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let symbol: String
        public let text: String
    }

    public var id: String { host }
    /// The Server's host, as the user typed it ("chat.example.com").
    public let host: String
    public let items: [Item]

    /// - Parameters:
    ///   - capabilities: the Account's, without a model (Server flags and permissions).
    ///   - savesChats: `false` when the Server makes every Chat Incognito (INCOG-02).
    ///   - speechOnDevice: whether Dictation and Voice mode listen and speak on this device
    ///     (no Server speech engines, ADR 0080).
    ///   - connectorNames: the Connectors the admin set up, in display order.
    public init(host: String, capabilities: Capabilities, savesChats: Bool, speechOnDevice: Bool, connectorNames: [String]) {
        self.host = host
        var items: [Item] = []
        if savesChats {
            items.append(Item(id: "chats", symbol: "bubble.left.and.bubble.right", text: "Your Chats are saved on \(host), so they’re in its web app too."))
        } else {
            items.append(Item(id: "chats", symbol: "theatermasks", text: "\(host) makes every Chat Incognito: nothing you say is saved."))
        }
        if capabilities.contains(.voiceMode) || capabilities.contains(.dictation) {
            items.append(Item(
                id: "voice", symbol: "waveform",
                text: speechOnDevice
                    ? "Voice mode and Dictation run on this device: your speech is recognised and spoken here."
                    : "Voice mode and Dictation use \(host)’s speech engines."
            ))
        }
        if capabilities.contains(.projects) {
            items.append(Item(id: "projects", symbol: "square.stack", text: "Projects keep related Chats together, with their own Instructions and Knowledge."))
        } else {
            items.append(Item(id: "projects", symbol: "square.stack", text: "Projects need folders, which \(host) doesn’t offer, so they’re hidden."))
        }
        if capabilities.contains(.webSearch) {
            items.append(Item(id: "webSearch", symbol: "globe", text: "Web search can look things up and cite its Sources."))
        }
        if capabilities.contains(.connectors), !connectorNames.isEmpty {
            items.append(Item(id: "connectors", symbol: "square.grid.2x2", text: "Connectors: \(Self.list(connectorNames)). Turn them on per Chat in Add to Chat."))
        }
        if capabilities.contains(.memory) {
            items.append(Item(id: "memory", symbol: "brain", text: "Memory remembers what matters across Chats. See and edit it in Settings."))
        }
        self.items = items
    }

    /// "A", "A and B", "A, B and C", "A, B and 2 more".
    static func list(_ names: [String], limit: Int = 3) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2...limit: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        default: return names.prefix(limit - 1).joined(separator: ", ") + " and \(names.count - (limit - 1)) more"
        }
    }
}
