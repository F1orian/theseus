public import Foundation
import Synchronization

/// How the UI names the Server. Normally that's its host (`chat.example.com`) or its own name.
///
/// For screen recordings (the launch video, demos), set a **Server alias** and every place the UI would
/// show the Server's host, URL or name shows the alias instead. That includes the Share extension, the
/// connection banner, citations and links that point at the Server. Set it either way:
/// - the `THESEUS_SERVER_ALIAS` build setting, e.g. `xcodebuild … THESEUS_SERVER_ALIAS=chat.example.com`.
///   Each target's Info.plist carries it as `TheseusServerAlias`, so the extensions get it too.
/// - the `THESEUS_SERVER_ALIAS` environment variable at launch (app process only).
///
/// Display only: networking, sign-in and identity always use the real URL. System UI that Theseus doesn't
/// draw (the share sheet's link preview) can't be covered.
public enum ServerDisplay {
    public static let alias: String? = {
        let candidates = [
            ProcessInfo.processInfo.environment["THESEUS_SERVER_ALIAS"],
            Bundle.main.object(forInfoDictionaryKey: "TheseusServerAlias") as? String,
        ]
        for candidate in candidates {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, !value.hasPrefix("$(") { return value }
        }
        return nil
    }()

    /// True when an alias hides the real Server.
    public static var isHidingServer: Bool { alias != nil }

    /// The Server's host for display: the alias, else `url.host()`, else `fallback`, else the URL.
    public static func host(_ url: URL, fallback: String? = nil) -> String {
        if let alias { register(url); return alias }
        return url.host() ?? fallback ?? url.absoluteString
    }

    /// A host string about to be shown (e.g. from the shared snapshot): the alias when one is set.
    public static func host(_ host: String) -> String { alias ?? host }

    /// The Server's own name (`/api/config`, e.g. "Open WebUI"), or the alias.
    public static func name(_ name: String) -> String { alias ?? name }

    /// The host of an arbitrary link (citation, embed, web page). Links to a known Server show the alias;
    /// everything else is untouched.
    public static func linkHost(_ host: String?) -> String? {
        guard let alias, let host else { return host }
        return known.withLock { $0.contains(host.lowercased()) } ? alias : host
    }

    /// Remembers a Server's host so `linkHost` recognises links to it. A no-op without an alias.
    public static func register(_ server: URL) {
        guard alias != nil, let host = server.host()?.lowercased() else { return }
        known.withLock { _ = $0.insert(host) }
    }

    private static let known = Mutex<Set<String>>([])

    /// Display names for models, for screenshots that mustn't show third-party model brands: the
    /// `THESEUS_MODEL_NAMES` build setting or environment variable, `id=Name` pairs separated by `;`
    /// (e.g. `claude-opus-5-5=Smart;claude-haiku-5-5=Fast`). Empty = the server's names.
    public static let modelNames: [String: String] = {
        let raw = ProcessInfo.processInfo.environment["THESEUS_MODEL_NAMES"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "TheseusModelNames") as? String) ?? ""
        guard !raw.hasPrefix("$(") else { return [:] }
        var names: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { names[parts[0]] = parts[1] }
        }
        return names
    }()

    /// A model's name for display: its alias from `modelNames`, else the server's name.
    public static func modelName(id: String, name: String) -> String { modelNames[id] ?? name }
}
