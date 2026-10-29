import Foundation
import Fixtures
@testable import SettingsFeature
import Testing

/// BRAND-02: the generated icon catalog matches what the app target compiles, and the picker
/// switches through the `AppIconSwitching` seam.
@Suite("App icons")
struct AppIconCatalogTests {
    /// The repository root, from this file's path (Modules/Tests/SettingsFeatureTests/…).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A build setting's value from project.yml (`KEY: value` or `KEY: "a b c"`).
    private static func buildSetting(_ key: String) throws -> String {
        let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        let line = try #require(project.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") })
        return line.split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    @Test func primaryIsTheAppIconBuildSetting() throws {
        #expect(try Self.buildSetting("ASSETCATALOG_COMPILER_APPICON_NAME") == AppIconCatalog.primary.name)
        #expect(AppIconCatalog.primary.name == "AppIcon")
        #expect(AppIconCatalog.primary.title == "Renoir")
        #expect(AppIconCatalog.all.filter(\.isPrimary).count == 1)
    }

    @Test func alternatesAreTheAlternateIconBuildSetting() throws {
        let names = try Self.buildSetting("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES").split(separator: " ").map(String.init)
        #expect(names == AppIconCatalog.alternateNames)
        #expect(names.count == 11)
    }

    @Test func everyIconHasAnIconComposerPackage() throws {
        let packages = try FileManager.default.contentsOfDirectory(atPath: Self.root.appending(path: "App/Icons").path())
            .filter { $0.hasSuffix(".icon") }
            .map { String($0.dropLast(".icon".count)) }
        #expect(Set(packages) == Set(AppIconCatalog.all.map(\.name)))
    }

    @Test(arguments: AppIconCatalog.all)
    func thumbnailLoads(icon: AppIconOption) {
        #expect(icon.hasThumbnail, "\(icon.name) has no thumbnail in AppIconThumbnails.xcassets")
    }

    @Test func aMissingThumbnailIsNoticed() {
        #expect(!AppIconOption(name: "AppIcon-Missing", title: "", group: .pixel, credit: "", isPrimary: false).hasThumbnail)
    }

    @Test func sectionsFollowIconsJSON() {
        #expect(AppIconCatalog.sections.map(\.group) == [.paintings, .cheese, .roomsAndLedges, .pixel])
        #expect(AppIconCatalog.sections.map(\.icons.count) == [6, 3, 2, 1])
        #expect(AppIconCatalog.sections.flatMap(\.icons) == AppIconCatalog.all)
    }

    @Test func artworksAreCreditedAndPixelArtIsNot() {
        for icon in AppIconCatalog.all {
            #expect(icon.credit.isEmpty == (icon.group == .pixel), "\(icon.name)")
        }
    }

    @Test func currentIconFromTheSystemName() {
        #expect(AppIconCatalog.option(forAlternateIconName: nil).isPrimary)
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet").title == "Monet")
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-Removed").isPrimary)
        #expect(AppIconCatalog.primary.alternateIconName == nil)
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet").alternateIconName == "AppIcon-Monet")
    }

    @Test func accessibilityLabelsNameTheWorkAndTheCurrentIcon() {
        #expect(AppIconCatalog.primary.accessibilityLabel(isCurrent: true) == "Renoir, Fruits of the Midi, current icon")
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet").accessibilityLabel(isCurrent: false) == "Monet, Apples and Grapes")
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-PixelMousehole").accessibilityLabel(isCurrent: false) == "Mousehole")
        #expect(AppIconCatalog.primary.shortCredit == "Fruits of the Midi · 1881")
        #expect(AppIconCatalog.option(forAlternateIconName: "AppIcon-PixelMousehole").shortCredit == nil)
    }
}

@MainActor
@Suite("App icon picker")
struct AppIconPickerModelTests {
    @Test func currentIsReadFromTheSwitcher() {
        let switcher = FakeAppIconSwitcher(alternateIconName: "AppIcon-Monet")
        let model = AppIconPickerModel(switcher: switcher)
        #expect(model.current.name == "AppIcon-Monet")
        #expect(model.isCurrent(AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet")))
        #expect(!model.isCurrent(AppIconCatalog.primary))
    }

