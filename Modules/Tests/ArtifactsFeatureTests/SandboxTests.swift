@testable import ArtifactsFeature
import DesignSystem
import Foundation
import Testing
import WebKit

@Suite("Artifact sandbox (ADR 0060)", .serialized)
@MainActor
struct SandboxTests {
    @Test func cspIsTheFirstThingInHead() {
        let page = ArtifactDocument.html("<!DOCTYPE html><html lang=\"en\"><HEAD class=\"x\"><title>T</title></HEAD><body></body></html>", allowsNetwork: false)
        let head = try? #require(page.range(of: "<HEAD class=\"x\">"))
        let csp = try? #require(page.range(of: "Content-Security-Policy"))
        let title = try? #require(page.range(of: "<title>"))
        if let head, let csp, let title {
            #expect(head.upperBound <= csp.lowerBound)
            #expect(csp.upperBound <= title.lowerBound)
        }
        #expect(page.contains("connect-src 'none'"))
        #expect(page.contains("name=\"viewport\""))
    }

    @Test func fragmentsAndBareDocumentsGetAHead() {
        #expect(ArtifactDocument.html("<html><body>x</body></html>", allowsNetwork: false).hasPrefix("<html><head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(ArtifactDocument.html("<!doctype html><p>x</p>", allowsNetwork: false).hasPrefix("<!doctype html><head><meta"))
        #expect(ArtifactDocument.html("<p>x</p>", allowsNetwork: false).hasPrefix("<!doctype html><html><head><meta"))
        // A page's own viewport is kept, not doubled.
        let own = ArtifactDocument.html("<head><meta name=\"viewport\" content=\"width=600\"></head>", allowsNetwork: false)
        #expect(own.components(separatedBy: "viewport").count == 2)
        // With network allowed, remote loads pass the CSP.
        #expect(ArtifactDocument.html("<p>x</p>", allowsNetwork: true).contains("default-src * data: blob:"))
    }

    /// #180: pages were drawn on a clear web view, so in dark mode a page without its own
    /// background showed its default black text on the app's dark background.
    @Test func pagesAreDrawnOnAnOpaqueBrowserCanvas() throws {
        let white = RGBA(hex: 0xFFFFFF)
        for kind in [Artifact.Kind.webPage, .image] {
            #expect(ArtifactDocument.canvas(for: kind, dark: true) == white)
            #expect(ArtifactDocument.canvas(for: kind, dark: false) == white)
        }
        // The Mermaid page is Theseus's own, themed page: the canvas matches it.
        #expect(ArtifactDocument.canvas(for: .diagram, dark: true) == Palette.background.dark)
        #expect(ArtifactDocument.canvas(for: .diagram, dark: false) == Palette.background.light)
        #expect(SandboxPolicy(allowsScripts: true).canvas == white)

        let policy = SandboxPolicy(allowsScripts: true, canvas: ArtifactDocument.canvas(for: .webPage, dark: true))
        let view = SandboxCoordinator.makeWebView(policy: policy, rules: nil, coordinator: SandboxCoordinator())
        let color = try #require(view.underPageBackgroundColor.usingColorSpace(.sRGB))
        #expect(color.alphaComponent == 1)
        #expect(color.redComponent == 1 && color.greenComponent == 1 && color.blueComponent == 1)
    }

    @Test func mermaidSourceIsEscapedAndTheRuntimeIsBundled() throws {
        let page = ArtifactDocument.mermaid("graph TD\n A[<b>x</b>] --> B & C", dark: false)
        #expect(page.contains("A[&lt;b&gt;x&lt;/b&gt;] --&gt; B &amp; C"))
        let runtime = try #require(MermaidRuntime.source)
        #expect(runtime.contains("globalThis[\"mermaid\"]"))
    }

    @Test func exportFileNamesAreSafe() throws {
        #expect(ArtifactExport.fileName("Tip / Calculator: v2!") == "Tip Calculator v2")
        #expect(ArtifactExport.fileName("///") == "Artifact")
        let artifact = Artifact(messageID: "m", index: 0, kind: .image, language: "svg", title: "Sun icon", content: "<svg/>")
        let url = try ArtifactExport.write(artifact)
        #expect(url.lastPathComponent == "Sun icon.svg")
        #expect(try String(contentsOf: url, encoding: .utf8) == "<svg/>")
    }

    @Test func offlineRulesCompile() async {
        #expect(await OfflineRules.ruleList() != nil)
    }

    /// Loads a page that tries to reach the network and reports what happened in its title.
    @Test func offlinePagesCannotReachTheNetwork() async throws {
        let rules = await OfflineRules.ruleList()
        let policy = SandboxPolicy(allowsScripts: true)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: SandboxCoordinator.configuration(policy: policy, rules: rules))
        let coordinator = SandboxCoordinator()
        webView.navigationDelegate = coordinator
        let html = ArtifactDocument.html("""
        <html><head><title>start</title></head><body><script>
        fetch('https://example.com/beacon').then(function () { document.title = 'leaked'; })
          .catch(function () { document.title = 'blocked'; });
        </script></body></html>
        """, allowsNetwork: false)
        webView.loadHTMLString(html, baseURL: nil)
        var title: String?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            title = try? await webView.evaluateJavaScript("document.title") as? String
            if title == "blocked" || title == "leaked" { break }
        }
        #expect(title == "blocked")
        // No bridge into the app.
        #expect(try await webView.evaluateJavaScript("typeof window.webkit === 'undefined' || typeof window.webkit.messageHandlers === 'undefined' || Object.keys(window.webkit.messageHandlers).length === 0") as? Bool == true)
    }
}
