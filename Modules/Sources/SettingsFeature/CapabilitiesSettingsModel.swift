public import Observation
public import OpenWebUIKit

/// The Capabilities page (SET-05): defaults for new Chats, one switch per optional Capability the
/// Server and the Account's permissions allow (ADR 0006). Choices roam in the user settings at
/// `theseus.capabilities` (ADR 0012). The safety model-fallback switch (SET-12) and Tool access
/// (CONN-06) have no Open WebUI equivalent and are omitted.
@MainActor
@Observable
public final class CapabilitiesSettingsModel {
    public enum Row: String, Hashable, Sendable, CaseIterable {
        case artifacts
        /// Code execution and file creation in the Server's sandbox (Open Terminal, ADR 0120).
        case sandbox
        case codeInterpreter
        case webSearch
        case imageGeneration
        /// Ask before tools run (OT-06), when the Server allows tool approvals.
        case askBeforeTools

        /// The Capability that must resolve for the row to show; `nil` = client-side only.
        var capability: Capability? {
            switch self {
            case .artifacts: nil
            case .sandbox: .sandbox
            case .codeInterpreter: .codeInterpreter
            case .webSearch: .webSearch
            case .imageGeneration: .imageGeneration
            case .askBeforeTools: .toolApprovals
            }
        }
    }

    public private(set) var defaults = CapabilityDefaults()
    /// Follow-up suggestions under the latest Response (`ui.autoFollowUps`, #141). Off until chosen.
    public private(set) var followUps = false
    /// The Server's active Skills (#140), listed read-only; empty when it has none.
    public private(set) var skills: [Skill] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public let capabilities: Capabilities

    @ObservationIgnored private let client: OpenWebUIClient
    /// Writes run one after another so each read-modify-write sees the previous one.
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    public init(client: OpenWebUIClient, capabilities: Capabilities) {
        self.client = client
        self.capabilities = capabilities
    }

    /// The switches to show, in display order.
    public var rows: [Row] {
        Row.allCases.filter { row in
            // One code execution row: the sandbox when the Server has one, else the interpreter.
            if row == .codeInterpreter, capabilities.contains(.sandbox) { return false }
            return row.capability.map(capabilities.contains) ?? true
        }
    }

    /// Whether the Memory section (PERS-03) shows.
    public var showsMemory: Bool {
        capabilities.contains(.memory)
    }

    public func isOn(_ row: Row) -> Bool {
        switch row {
        case .artifacts: defaults.artifacts
        case .sandbox: defaults.sandbox
        case .codeInterpreter: defaults.codeInterpreter
        case .webSearch: defaults.webSearch
        case .imageGeneration: defaults.imageGeneration
        case .askBeforeTools: defaults.askBeforeTools
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let settings = try await client.send(.userSettings)
            defaults = settings.capabilityDefaults
            followUps = settings.followUpsPreference ?? false
            errorMessage = nil
            skills = ((try? await client.send(.skills)) ?? [])
                .filter(\.isActive)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.message
        }
    }

    /// Flips `row` at once and saves it; reverts with an error message if the Server refuses.
    public func set(_ row: Row, on: Bool) async {
        let previous = pendingWrite
        let task = Task { [weak self] in
            await previous?.value
            await self?.write(row, on: on)
        }
        pendingWrite = task
        apply(row, on: on, to: &defaults)
        await task.value
    }

    private func write(_ row: Row, on: Bool) async {
        do {
            let stored = try await client.updateTheseusSettings { namespace in
                var current = UserSettings(raw: ["theseus": .object(namespace)]).capabilityDefaults
                CapabilitiesSettingsModel.apply(row, on: on, to: &current)
                if let value = try? current.jsonValue() {
                    namespace[CapabilityDefaults.namespaceKey] = value
                }
            }
            defaults = stored.capabilityDefaults
            errorMessage = nil
        } catch {
            apply(row, on: !on, to: &defaults)
            errorMessage = "Couldn't save your choice. \(error.message)"
        }
    }

    /// Turns follow-up suggestions on or off, shared with the web client (`ui.autoFollowUps`).
    public func setFollowUps(_ on: Bool) async {
        followUps = on
        do {
            followUps = try await client.updateFollowUpsPreference(on).followUpsPreference ?? on
            errorMessage = nil
        } catch {
            followUps = !on
            errorMessage = "Couldn't save your choice. \(error.message)"
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    private func apply(_ row: Row, on: Bool, to defaults: inout CapabilityDefaults) {
        Self.apply(row, on: on, to: &defaults)
    }

    nonisolated private static func apply(_ row: Row, on: Bool, to defaults: inout CapabilityDefaults) {
        switch row {
        case .artifacts: defaults.artifacts = on
        case .sandbox: defaults.sandbox = on
        case .codeInterpreter: defaults.codeInterpreter = on
        case .webSearch: defaults.webSearch = on
        case .imageGeneration: defaults.imageGeneration = on
        case .askBeforeTools: defaults.askBeforeTools = on
        }
    }
}
