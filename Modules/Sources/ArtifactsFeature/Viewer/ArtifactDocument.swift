import DesignSystem
import Foundation

/// The HTML documents the sandboxed viewer loads for an Artifact (ADR 0060): the Artifact's own
/// markup with a strict Content-Security-Policy injected first, or a small wrapper page.
enum ArtifactDocument {
    /// No network at all: inline scripts and styles, `data:`/`blob:` media only.
    static let offlinePolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval'",
        "style-src 'unsafe-inline'",
        "img-src data: blob:",
        "font-src data:",
        "media-src data: blob:",
        "connect-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    /// After the user allowed network access for this viewing: remote loads, still no form posts
    /// or `<base>` rewrites.
    static let networkPolicy = [
        "default-src * data: blob: 'unsafe-inline' 'unsafe-eval'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    /// A browser window's default canvas: what an HTML page that sets no background is drawn on.
    static let browserCanvas = RGBA(hex: 0xFFFFFF)

    /// What the web view shows behind `artifact`'s page (#180): white for Web pages and SVG, as
    /// in a browser (their default text is black, whatever the app's appearance), and the app's
    /// background for the Mermaid page, which Theseus themes itself.
    static func canvas(for kind: Artifact.Kind, dark: Bool) -> RGBA {
        switch kind {
        case .diagram: dark ? Palette.background.dark : Palette.background.light
        case .webPage, .image, .component, .document, .code: browserCanvas
        }
    }

    /// The page for `artifact`: Web pages as written, SVG and Mermaid wrapped.
    static func page(for artifact: Artifact, allowsNetwork: Bool = false, dark: Bool = false) -> String {
        switch artifact.kind {
        case .webPage: html(artifact.content, allowsNetwork: allowsNetwork)
        case .image: svg(artifact.content)
        case .diagram: mermaid(artifact.content, dark: dark)
        case .component, .document, .code: html("<pre>\(escaped(artifact.content))</pre>", allowsNetwork: false)
        }
    }

    /// `source` with the CSP (and a mobile viewport, when missing) as the first tags of `<head>`.
    static func html(_ source: String, allowsNetwork: Bool) -> String {
        var head = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(allowsNetwork ? networkPolicy : offlinePolicy)\">"
        if source.range(of: #"<meta[^>]+name\s*=\s*["']?viewport"#, options: [.regularExpression, .caseInsensitive]) == nil {
            head += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        }
        if let range = source.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: range, with: source[range] + head)
        }
        if let range = source.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: range, with: source[range] + "<head>\(head)</head>")
        }
        if let range = source.range(of: #"<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: range, with: source[range] + "<head>\(head)</head>")
        }
        return "<!doctype html><html><head>\(head)</head><body>\(source)</body></html>"
    }

    /// An SVG centred on a white canvas (scripts are off for images).
    static func svg(_ source: String) -> String {
        html("""
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; height: 100%; background: #fff; }
        body { display: flex; align-items: center; justify-content: center; }
        svg { max-width: 100%; max-height: 100vh; height: auto; }
        </style></head><body>\(source)</body></html>
        """, allowsNetwork: false)
    }

    /// A Mermaid source in a `<pre class="mermaid">`; `mermaidBootstrap` draws it.
    static func mermaid(_ source: String, dark: Bool) -> String {
        html("""
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; background: \(dark ? Palette.background.dark.hexString : Palette.background.light.hexString); color: \(dark ? Palette.textPrimary.dark.hexString : Palette.textPrimary.light.hexString); }
        body { padding: 16px; font: -apple-system-body; }
        .mermaid { display: flex; justify-content: center; margin: 0; }
        .mermaid svg { max-width: 100%; height: auto; }
        .error { white-space: pre-wrap; font: -apple-system-footnote; color: \(dark ? Palette.destructive.dark.hexString : Palette.destructive.light.hexString); }
        </style></head><body><pre class="mermaid">\(escaped(source))</pre></body></html>
        """, allowsNetwork: false)
    }

    /// Runs after the bundled `mermaid.min.js`: draws every `.mermaid` block, or explains why not.
    static func mermaidBootstrap(dark: Bool) -> String {
        """
        (function () {
          function fail(error) {
            var note = document.createElement('pre');
            note.className = 'error';
            note.textContent = 'This diagram couldn\\u2019t be drawn. ' + (error && error.message ? error.message : String(error));
            document.body.appendChild(note);
          }
          try {
            mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: '\(dark ? "dark" : "default")' });
            mermaid.run({ querySelector: '.mermaid' }).catch(fail);
          } catch (error) { fail(error); }
        })();
        """
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
