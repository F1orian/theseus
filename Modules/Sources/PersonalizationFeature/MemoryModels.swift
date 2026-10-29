import ChatDomain
public import Foundation
public import Observation
public import OpenWebUIKit

/// The Memory section of the Capabilities page (PERS-03): the "Remember things from my chats"
/// switch (`ui.memory`, shared with the web client, ADR 0030) and the "View your memory" row with
/// when Memory last changed. Shows only when the `memory` Capability resolves (ADR 0006).
@MainActor
@Observable
public final class MemorySettingsModel {
    /// The switch. `ui.memory` unset means on, like the web client.
    public private(set) var isOn = true
    public private(set) var errorMessage: String?
    /// The Memory entries behind the "View your memory" row and sheet.
    public let summary: MemorySummaryModel
    public let isAvailable: Bool

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    public init(client: OpenWebUIClient, capabilities: Capabilities) {
        self.client = client
        isAvailable = capabilities.contains(.memory)
        summary = MemorySummaryModel(client: client)
    }

    public func load() async {
        guard isAvailable else { return }
        async let entries: Void = summary.load()
        do {
            isOn = try await client.send(.userSettings).memoryPreference ?? true
            errorMessage = nil
        } catch {
            errorMessage = error.message
        }
        await entries
    }

    /// Flips the switch at once and saves it; reverts with an error if the Server refuses.
    public func setOn(_ on: Bool) async {
        let previous = pendingWrite
        isOn = on
        let task = Task { [weak self] in
            await previous?.value
            await self?.write(on)
        }
        pendingWrite = task
        await task.value
    }

    private func write(_ on: Bool) async {
        do {
            let stored = try await client.updateMemoryPreference(on)
            isOn = stored.memoryPreference ?? on
            errorMessage = nil
        } catch {
            isOn = !on
            errorMessage = "Couldn't save your choice. \(error.message)"
        }
    }

    public func dismissError() {
        errorMessage = nil
    }
}

/// The Memory summary sheet (PERS-04). Open WebUI keeps discrete Memory entries rather than a
/// narrative, so the sheet lists them in sections by topic (`path`) and lets the user add, edit,
/// delete and forget everything.
@MainActor
@Observable
public final class MemorySummaryModel {
    public private(set) var entries: [MemoryEntry] = []
    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// Whether the sheet shows edit controls (the floating pencil toggles it).
    public var isEditing = false

    @ObservationIgnored private let client: OpenWebUIClient

    public init(client: OpenWebUIClient) {
        self.client = client
    }

    public var sections: [MemorySection] {
        MemorySection.group(entries)
    }

    /// Where the Memory lives ("chat.example.com"), for the summary's header.
    public var serverName: String {
        ServerDisplay.host(client.server, fallback: "your Server")
    }

    /// The plaque under an entry (BRAND-04): "Added today", "Added yesterday", "Added 12 Oct", or
    /// "Added 12 Oct 2025" before this year. Day-month order and English month names, like the
    /// rest of Theseus's English UI; the plaque style sets it in capitals.
    public nonisolated static func addedText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Added today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Added yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return "Added \(formatter.string(from: date))"
    }

    /// When any entry last changed.
    public var lastUpdated: Date? {
        entries.map(\.updatedAt).max()
    }

    /// "Updated 12 hr ago", or `nil` when there is nothing in Memory.
    public func updatedText(relativeTo now: Date = .now) -> String? {
        guard let lastUpdated else { return nil }
        let relative = min(lastUpdated, now).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "Updated \(relative)"
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await client.send(.memories)
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.message
        }
    }

    /// Adds a fact about the user. `path` files it under a topic (e.g. `work/projects`).
    public func add(content: String, path: String?) async {
        let content = content.trimmed
        guard !content.isEmpty else { return }
        await perform("Couldn't add to Memory.") { client in
            let entry = try await client.send(.addMemory(content: content, kind: .user, path: Self.normalized(path)))
            entries.append(entry)
        }
    }

    public func update(_ entry: MemoryEntry, content: String, path: String?) async {
        let content = content.trimmed
        guard !content.isEmpty else { return }
        await perform("Couldn't save this memory.") { client in
            let stored = try await client.send(.updateMemory(id: entry.id, content: content, path: Self.normalized(path)))
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = stored
            }
        }
    }

    public func delete(_ entry: MemoryEntry) async {
        await perform("Couldn't delete this memory.") { client in
            _ = try await client.send(.deleteMemory(id: entry.id))
            entries.removeAll { $0.id == entry.id }
            if entries.isEmpty { isEditing = false }
        }
    }

    /// Deletes every Memory entry of the Account.
    public func forgetAll() async {
        await perform("Couldn't forget your memory.") { client in
            _ = try await client.send(.forgetAllMemories)
            entries = []
            isEditing = false
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    private func perform(_ failure: String, _ work: (OpenWebUIClient) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work(client)
            errorMessage = nil
        } catch {
            errorMessage = "\(failure) \((error as? OpenWebUIError)?.message ?? "Something went wrong.")"
        }
    }

    /// Trims a topic path and its slashes; empty means none.
    nonisolated static func normalized(_ path: String?) -> String? {
        let value = (path ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["/"]))
        return value.isEmpty ? nil : value
    }
}

/// One titled group of Memory entries in the summary sheet.
public struct MemorySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entries: [MemoryEntry]

    /// Groups entries: facts about the user without a topic first ("About you"), then one section
    /// per topic path (case-insensitive, alphabetical), then other context without a topic. Entries
    /// keep the order they were remembered in.
    public static func group(_ entries: [MemoryEntry]) -> [MemorySection] {
        let ordered = entries.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var about: [MemoryEntry] = []
        var other: [MemoryEntry] = []
        var byPath: [String: (title: String, entries: [MemoryEntry])] = [:]
        for entry in ordered {
            if let path = MemorySummaryModel.normalized(entry.path) {
                let key = path.lowercased()
                byPath[key, default: (title(for: path), [])].entries.append(entry)
            } else if entry.kind == .user {
                about.append(entry)
            } else {
                other.append(entry)
            }
        }
        var sections: [MemorySection] = []
        if !about.isEmpty { sections.append(MemorySection(id: "about", title: "About you", entries: about)) }
        for key in byPath.keys.sorted() {
            if let group = byPath[key] {
                sections.append(MemorySection(id: "path:\(key)", title: group.title, entries: group.entries))
            }
        }
        if !other.isEmpty { sections.append(MemorySection(id: "other", title: "Other context", entries: other)) }
        return sections
    }

    /// `work/side_projects` → "Work › Side projects".
    static func title(for path: String) -> String {
        path.split(separator: "/").map { part in
            let words = part.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }.joined(separator: " › ")
    }
}
