#if os(iOS)
import ChatDomain
import DesignSystem
import SwiftUI
import WebKit

/// AUTH-04: the single sign-on sheet. A `WKWebView` with a **non-persistent** data store runs the
/// Server's OAuth flow; every navigation step and cookie change is reported to `WebSignInModel`,
/// which captures the Server's `token` cookie (ADR 0014). Nothing from the web session survives
/// the sheet.
struct WebSignInSheet: View {
    let model: WebSignInModel

    var body: some View {
        NavigationStack {
            SignInWebView(model: model)
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if model.state != .browsing {
                        ProgressView("Signing in…")
                            .padding(Spacing.xl)
                            .background(.regularMaterial, in: .rect(cornerRadius: Radius.large))
                    }
                }
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { Task { await model.cancel() } }
                            .tint(Palette.textPrimary.color)
                            .accessibilityIdentifier("sso.cancel")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(model.title).font(Typography.headline)
                            if let host = ServerDisplay.linkHost(model.pageHost) {
                                Label(host, systemImage: model.pageIsEncrypted ? "lock.fill" : "lock.open")
                                    .labelStyle(.titleAndIcon)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary.color)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
        .interactiveDismissDisabled(model.state != .browsing)
    }
}

private struct SignInWebView: UIViewRepresentable {
    let model: WebSignInModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing (IdP cookies, the Server's cookie) outlives this sheet.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "sso.webView"
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: model.webSignIn.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let model: WebSignInModel
        weak var webView: WKWebView?

        init(model: WebSignInModel) {
            self.model = model
        }

        private func inspect() {
            guard let webView else { return }
            let url = webView.url
            Task {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                await model.observe(url: url, cookies: cookies)
                if model.state != .browsing { webView.stopLoading() }
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            inspect()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            inspect()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspect()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        private func report(_ error: any Error) {
            // Cancelled loads are normal: redirects, and our own stopLoading() after capture.
            guard let urlError = error as? URLError, urlError.code != .cancelled else { return }
            Task { await model.loadFailed(urlError) }
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.inspect() }
        }
    }
}
#endif
