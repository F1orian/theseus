public import ChatDomain
import Foundation

/// Decodes an OpenAI-compatible Server-Sent Events body (`data: {chunk}` … `data: [DONE]`) into
/// `ResponseEvent`s. Used by the stateless fallback path (ADR 0003).
public enum SSEDecoder {
    /// Events for every `data:` payload. Multi-line `data:` fields are joined with `\n` as the
    /// SSE spec says; blank lines end an event; comments (`:`) and other fields are ignored.
    public static func events<Lines: AsyncSequence & Sendable>(_ lines: Lines) -> AsyncThrowingStream<ResponseEvent, any Error>
    where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var data: [String] = []
                    func flush() -> Bool {
                        defer { data.removeAll() }
                        guard !data.isEmpty else { return false }
                        let payload = data.joined(separator: "\n")
                        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                            continuation.yield(.completed(output: nil))
                            return true
                        }
                        for event in decode(payload) { continuation.yield(event) }
                        return false
                    }
                    for try await line in lines {
                        if line.isEmpty {
                            if flush() { break }
                        } else if line.hasPrefix("data:") {
                            var value = line.dropFirst(5)
                            if value.first == " " { value = value.dropFirst() }
                            data.append(String(value))
                        }
                    }
                    _ = flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One `data:` payload: a `chat.completion.chunk`, or `{"error": …}` mid-stream.
    public static func decode(_ payload: String) -> [ResponseEvent] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { return [] }
        if let error = json[path: "error"], error != .null {
            let message = error.stringValue ?? error[path: "message"]?.stringValue ?? error[path: "detail"]?.stringValue
            return [.failed(message ?? "Something went wrong.")]
        }
        if json[path: "type"]?.stringValue?.hasPrefix("response.") == true {
            return ChatEventDecoder.responseCompletion(json)
        }
        return ChatEventDecoder.chatCompletionChunk(json)
    }
}
