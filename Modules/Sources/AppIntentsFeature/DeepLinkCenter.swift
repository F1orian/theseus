/// Hands `DeepLink`s from App Intents (and the URL scheme) to the running app. Links that arrive
/// before the app installs its handler (a cold launch from a widget or Siri) wait until it does.
@MainActor
public final class DeepLinkCenter {
    /// The app's center. Intents run inside the app process, so they reach the same instance.
    public static let shared = DeepLinkCenter()

    private var handler: ((DeepLink) -> Void)?
    private var waiting: [DeepLink] = []

    public init() {}

    /// Opens `link` now, or as soon as a handler is installed.
    public func open(_ link: DeepLink) {
        if let handler {
            handler(link)
        } else {
            waiting.append(link)
        }
    }

    /// Installs the app's router and delivers any links that arrived before it.
    public func setHandler(_ handler: @escaping (DeepLink) -> Void) {
        self.handler = handler
        let links = waiting
        waiting = []
        links.forEach(handler)
    }
}
