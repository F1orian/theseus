public import OpenWebUIKit
public import SettingsFeature
import SwiftUI

/// Plugs the Memory & personalization pages into the Settings sheet (`SettingsExtensions`):
/// Profile (PERS-01/02), Instructions (PERS-02), and Memory (PERS-03/04) both as its own page and as
/// the Memory section of the Capabilities page. The Settings sheet gates the Instructions row and the
/// Memory section by Capability; the pages gate their own parts too (ADR 0006).
public enum PersonalizationSettings {
    /// Registers every page.
    /// - Parameters:
    ///   - capabilities: read when a page opens, so it sees the Settings sheet's latest resolution.
    ///   - onNameChange: called after the full name was saved (the app can refresh the Account).
    @MainActor
    public static func register(
        in extensions: inout SettingsExtensions,
        client: OpenWebUIClient,
        capabilities: @escaping @MainActor () -> Capabilities,
        onNameChange: (@MainActor (String) -> Void)? = nil
    ) {
        extensions.register(.profile) {
            ProfileView(model: {
                let model = ProfileModel(client: client, capabilities: capabilities())
                model.onNameChange = onNameChange
                return model
            }())
        }
        extensions.register(.instructions) {
            InstructionsView(model: InstructionsModel(client: client))
        }
        extensions.register(.memory) {
            MemorySettingsPage(model: MemorySettingsModel(client: client, capabilities: capabilities()))
        }
        extensions.register(.capabilitiesMemory) {
            MemorySettingsSection(model: MemorySettingsModel(client: client, capabilities: capabilities()))
        }
    }
}