    @Test func selectingAnAlternateAndBackToThePrimary() async {
        let switcher = FakeAppIconSwitcher()
        let model = AppIconPickerModel(switcher: switcher)
        await model.select(AppIconCatalog.option(forAlternateIconName: "AppIcon-PixelMousehole"))
        #expect(model.current.name == "AppIcon-PixelMousehole")
        await model.select(AppIconCatalog.primary)
        #expect(model.current.isPrimary)
        #expect(switcher.requests == ["AppIcon-PixelMousehole", nil])
        #expect(model.pendingIcon == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func selectingTheCurrentIconDoesNothing() async {
        let switcher = FakeAppIconSwitcher()
        let model = AppIconPickerModel(switcher: switcher)
        await model.select(AppIconCatalog.primary)
        #expect(switcher.requests.isEmpty)
    }

    @Test func aFailedSwitchShowsAnErrorAndKeepsTheIcon() async {
        let switcher = FakeAppIconSwitcher()
        switcher.nextError = CocoaError(.featureUnsupported)
        let model = AppIconPickerModel(switcher: switcher)
        await model.select(AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet"))
        #expect(model.current.isPrimary)
        #expect(model.errorMessage?.hasPrefix("Couldn't change the app icon.") == true)
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test func refreshRereadsTheSystem() {
        let switcher = FakeAppIconSwitcher()
        let model = AppIconPickerModel(switcher: switcher)
        #expect(model.current.isPrimary)
        switcher.alternateIconName = "AppIcon-HammershoiSun"  // changed outside the picker
        model.refresh()
        #expect(model.current.name == "AppIcon-HammershoiSun")
    }

    /// `UIApplication.alternateIconName` blocks while a switch is in flight, so the model must not
    /// read it until `setAlternateIconName` returns.
    @Test func theSystemNameIsNotReadWhileASwitchIsInFlight() async {
        let switcher = SuspendingIconSwitcher()
        let model = AppIconPickerModel(switcher: switcher)
        let monet = AppIconCatalog.option(forAlternateIconName: "AppIcon-Monet")
        let selecting = Task { await model.select(monet) }
        while !switcher.isSetting { await Task.yield() }
        #expect(model.pendingIcon == monet)
        model.refresh()
        #expect(model.current.isPrimary)
        #expect(switcher.readsWhileSetting == 0)
        switcher.finish()
        await selecting.value
        #expect(model.current == monet)
        #expect(model.pendingIcon == nil)
    }

    @Test(arguments: [true, false])
    func settingsShowsTheRowOnlyWithAlternateIconSupport(supported: Bool) {
        let model = SettingsModel(
            account: testAccount,
            client: makeClient(StubTransport()),
            preferences: AccountPreferencesStore(accountID: testAccount.id, defaults: makeDefaults()),
            capabilities: capabilities(),
            appIconSwitcher: FakeAppIconSwitcher(supportsAlternateIcons: supported),
            actions: ActionLog().actions
        )
        #expect(model.showsAppIconRow == supported)
    }

    @Test func settingsDefaultsToTheSystemSwitcher() {
        let model = SettingsModel(
            account: testAccount,
            client: makeClient(StubTransport()),
            preferences: AccountPreferencesStore(accountID: testAccount.id, defaults: makeDefaults()),
            capabilities: capabilities(),
            actions: ActionLog().actions
        )
        #if canImport(UIKit)
        _ = model.showsAppIconRow
        #else
        #expect(!model.showsAppIconRow, "macOS has no alternate icons")
        #endif
    }
}

/// A switcher whose `setAlternateIconName` waits for `finish()`, counting reads in between.
@MainActor
private final class SuspendingIconSwitcher: AppIconSwitching {
    var supportsAlternateIcons: Bool { true }
    private var name: String?
    private(set) var isSetting = false
    private(set) var readsWhileSetting = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var alternateIconName: String? {
        if isSetting { readsWhileSetting += 1 }
        return name
    }

    func setAlternateIconName(_ name: String?) async throws {
        isSetting = true
        await withCheckedContinuation { continuation = $0 }
        self.name = name
        isSetting = false
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
