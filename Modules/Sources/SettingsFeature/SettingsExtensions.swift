public import SwiftUI

/// Settings pages that other Feature areas own and plug into the Settings sheet.
public enum SettingsExtensionPage: String, Hashable, Sendable, CaseIterable {
    /// Profile: name, nickname, avatar (PERS-01, Memory & personalization epic).
    case profile
    /// Profile Instructions for all Chats (PERS-02).
    case instructions
    /// Memory settings and summary (PERS-03, PERS-04).
    case memory
    /// Styles (PERS-05).
    case styles
    /// Connectors (CONN-02, Connectors & tools epic).
    case connectors
    /// Device permissions (CONN-07).
    case permissions
    /// Voice settings (VOICE-06).
    case voice
    /// The model for new Chats (MODEL-04, Models & effort epic).
    case models
}

/// Sections other Feature areas place inside a built-in Settings page.
public enum SettingsExtensionSection: String, Hashable, Sendable, CaseIterable {
    /// The Memory section of the Capabilities page (PERS-03). It shows only when the `memory`
    /// Capability resolves; until registered it is a row that opens the `.memory` page.
    case capabilitiesMemory
}

/// One row of **Settings › Server administration** (#186): a page that changes the Server for
/// everyone on it. Only admins see the section. Feature areas contribute rows with
/// `SettingsExtensions.registerAdministration(_:)`; the section sorts them by `order`.
public struct SettingsAdministrationRow: Identifiable {
    /// Where well-known rows sit. Other areas may use any value in between.
    public enum Order {
        /// Connectors: the Server's tool-server connections (ConnectorsFeature).
        public static let connectors = 10
        /// User permissions: the default permissions of every non-admin user (SettingsFeature).
        public static let userPermissions = 20
        /// Skills shared on the Server (#187).
        public static let skills = 30
    }

    /// Stable id; the row's accessibility identifier is `settings.administration.<id>`.
    public let id: String
    public let title: String
    public let systemImage: String
    /// A short grey line under the title, e.g. "2 connections" (optional).
    public let subtitle: String?
    public let order: Int
    let destination: @MainActor () -> AnyView

    public init(
        id: String,
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        order: Int,
        @ViewBuilder destination: @escaping @MainActor () -> some View
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.order = order
        self.destination = { AnyView(destination()) }
    }
}

/// The pages other Feature areas registered. `AppFeature` builds this once per Account and hands
/// it to `SettingsModel.extensions`.
///
/// Profile, Instructions and Memory rows are always shown when their Capability resolves; until an
/// epic registers a page they open a placeholder. Styles, Connectors, Permissions and Voice rows
/// appear only once registered (the registering epic gates them by Capability, ADR 0006). So does
/// Models (MODEL-04).
public struct SettingsExtensions {
    private var pages: [SettingsExtensionPage: @MainActor () -> AnyView] = [:]
    private var sections: [SettingsExtensionSection: @MainActor () -> AnyView] = [:]
    private var administration: [String: SettingsAdministrationRow] = [:]

    public init() {}

    // MARK: Server administration (#186)

    /// Adds `row` to Settings › Server administration (admins only). Registering the same `id`
    /// again replaces the row.
    ///
    /// ```swift
    /// settings.extensions.registerAdministration(SettingsAdministrationRow(
    ///     id: "skills", title: "Skills", systemImage: "book.closed",
    ///     order: SettingsAdministrationRow.Order.skills
    /// ) { SkillsAdministrationPage(…) })
    /// ```
    public mutating func registerAdministration(_ row: SettingsAdministrationRow) {
        administration[row.id] = row
    }

    /// The contributed Server administration rows, by `order` then title.
    public var administrationRows: [SettingsAdministrationRow] {
        administration.values.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.title < rhs.title : lhs.order < rhs.order
        }
    }

    /// The registered view for the Server administration row `id`, or `nil`.
    @MainActor
    public func administrationDestination(for id: String) -> AnyView? {
        administration[id]?.destination()
    }

    /// Registers the destination view for `page`.
    public mutating func register(_ page: SettingsExtensionPage, @ViewBuilder destination: @escaping @MainActor () -> some View) {
        pages[page] = { AnyView(destination()) }
    }

    public func isRegistered(_ page: SettingsExtensionPage) -> Bool {
        pages[page] != nil
    }

    /// The registered view for `page`, or `nil`.
    @MainActor
    public func destination(for page: SettingsExtensionPage) -> AnyView? {
        pages[page]?()
    }

    /// Registers the content for `section` (one or more `Section`s of a Settings `List`).
    public mutating func register(_ section: SettingsExtensionSection, @ViewBuilder content: @escaping @MainActor () -> some View) {
        sections[section] = { AnyView(content()) }
    }

    /// The registered content for `section`, or `nil`.
    @MainActor
    public func content(for section: SettingsExtensionSection) -> AnyView? {
        sections[section]?()
    }
}
