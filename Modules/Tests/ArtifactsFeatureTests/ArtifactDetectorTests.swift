@testable import ArtifactsFeature
import Testing

@Suite("Artifact detection (ADR 0060)")
struct ArtifactDetectorTests {
    private func lines(_ count: Int, _ line: String = "<p>line</p>") -> String {
        Array(repeating: line, count: count).joined(separator: "\n")
    }

    @Test func fullHTMLDocumentIsAWebPageWhateverItsSize() {
        let text = "Here you go.\n\n```html\n<!DOCTYPE html>\n<html><head><title>Tip &amp; Split</title></head><body></body></html>\n```\n"
        let artifacts = ArtifactDetector.artifacts(messageID: "m", text: text)
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.kind == .webPage)
        #expect(artifacts.first?.title == "Tip & Split")
        #expect(artifacts.first?.id == "m/0")
        #expect(artifacts.first?.isComplete == true)
    }

    @Test func shortHTMLSnippetStaysCode() {
        let text = "Use a tag:\n\n```html\n<b>bold</b>\n```\n"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: text).isEmpty)
        let long = "```html\n\(lines(ArtifactDetector.minimumLines))\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: long).first?.title == "Web page")
    }

    @Test func htmlFallsBackToTheFirstHeading() {
        let text = "```html\n<body><h1 class=\"x\">Hello <em>world</em></h1></body>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: text).first?.title == "Hello world")
    }

    /// #180: the library showed pasted `<script>` snippets as blank "Web page" Artifacts.
    @Test func htmlSnippetsThatShowNothingStayCode() {
        let script = "```html\n<script>\n  document.addEventListener('DOMContentLoaded', function () {\n\(lines(12, "    console.log('x');"))\n  });\n</script>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: script).isEmpty)
        let style = "```html\n<style>\n\(lines(12, ".a { color: red; }"))\n</style>\n<!-- nothing else -->\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: style).isEmpty)
        // A script that builds the page itself, or a fragment with markup, still shows something.
        let builder = "```html\n<script>\n\(lines(12, "document.body.appendChild(document.createElement('p'));"))\n</script>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: builder).map(\.kind) == [.webPage])
        let form = "```html\n<style>\n\(lines(10, ".card { padding: 8px; }"))\n</style>\n<div class=\"card\">\n  <h2>Signup <b>card</b></h2>\n  <button>Go</button>\n</div>\n```"
        let found = ArtifactDetector.artifacts(messageID: "m", text: form)
        #expect(found.map(\.kind) == [.webPage])
        // Fragments without `<title>` or `<h1>` take their first `<h2>`/`<h3>` as the title.
        #expect(found.first?.title == "Signup card")
    }

    @Test func svgAndSVGInXMLAreImages() {
        let svg = "```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\"><title>Sun icon</title><circle r=\"4\"/></svg>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: svg).map(\.kind) == [.image])
        #expect(ArtifactDetector.artifacts(messageID: "m", text: svg).first?.title == "Sun icon")
        let xml = "```xml\n<?xml version=\"1.0\"?>\n<svg viewBox=\"0 0 1 1\"></svg>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: xml).first?.title == "Image")
        let plainXML = "```xml\n<note><to>Tove</to></note>\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: plainXML).isEmpty)
    }

    @Test(arguments: [
        ("graph TD\n  A --> B", "Flowchart"),
        ("sequenceDiagram\n  A->>B: hi", "Sequence diagram"),
        ("%% comment\nerDiagram\n  A ||--o{ B : has", "Entity relationship diagram"),
        ("pie title Pets adopted\n  \"Dogs\" : 386", "Pets adopted"),
        ("---\ntitle: Tea time\n---\nflowchart LR\n  A-->B", "Tea time"),
        ("gantt\n  title Release plan\n  section A", "Release plan"),
        ("somethingNew\n  x", "Diagram"),
    ])
    func mermaidTitles(source: String, title: String) {
        let artifacts = ArtifactDetector.artifacts(messageID: "m", text: "```mermaid\n\(source)\n```")
        #expect(artifacts.first?.kind == .diagram)
        #expect(artifacts.first?.title == title)
    }

    @Test func componentsAndDocumentsNeedSomeSize() {
        let component = "```jsx\nimport { useState } from 'react';\n\(lines(12, "// line"))\nexport default function TipCalculator() { return <div/>; }\n```"
        let found = ArtifactDetector.artifacts(messageID: "m", text: component)
        #expect(found.first?.kind == .component)
        #expect(found.first?.title == "Tip Calculator")
        #expect(found.first?.hasPreview == false)
        #expect(ArtifactDetector.artifacts(messageID: "m", text: "```jsx\nconst a = <b/>;\n```").isEmpty)

        let document = "```markdown\n# **Trip** plan\n\(lines(12, "- item"))\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: document).first?.title == "Trip plan")
        #expect(ArtifactDetector.artifacts(messageID: "m", text: "```md\n# Short\n```").isEmpty)
    }

    @Test func ordinaryCodeIsNeverAnArtifact() {
        let text = "```swift\n\(lines(80, "print(1)"))\n```\n\n```\nplain\n```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: text).isEmpty)
    }

    @Test func codeInListsAndQuotesCounts() {
        let text = "1. Step one:\n\n   ```mermaid\n   graph TD\n     A-->B\n   ```\n\n> ```svg\n> <svg></svg>\n> ```"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: text).map(\.kind) == [.diagram, .image])
    }

    @Test func anOpenFenceWhileStreamingIsAWritingArtifact() {
        let text = "Here's the page.\n\n```html\n<div>"
        let streaming = ArtifactDetector.artifacts(messageID: "m", text: text, isStreaming: true)
        #expect(streaming.count == 1)
        #expect(streaming.first?.isComplete == false)
        // The same text in a finished Response is a short snippet: code.
        #expect(ArtifactDetector.artifacts(messageID: "m", text: text, isStreaming: false).isEmpty)
        // Closed fences are complete even while the Response streams on.
        let closed = "```mermaid\ngraph TD\n A-->B\n```\n\nMore text"
        #expect(ArtifactDetector.artifacts(messageID: "m", text: closed, isStreaming: true).first?.isComplete == true)
    }

    @Test func openFenceTracking() {
        #expect(ArtifactDetector.hasOpenFence("```html\n<p>"))
        #expect(!ArtifactDetector.hasOpenFence("```html\n<p>\n```"))
        // A longer outer fence isn't closed by an inner, shorter one.
        #expect(ArtifactDetector.hasOpenFence("````markdown\n```swift\nx\n```\n"))
        #expect(!ArtifactDetector.hasOpenFence("~~~\n```\n~~~"))
    }

    @Test func toolEmbedsAreWebPagesAfterTheCodeBlocks() {
        let text = "```mermaid\ngraph TD\n A-->B\n```"
        let embeds = ["<html><head><title>Weather</title></head><body>☀️</body></html>", "https://example.com/view", "  "]
        let artifacts = ArtifactDetector.artifacts(messageID: "m", text: text, embeds: embeds)
        #expect(artifacts.map(\.kind) == [.diagram, .webPage])
        #expect(artifacts.last?.origin == .toolEmbed)
        #expect(artifacts.last?.title == "Weather")
        #expect(artifacts.last?.typeLabel == "Tool view")
        #expect(artifacts.last?.id == "m/1")
    }

    @Test func networkReferencesAreNoticed() {
        let cdn = Artifact(messageID: "m", index: 0, kind: .webPage, language: "html", title: "x",
                           content: "<script src=\"https://cdn.tailwindcss.com\"></script>")
        let offline = Artifact(messageID: "m", index: 0, kind: .webPage, language: "html", title: "x",
                               content: "<a href=\"#top\">Top</a><img src=\"data:image/png;base64,AA\">")
        #expect(cdn.referencesNetwork)
        #expect(!offline.referencesNetwork)
    }
}
