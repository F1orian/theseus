public import ChatDomain
import Foundation

extension OpenWebUIClient {
    /// `GET /api/v1/chats/all`: every Chat of the Account, streamed as NDJSON (one `ChatResponse`
    /// per line). `keep` sees each raw line first, so callers can skip decoding Chats they don't
    /// need (the export of a busy Account runs to tens of megabytes). Undecodable lines are skipped.
    public func exportChats(keepingLinesWhere keep: @Sendable (String) -> Bool = { _ in true }) async throws(OpenWebUIError) -> [Chat] {
        let lines = try await streamLines(Endpoint<JSONValue>(method: .get, path: "api/v1/chats/all", authentication: .required))
        var chats: [Chat] = []
        do {
            for try await line in lines where !line.isEmpty && keep(line) {
                if let wire = try? WireCoding.decoder.decode(ChatWire.self, from: Data(line.utf8)) {
                    chats.append(wire.domain)
                }
            }
        } catch let error as OpenWebUIError {
            throw error
        } catch {
            throw .transport(.networkConnectionLost)
        }
        return chats
    }
}
