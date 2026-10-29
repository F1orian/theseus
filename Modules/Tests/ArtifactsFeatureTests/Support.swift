import Fixtures
import Foundation
import OpenWebUIKit

final class StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

func makeClient(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
}
