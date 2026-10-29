#if os(iOS)
import DesignSystem
import SwiftUI
import WebKit

/// CONN-03: connects a Connector by walking the Server's MCP OAuth 2.1 flow in a web view. Like
/// the single sign-on sheet (ADR 0014) it uses a **non-persistent** data store, here seeded with
/// the Session token as the Server's `token` cookie; nothing from the web session outlives the
/// sheet. `ConnectorAuthorization` decides when the flow is done.
struct ConnectorConnectSheet: View {
    let authorization: ConnectorAuthorization
    let onFinish: (ConnectorAuthorization.Event?) -> Void

    @State private var pageHost: String?
    @State private var isLoading = true
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ConnectorWebView(authorization: authorization, pageHost: $pageHost, isLoading: $isLoading) { event in
                finish(event)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if isLoading, pageHost == nil {
                    ProgressView()
                }
            }
            .navigationTitle("Connect \(authorization.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { finish(nil) }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("connectors.connect.cancel")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Connect \(authorization.name)").font(Typography.headline)
                        if let pageHost {
                            Label(pageHost, systemImage: "lock.fill")
                                .labelStyle(.titleAndIcon)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary.color)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("connectors.connect")
    }

    private func finish(_ event: ConnectorAuthorization.Event?) {
        guard !finished else { return }
        finished = true
        onFinish(event)
    }
}

private struct ConnectorWebView: UIViewRepresentable {
    let authorization: ConnectorAuthorization
    @Binding var pageHost: String?
    @Binding var isLoading: Bool
    let onEvent: (ConnectorAuthorization.Event) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "connectors.connect.webView"
        context.coordinator.webView = webView
        let request = authorization.startRequest
        if let cookie = authorization.sessionCookie {
            Task { @MainActor in
                await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                webView.load(request)
            }
        } else {
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ConnectorWebView
        weak var webView: WKWebView?
        private var done = false

        init(parent: ConnectorWebView) {
            self.parent = parent
        }

        private func handle(_ event: ConnectorAuthorization.Event) {
            guard !done, event != .continue else { return }
            done = true
            webView?.stopLoading()
            parent.onEvent(event)
        }

        private func inspect(_ url: URL?) {
            parent.pageHost = url?.host()
            handle(parent.authorization.event(at: url))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let event = parent.authorization.event(at: navigationAction.request.url)
            if event != .continue {
                // Don't load the Server's web app once the flow is over.
                handle(event)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let response = navigationResponse.response as? HTTPURLResponse {
                let event = parent.authorization.event(forResponseFrom: response.url, status: response.statusCode)
                if event != .continue {
                    handle(event)
                    return .cancel
                }
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            inspect(webView.url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.isLoading = true
            inspect(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            inspect(webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        private func report(_ error: any Error) {
            parent.isLoading = false
            // Cancelled loads are normal: redirects, and our own cancel once the flow is over.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return } // frame load interrupted
            handle(.failed(error.localizedDescription))
        }
    }
}
#endif
