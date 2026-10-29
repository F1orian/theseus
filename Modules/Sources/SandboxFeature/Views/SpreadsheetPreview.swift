import DesignSystem
import Foundation
import SwiftUI
#if canImport(UIKit)
import WebKit
#endif

/// The preview for spreadsheets (#143). Quick Look renders an Office sheet as a desktop-width web
/// page scaled to fit the phone, so a small sheet shows as a speck in the top-left corner and every
/// sheet needs pinching. WebKit converts the same file, and this view gives that page the device's
/// width and readable cell text instead. Tabs for workbooks with several sheets still work.
enum SpreadsheetPreview {
    /// Extensions this preview handles instead of Quick Look.
    static let extensions: Set<String> = ["xlsx", "xlsm", "xls"]

    static func handles(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Injected into the converted page and its sheet frames: phone-width layout, legible cells
    /// in the system font, and columns as wide as their text (WebKit's conversion keeps Excel's
    /// column widths in points and clips longer text).
    static let script = """
    (function () {
      var head = document.head || document.documentElement;
      var viewport = document.querySelector('meta[name=viewport]');
      if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; head.appendChild(viewport); }
      viewport.content = 'width=device-width, initial-scale=1';
      var style = document.createElement('style');
      style.textContent = 'body{-webkit-text-size-adjust:100%;margin:8px;}'
        + ' table{border-collapse:collapse;table-layout:auto !important;width:auto !important;} col{width:auto !important;}'
        + ' td,th{font-family:-apple-system,sans-serif !important;font-size:16px !important;padding:6px 10px !important;'
        + 'width:auto !important;white-space:nowrap;} td>div{width:auto !important;overflow:visible !important;}';
      head.appendChild(style);
    })();
    """
}

#if canImport(UIKit)
/// A sheet with the spreadsheet, its name, Done and Share.
struct SpreadsheetPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SpreadsheetWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", systemImage: "xmark") { dismiss() }
                            .tint(Palette.textPrimary.color)
                            .accessibilityIdentifier("spreadsheet.close")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .tint(Palette.textPrimary.color)
                            .accessibilityIdentifier("spreadsheet.share")
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spreadsheet.preview")
    }
}

/// The converted sheet: a non-persistent web view that only reads the file (no network, no
/// navigation away).
private struct SpreadsheetWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(source: SpreadsheetPreview.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The file and the sheets WebKit converted it into; nothing remote.
            switch action.request.url?.scheme {
            case "file", "x-apple-ql-id", "about": .allow
            default: .cancel
            }
        }
    }
}
#endif
