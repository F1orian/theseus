import Foundation

/// Sample Artifacts for `#Preview`s.
enum ArtifactPreviewData {
    static let page = """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Tip Calculator</title>
    <style>
      body { font-family: -apple-system, sans-serif; background: #fdf2f8; color: #831843; padding: 24px; }
      .card { background: #fff; border-radius: 12px; padding: 20px; box-shadow: 0 2px 8px #0001; }
      button { background: #db2777; color: #fff; border: 0; border-radius: 8px; padding: 10px 16px; font-size: 16px; }
    </style></head>
    <body><div class="card"><h1>Tip Calculator</h1>
    <p>Total: <strong id="total">$0.00</strong></p>
    <button onclick="document.getElementById('total').textContent = '$42.00'">Calculate</button></div></body>
    </html>
    """

    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
      <title>Sun icon</title>
      <circle cx="60" cy="60" r="22" fill="#facc15"/>
    </svg>
    """

    static let diagram = """
    graph TD
        A[Boil water] --> B[Warm the teapot]
        B --> C[Add tea]
        C --> D[Steep]
        D --> E[Serve]
    """

    static var catalog: ArtifactCatalog {
        ArtifactCatalog(responses: [
            .init(messageID: "m1", text: "Here you go.\n\n```html\n\(page)\n```"),
            .init(messageID: "m2", text: "In pink.\n\n```html\n\(page)\n```"),
            .init(messageID: "m3", text: "```svg\n\(svg)\n```"),
            .init(messageID: "m4", text: "```mermaid\n\(diagram)\n```"),
        ])
    }

    static var writing: Artifact {
        Artifact(messageID: "m5", index: 0, kind: .webPage, language: "html", title: "Web page", content: "<div>", isComplete: false)
    }
}
