public import Foundation

/// Normalises what a user types into the Server field into a base URL.
public enum ServerURL {
    /// - `chat.example.com` → `https://chat.example.com`
    /// - `http://192.168.1.5:8080/` → `http://192.168.1.5:8080`
    /// - `https://example.com/owui/` → `https://example.com/owui` (sub-path deployments keep their path)
    ///
    /// Query strings and fragments are dropped. Only `http` and `https` are accepted.
    public static func normalize(_ input: String) throws(OpenWebUIError) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidServerURL(input) }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(" ")
        else { throw .invalidServerURL(input) }

        components.scheme = scheme
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw .invalidServerURL(input) }
        return url
    }
}
