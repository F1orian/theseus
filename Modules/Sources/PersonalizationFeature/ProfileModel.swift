import Foundation
public import Observation
public import OpenWebUIKit

/// The Profile page (PERS-01, with PERS-02 inline): Full name (`user.name`), Nickname
/// (`theseus.profile.nickname`, ADR 0012) and, when the `instructions` Capability resolves, profile
/// Instructions (`ui.system`, ADR 0030). The check button saves only what changed.
@MainActor
@Observable
public final class ProfileModel {
    public var fullName = ""
    public var nickname = ""
    public var instructions = ""
    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    /// Whether the Instructions section shows (`chat.controls` + `chat.system_prompt`).
    public let showsInstructions: Bool
    /// Called with the new full name after it was saved, so the app can refresh the Account.
    @ObservationIgnored public var onNameChange: (@MainActor (String) -> Void)?

    private var saved = Saved()
    @ObservationIgnored private let client: OpenWebUIClient

    private struct Saved: Equatable {
        var fullName = ""
        var nickname = ""
        var instructions = ""
    }

    public init(client: OpenWebUIClient, capabilities: Capabilities) {
        self.client = client
        showsInstructions = capabilities.contains(.instructions)
    }

    /// Whether anything differs from what the Server has (fills the check button).
    public var hasChanges: Bool {
        isLoaded && (nameChanged || nicknameChanged || instructionsChanged)
    }

    /// Whether the check button is enabled: there are changes and the full name isn't blank.
    public var canSave: Bool {
        hasChanges && !isSaving && !fullName.trimmed.isEmpty
    }

    private var nameChanged: Bool { fullName.trimmed != saved.fullName }
    private var nicknameChanged: Bool { nickname.trimmed != saved.nickname }
    private var instructionsChanged: Bool { showsInstructions && instructions != saved.instructions }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let profile = client.send(.userProfile)
            async let settings = client.send(.userSettings)
            let (loadedProfile, loadedSettings) = try await (profile, settings)
            saved = Saved(
                fullName: loadedProfile.name,
                nickname: loadedSettings.profilePreferences.nickname ?? "",
                instructions: loadedSettings.instructions
            )
            fullName = saved.fullName
            nickname = saved.nickname
            instructions = saved.instructions
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = (error as? OpenWebUIError)?.message ?? "Couldn't load your profile."
        }
    }

    /// Saves the changed fields one by one. Parts that saved stay saved; a failure leaves the rest
    /// pending with an error message.
    public func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        var failure: OpenWebUIError?

        if nameChanged {
            do {
                let stored = try await client.updateProfileName(fullName)
                saved.fullName = stored.name
                fullName = stored.name
                onNameChange?(stored.name)
            } catch {
                failure = error
            }
        }
        if nicknameChanged {
            let value = nickname.trimmed
            do {
                let stored = try await client.updateTheseusSettings { namespace in
                    var preferences = UserSettings(raw: ["theseus": .object(namespace)]).profilePreferences
                    preferences.nickname = value.isEmpty ? nil : value
                    if let json = try? preferences.jsonValue() {
                        namespace[ProfilePreferences.namespaceKey] = json
                    }
                }
                saved.nickname = stored.profilePreferences.nickname ?? ""
                nickname = saved.nickname
            } catch {
                failure = error
            }
        }
        if instructionsChanged {
            let value = instructions
            do {
                let stored = try await client.updateInstructions(value)
                if stored.instructions == value {
                    saved.instructions = value
                } else {
                    failure = .forbidden(detail: InstructionsModel.droppedMessage)
                }
            } catch {
                failure = error
            }
        }
        errorMessage = failure.map { "Couldn't save your profile. \($0.message)" }
    }

    public func dismissError() {
        errorMessage = nil
    }
}

/// The Instructions page (PERS-02): one free-text field applied to every Chat. Stored at
/// `ui.system`, shared with the Open WebUI web client (ADR 0030).
@MainActor
@Observable
public final class InstructionsModel {
    static let droppedMessage = "This Server doesn't let your account change Instructions."

    public var text = ""
    public private(set) var isLoaded = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private var saved = ""
    @ObservationIgnored private let client: OpenWebUIClient

    public init(client: OpenWebUIClient) {
        self.client = client
    }

    public var hasChanges: Bool {
        isLoaded && text != saved
    }

    public func load() async {
        do {
            saved = try await client.send(.userSettings).instructions
            text = saved
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.message
        }
    }

    public func save() async {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let value = text
        do {
            let stored = try await client.updateInstructions(value)
            // The server silently drops `ui.system` without chat.controls + chat.system_prompt.
            guard stored.instructions == value else {
                errorMessage = Self.droppedMessage
                return
            }
            saved = value
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save your Instructions. \(error.message)"
        }
    }

    public func dismissError() {
        errorMessage = nil
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
