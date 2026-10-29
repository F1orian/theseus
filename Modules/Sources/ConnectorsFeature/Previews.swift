#if DEBUG
import Foundation
import OpenWebUIKit

/// A canned Server for SwiftUI previews: three kinds of Connectors, one MCP server not connected.
final class PreviewTransport: HTTPTransport {
    static let tools = #"""
    [
      {"id":"weather","name":"Weather","meta":{"description":"Current conditions and forecasts."}},
      {"id":"server:crm","name":"Customer records","meta":{"description":"Look up accounts and orders."}},
      {"id":"server:mcp:linear","name":"Linear","meta":{"description":"Issues, projects and cycles."},"authenticated":false},
      {"id":"server:mcp:docs","name":"Company docs","meta":{"description":"Search handbooks and policies."},"authenticated":true}
    ]
    """#

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.url?.path() == "/api/v1/tools/" ? Data(Self.tools.utf8) : Data("true".utf8)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw URLError(.badURL) }
        return (body, response)
    }
}

extension OpenWebUIClient {
    static var preview: OpenWebUIClient {
        OpenWebUIClient(server: URL(string: "https://owui.example.com") ?? URL(fileURLWithPath: "/"), transport: PreviewTransport())
    }
}

extension ConnectorDirectory {
    @MainActor static var preview: ConnectorDirectory {
        let entries = (try? JSONDecoder().decode([ToolEntry].self, from: Data(PreviewTransport.tools.utf8))) ?? []
        return ConnectorDirectory(client: .preview, connectors: entries)
    }
}

@MainActor
final class PreviewLocationProvider: LocationProviding {
    var authorization: LocationAuthorization = .allowed
    func requestAuthorization() async -> LocationAuthorization { authorization }
    func currentCoordinate() async -> Coordinate? { Coordinate(latitude: 48.1372, longitude: 11.5756) }
}

extension LocationSharing {
    @MainActor static var preview: LocationSharing {
        LocationSharing(accountKey: "preview", provider: PreviewLocationProvider())
    }
}
#endif
