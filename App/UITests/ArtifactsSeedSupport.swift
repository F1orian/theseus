import XCTest

/// Creates and deletes the walkthrough's `[theseus-test]` Chats through the REST API.
struct SeedServer: Sendable {
    struct Sample: Sendable {
        let name: String
        let slug: String
        /// The assistant Message's whole content.
        let content: String
        /// The library item's title, or `nil` when the Response holds no Artifact.
        let expectedTitle: String?
        var typeLabel = ""
        /// The page sets no background: it must sit on a light canvas (#180).
        var checksCanvas = false
        /// Also opened from its Chat's card.
        var opensFromChat = false

        static func fenced(
            _ name: String, title: String?, type: String = "", checksCanvas: Bool = false, opensFromChat: Bool = false,
            slug: String, fence: String, body: String
        ) -> Sample {
            Sample(name: name, slug: slug, content: "Here it is:\n\n```\(fence)\n\(body)\n```\n", expectedTitle: title,
                   typeLabel: type, checksCanvas: checksCanvas, opensFromChat: opensFromChat)
        }
    }

    /// One call of Claude's `artifacts` tool as Open WebUI serializes it in an imported Chat:
    /// the arguments JSON-encoded twice, then HTML-escaped.
    static func serializedArtifactCall(id: String, _ arguments: [String: String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let literal = (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let escaped = literal.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#x27;")
        return "<details type=\"tool_calls\" done=\"true\" id=\"\(id)\" name=\"artifacts\" arguments=\"\(escaped)\" result=\"&quot;OK&quot;\" files=\"\">\n<summary>Tool Executed</summary>\n</details>\n"
    }

    static let prefix = "[theseus-test] Artifacts library "

    let base: URL
    let token: String

    init(url: String, email: String, password: String) async throws {
        base = URL(string: url)!
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let response = try await Self.send(base, "api/v1/auths/signin", method: "POST", body: body, token: nil)
        token = (response as? [String: Any])?["token"] as? String ?? ""
    }

    func seed(_ samples: [Sample]) async throws {
        try await deleteSeeded()
        // In the past, oldest first, so the last sample is the newest.
        let now = Int(Date().timeIntervalSince1970) - samples.count * 2 - 2
        for (offset, sample) in samples.enumerated() {
            let userID = UUID().uuidString.lowercased(), assistantID = UUID().uuidString.lowercased()
            let model = "claude-haiku-5-5"
            let user: [String: Any] = ["id": userID, "parentId": NSNull(), "childrenIds": [assistantID], "role": "user",
                                       "content": "Show me \(sample.name).", "timestamp": now + offset * 2, "models": [model]]
            let assistant: [String: Any] = ["id": assistantID, "parentId": userID, "childrenIds": [], "role": "assistant",
                                            "content": sample.content,
                                            "timestamp": now + offset * 2 + 1, "model": model, "done": true]
            let chat: [String: Any] = ["title": Self.prefix + sample.name, "models": [model],
                                       "history": ["messages": [userID: user, assistantID: assistant], "currentId": assistantID],
                                       "messages": [user, assistant], "timestamp": (now + offset * 2) * 1000]
            let body = try JSONSerialization.data(withJSONObject: ["chat": chat])
            _ = try await Self.send(base, "api/v1/chats/new", method: "POST", body: body, token: token)
        }
    }

    func deleteSeeded() async throws {
        var page = 1
        while true {
            guard let chats = try await Self.send(base, "api/v1/chats/?page=\(page)", method: "GET", body: nil, token: token) as? [[String: Any]],
                  !chats.isEmpty
            else { break }
            for chat in chats {
                guard let id = chat["id"] as? String, (chat["title"] as? String)?.hasPrefix(Self.prefix) == true else { continue }
                _ = try await Self.send(base, "api/v1/chats/\(id)", method: "DELETE", body: nil, token: token)
            }
            page += 1
        }
    }

    private static func send(_ base: URL, _ path: String, method: String, body: Data?, token: String?) async throws -> Any? {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try? JSONSerialization.jsonObject(with: data)
    }

    static let samples: [Sample] = [
        Sample.fenced("HTML page", title: "Tip Calculator", type: "Interactive artifact", slug: "html", fence: "html", body: """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Tip Calculator</title>
        <style>
          body { font-family: -apple-system, sans-serif; padding: 24px; background: #fff7f0; color: #222; }
          h1 { color: #c2410c; }
          .total { font-size: 28px; font-weight: 700; margin-top: 16px; }
        </style>
        </head>
        <body>
        <h1>Tip Calculator</h1>
        <label>Bill <input id="bill" type="number" value="42"></label>
        <label>Tip <input id="tip" type="range" min="0" max="30" value="15"></label>
        <div class="total" id="total"></div>
        <script>
          const bill = document.getElementById('bill'), tip = document.getElementById('tip');
          function update() { document.getElementById('total').textContent = 'Total: $' + (bill.value * (1 + tip.value / 100)).toFixed(2); }
          bill.oninput = tip.oninput = update; update();
        </script>
        </body>
        </html>
        """),
        Sample.fenced("HTML fragment", title: "Signup card", type: "Interactive artifact", checksCanvas: true, opensFromChat: true, slug: "html-fragment", fence: "html", body: """
        <style>
        .card { border: 2px solid #2563eb; border-radius: 12px; padding: 16px; margin: 16px; }
        .card h2 { color: #2563eb; margin: 0 0 8px; }
        .card p { color: #333; }
        .card button { background: #2563eb; color: white; border: 0; padding: 8px 16px; border-radius: 8px; }
        </style>
        <div class="card">
          <h2>Signup card</h2>
          <p>Join the newsletter for weekly updates.</p>
          <input type="email" placeholder="you@example.com">
          <button onclick="this.textContent='Thanks!'">Subscribe</button>
        </div>
        <script>
          document.querySelector('.card p').style.fontStyle = 'italic';
        </script>
        """),
        Sample.fenced("React component", title: "Counter Button", type: "Component", slug: "react", fence: "jsx", body: """
        import { useState } from "react";

        export default function CounterButton() {
          const [count, setCount] = useState(0);
          return (
            <div className="p-6 flex flex-col items-center gap-4">
              <h1 className="text-2xl font-bold">Counter</h1>
              <p className="text-lg">You clicked {count} times</p>
              <button
                className="rounded-lg bg-blue-600 px-4 py-2 text-white"
                onClick={() => setCount(count + 1)}
              >
                Click me
              </button>
            </div>
          );
        }
        """),
        Sample.fenced("SVG image", title: "Sun icon", type: "Image", slug: "svg", fence: "svg", body: """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
          <title>Sun icon</title>
          <circle cx="60" cy="60" r="24" fill="#f59e0b"/>
          <g stroke="#f59e0b" stroke-width="6" stroke-linecap="round">
            <line x1="60" y1="8" x2="60" y2="24"/><line x1="60" y1="96" x2="60" y2="112"/>
            <line x1="8" y1="60" x2="24" y2="60"/><line x1="96" y1="60" x2="112" y2="60"/>
          </g>
        </svg>
        """),
        Sample.fenced("Mermaid diagram", title: "Flowchart", type: "Diagram", slug: "mermaid", fence: "mermaid", body: """
        graph TD
          A[Boil water] --> B[Warm the pot]
          B --> C[Add tea leaves]
          C --> D[Pour water and steep]
          D --> E[Serve]
        """),
        Sample.fenced("Markdown document", title: "Weekend Trip Checklist", type: "Document", slug: "markdown", fence: "markdown", body: """
        # Weekend Trip Checklist

        A short packing list for two days in the mountains.

        ## Clothing
        - Rain jacket
        - Warm fleece
        - **Two** pairs of socks

        ## Gear
        1. Backpack (30 l)
        2. Headlamp
        3. Water bottle

        > Check the weather the night before.

        | Item | Qty |
        |------|-----|
        | Snacks | 4 |
        | Map | 1 |
        """),
        // #180: a snippet to paste elsewhere, which used to open as a blank "Web page".
        Sample.fenced("Script snippet", title: nil, slug: "script", fence: "html", body: """
        <script>
          document.addEventListener('DOMContentLoaded', function () {
            const meta = document.getElementById('product-meta');
            if (meta) {
              const data = JSON.parse(meta.textContent);
              const button = document.querySelector('a.btn[href="#product"]');
              if (button) {
                const url = new URL(data.url);
                url.searchParams.append('ref', 'blog');
                button.href = url.toString();
              }
            }
          });
        </script>
        """),
        // #180: a Chat imported from Claude: Thinking and Claude's `artifacts` calls serialized
        // in the content (create, then an edit: Version 2).
        Sample(
            name: "Claude import",
            slug: "imported",
            content: """
            <details type="reasoning" done="true" duration="2">
            <summary>Thought for 2 seconds</summary>
            > A packing list document fits.
            </details>
            I'll write it as a document.

            """
                + serializedArtifactCall(id: "toolu_create", [
                    "command": "create", "id": "packing_list", "type": "text/markdown", "title": "Packing List",
                    "content": "# Packing List\n\n- Tent\n- Stove\n- Socks",
                ])
                + serializedArtifactCall(id: "toolu_update", ["command": "update", "id": "packing_list", "old_str": "- Socks", "new_str": "- Socks\n- Rain jacket"])
                + "Added the rain jacket.\n",
            expectedTitle: "Packing List",
            typeLabel: "Document",
            opensFromChat: true
        ),
    ]
}

extension XCUIScreenshot {
    /// The brightness (0…1) of the pixel at `point` (in screen points), or `nil` outside.
    func brightness(at point: CGPoint) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / image.size.width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
