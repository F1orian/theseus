@testable import ChatDomain
import Foundation
import Testing

/// Open WebUI's `<details>` serialization of Thinking and tool calls (imported Chats, #180).
@Suite("Serialized content")
struct SerializedContentTests {
    private let content = """
    <details type="reasoning" done="true" duration="2">
    <summary>Thought for 2 seconds</summary>
    > First line.
    >
    > Second line.
    </details>
    <details type="tool_calls" done="true" id="toolu_1" name="web_search" arguments="&quot;{\\&quot;query\\&quot;: \\&quot;tea &amp; cake\\&quot;}&quot;" result="&quot;It&#x27;s fine&quot;" files="">
    <summary>Tool Executed</summary>
    </details>
    Here's the **answer**.

    ```html
    <details type="reasoning"><summary>Not a block: it's code</summary></details>
    ```
    <details type="tool_calls" done="true" id="" name="artifacts" arguments="&quot;{}&quot;" result="" files="">
    <summary>Tool Executed</summary>
    </details>
    The end.
    """

    @Test func blocksBecomeSegmentsInOrder() throws {
        let segments = SerializedContent.segments(content)
        #expect(segments.count == 5)
        #expect(segments[0] == .reasoning(text: "First line.\n\nSecond line.", duration: 2, isOpen: false))
        guard case .toolCall(let search) = segments[1], case .text(let answer) = segments[2],
              case .toolCall(let artifact) = segments[3], case .text(let end) = segments[4]
        else {
            Issue.record("unexpected segments \(segments)")
            return
        }
        // Arguments and results are HTML-escaped JSON strings holding JSON.
        #expect(search.id == "toolu_1")
        #expect(search.name == "web_search")
        #expect(search.arguments == #"{"query": "tea & cake"}"#)
        #expect(search.result == "It's fine")
        #expect(!search.isRunning)
        // `<details>` inside a code fence is code, not a block.
        #expect(answer.hasPrefix("Here's the **answer**."))
        #expect(answer.contains("<details type=\"reasoning\"><summary>Not a block"))
        // A call without an id gets a stable one.
        #expect(artifact.id == "serialized-tool-1")
        #expect(end == "The end.")
    }

    @Test func plainTextDropsTheBlocks() {
        let text = SerializedContent.plainText(content)
        #expect(!text.contains("<details type=\"tool_calls\""))
        #expect(!text.contains("Thought for"))
        #expect(text.hasPrefix("Here's the **answer**."))
        #expect(text.hasSuffix("The end."))
        #expect(SerializedContent.plainText("No blocks.") == "No blocks.")
    }

    @Test func anOpenBlockRunsToTheEnd() {
        let segments = SerializedContent.segments("Before.\n<details type=\"reasoning\" done=\"false\">\n<summary>Thinking…</summary>\n> Still going")
        #expect(segments == [.text("Before."), .reasoning(text: "Still going", duration: nil, isOpen: true)])
    }

    @Test func otherBlockKindsKeepTheirContentAsText() {
        let segments = SerializedContent.segments("<details type=\"code_interpreter\" done=\"true\">\n<summary>Analyzed</summary>\nprint(1)\n</details>\nAfter.")
        #expect(segments == [.text("print(1)"), .text("After.")])
    }

    /// The attribute scanner reads tags exactly as the regex it replaced (compiled again for every
    /// tag, it dominated opening long imported Chats).
    @Test(arguments: [
        #"details type="tool_calls" done="true" id="toolu_1" name="web_search" arguments="&quot;{}&quot;" result="" files="""#,
        #"details type = "reasoning"  done="false"duration="3""#,
        #"details data-x:y_z="1" ="orphan" bare type="a" broken="unterminated"#,
        #"details 9type="digit-led" ty pe="split" t="" u="a b > c""#,
        "details\ttype=\t\"tab\"\nname=\"multi\nline\"",
        "", "details", #"="x""#, #"a="b"c="d""#, #"é="no" ok="yes""#, #"x="1" x="2""#,
        "a\u{301}=\"accent\" b=\"plain\"",
    ])
    func attributesMatchTheRegexTheyReplaced(tag: String) {
        var expected: [String: String] = [:]
        var rest = Substring(tag)
        while let match = rest.firstMatch(of: /([A-Za-z_:-]+)\s*=\s*"([^"]*)"/) {
            expected[String(match.output.1)] = SerializedContent.decodeEntities(String(match.output.2))
            rest = rest[match.range.upperBound...]
        }
        #expect(SerializedContent.attributes(in: Substring(tag)) == expected)
    }

    @Test func entitiesDecode() {
        #expect(SerializedContent.decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#x27; &bogus; & f") == "a & b <c> \"d\" 'e' &bogus; & f")
    }

    /// The transcript showed the raw `<details>` markup of imported Chats (#180).
    @Test func storedMessagesWithSerializedBlocksBecomeParts() {
        let state = ResponseState(output: [], content: content, isDone: true)
        let kinds = state.parts.map { part -> String in
            switch part {
            case .thinking: "thinking"
            case .text: "text"
            case .tools(_, let tools): "tools:" + tools.map(\.name).joined(separator: ",")
            default: "other"
            }
        }
        #expect(kinds == ["thinking", "tools:web_search", "text", "tools:artifacts", "text"])
        #expect(!state.text.contains("<details type=\"tool_calls\""))
        #expect(state.toolSteps(named: ToolActivity.artifactsName).map(\.id) == ["serialized-tool-1"])
        #expect(ResponseState(output: [], content: "Plain.", isDone: true).toolSteps(named: ToolActivity.artifactsName).isEmpty)
    }
}
