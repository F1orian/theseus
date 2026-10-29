import DesignSystem
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What the sandbox allows for one page (ADR 0060).
struct SandboxPolicy: Hashable {
    /// JavaScript (Web pages, Mermaid); off for SVG.
    var allowsScripts: Bool
    /// Remote loads, after the user allowed them for this viewing.
    var allowsNetwork: Bool = false
    /// Injected at document end (the bundled Mermaid runtime).
    var userScripts: [String] = []
    /// What shows behind the page and before it paints (#180). Never clear: a page that sets no
    /// background of its own (most fragments) draws its default black text straight onto it,
    /// so a clear canvas over the app's dark background made such pages unreadable.
    var canvas: RGBA = ArtifactDocument.browserCanvas
}

/// The compiled rule list that blocks every remote load, under the CSP (ADR 0060).
@MainActor
enum OfflineRules {
    private static var compiled: Task<WKContentRuleList?, Never>?

    static let json = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
    """

    static func ruleList() async -> WKContentRuleList? {
        if let compiled { return await compiled.value }
        let task = Task<WKContentRuleList?, Never> {
            guard let store = WKContentRuleListStore.default() else { return nil }
            return try? await store.compileContentRuleList(forIdentifier: "theseus.artifacts.offline", encodedContentRuleList: json)
        }
        compiled = task
        return await task.value
    }
}

/// A `WKWebView` that shows one Artifact page offline: no persistence, no bridge, no pop-ups, no
/// navigation away (tapped web links open in the browser instead).
struct SandboxedWebView: View {
    let html: String
    let policy: SandboxPolicy
    @Environment(\.openURL) private var openURL
    @State private var rules: WKContentRuleList?
    @State private var state = LoadState.preparing

    private enum LoadState { case preparing, ready, failed }

    var body: some View {
        Group {
            switch state {
            case .ready:
                WebViewHost(html: html, policy: policy, rules: rules) { url in openURL(url) }
            case .preparing:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text("Theseus couldn't set up its offline sandbox. Switch to Code to read the artifact.")
                )
            }
        }
        .task(id: policy.allowsNetwork) {
            rules = policy.allowsNetwork ? nil : await OfflineRules.ruleList()
            // Fail closed: an offline page never loads without its network wall.
            state = policy.allowsNetwork || rules != nil ? .ready : .failed
        }
    }
}

@MainActor
final class SandboxCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var allowsNetwork = false
    var openLink: (URL) -> Void = { _ in }
    var loaded: String?

    /// The web view for one page: sandboxed (see `configuration`) and painted with the policy's
    /// canvas, like a browser window, so a page without its own background stays readable.
    static func makeWebView(policy: SandboxPolicy, rules: WKContentRuleList?, coordinator: SandboxCoordinator) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration(policy: policy, rules: rules))
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsLinkPreview = false
        #if canImport(UIKit)
        let canvas = UIColor(red: policy.canvas.red, green: policy.canvas.green, blue: policy.canvas.blue, alpha: 1)
        view.isOpaque = true
        view.backgroundColor = canvas
        view.scrollView.backgroundColor = canvas
        view.underPageBackgroundColor = canvas
        view.accessibilityIdentifier = "artifact.webView"
        #elseif canImport(AppKit)
        view.underPageBackgroundColor = NSColor(srgbRed: policy.canvas.red, green: policy.canvas.green, blue: policy.canvas.blue, alpha: 1)
        #endif
        return view
    }

    static func configuration(policy: SandboxPolicy, rules: WKContentRuleList?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = policy.allowsScripts
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        #endif
        if let rules { configuration.userContentController.add(rules) }
        for script in policy.userScripts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        return configuration
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let isWeb = scheme == "http" || scheme == "https"
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true {
            // In-page anchors keep working; web links leave the sandbox for the browser.
            if scheme == "about" { return .allow }
            if isWeb { openLink(url) }
            return .cancel
        }
        if scheme == "about" { return .allow }
        // Sub-frames (an embedded video, a tool view) only when the user allowed the network.
        if isWeb, allowsNetwork, action.targetFrame?.isMainFrame == false { return .allow }
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target="_blank"` / `window.open`: open web links in the browser, never a new web view.
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openLink(url)
        }
        return nil
    }
}

#if os(iOS)
private struct WebViewHost: UIViewRepresentable {
    let html: String
    let policy: SandboxPolicy
    let rules: WKContentRuleList?
    let openLink: (URL) -> Void

    func makeCoordinator() -> SandboxCoordinator { SandboxCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        SandboxCoordinator.makeWebView(policy: policy, rules: rules, coordinator: context.coordinator)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        load(view, coordinator: context.coordinator)
    }

    private func load(_ view: WKWebView, coordinator: SandboxCoordinator) {
        coordinator.allowsNetwork = policy.allowsNetwork
        coordinator.openLink = openLink
        guard coordinator.loaded != html else { return }
        coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }
}
#else
private struct WebViewHost: NSViewRepresentable {
    let html: String
    let policy: SandboxPolicy
    let rules: WKContentRuleList?
    let openLink: (URL) -> Void

    func makeCoordinator() -> SandboxCoordinator { SandboxCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        SandboxCoordinator.makeWebView(policy: policy, rules: rules, coordinator: context.coordinator)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.allowsNetwork = policy.allowsNetwork
        context.coordinator.openLink = openLink
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }
}
#endif
