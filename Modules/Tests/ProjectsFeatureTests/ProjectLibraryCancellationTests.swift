import Fixtures
import Foundation
import OpenWebUIKit
@testable import ProjectsFeature
import Testing

/// A transport whose requests are all cancelled, like a screen's `.task` when the user leaves it.
private struct CancelledTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw OpenWebUIError.transport(.cancelled)
    }
}

/// Leaving a Project's screen cancels its loads; that's no error to show (#130: the "A network
/// error occurred." notice sat over the header and swallowed taps).
@MainActor
@Suite("ProjectLibrary cancellation")
struct ProjectLibraryCancellationTests {
    @Test func cancelledLoadsShowNoNotice() async {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: CancelledTransport(), authorizer: StaticAuthorizer())
        let library = ProjectLibrary(client: client)
        library.capabilities = Capabilities(enabled: [.projects])
        await library.loadDetails("p")
        await library.loadChats(in: "p")
        #expect(library.errorMessage == nil)
    }
}
