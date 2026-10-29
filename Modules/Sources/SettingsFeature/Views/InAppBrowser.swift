import SwiftUI
#if os(iOS)
import SafariServices
#endif

extension View {
    /// Opens web links (`openURL`, `Link`) inside the app in a Safari sheet; other schemes
    /// (`mailto:`, `app-settings:`) go to the system as usual.
    func inAppBrowser() -> some View {
        modifier(InAppBrowserModifier())
    }
}

private struct BrowserPage: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct InAppBrowserModifier: ViewModifier {
    @State private var page: BrowserPage?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
                page = BrowserPage(url: url)
                return .handled
            })
            .sheet(item: $page) { page in
                SafariView(url: page.url).ignoresSafeArea()
            }
        #else
        content
        #endif
    }
}

#if os(iOS)
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
