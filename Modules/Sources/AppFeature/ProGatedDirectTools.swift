import Entitlements
import OpenWebUIKit

/// Personal connectors (direct tool servers, #186) in chats are Theseus Pro (ADR 0173): in the
/// free tier no `tool_servers` go out, so the model never sees their tools and the Server never
/// asks this device to run one. Setting them up in Settings › Connectors stays free.
struct ProGatedDirectTools: DirectToolServers {
    let base: any DirectToolServers
    let pro: ProStore

    func toolServersPayload() async -> [JSONValue] {
        guard await pro.allows(.connectors) else { return [] }
        return await base.toolServersPayload()
    }

    func execute(_ call: DirectToolCall) async -> JSONValue {
        await base.execute(call)
    }
}
