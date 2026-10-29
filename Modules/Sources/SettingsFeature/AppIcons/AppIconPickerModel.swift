import Foundation
public import Observation

/// Settings › App Icon (BRAND-02): the shipped icons, which one is current, and switching.
/// The system (`UIApplication.alternateIconName`) is the source of truth: nothing is persisted.
/// The model re-reads it on appear and after every switch, but never *while* a switch is in
/// flight: then the getter blocks the main thread until iOS's confirmation alert is dismissed,
/// and the alert can't show (seen on iOS 27.0), so views read the last value instead.
@MainActor
@Observable
public final class AppIconPickerModel {
    /// The picker's sections, in `icons.json` order.
    public let sections = AppIconCatalog.sections
    /// The icon being switched to, while iOS applies it.
    public private(set) var pendingIcon: AppIconOption?
    /// Why the last switch failed, shown as a toast until dismissed.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let switcher: any AppIconSwitching
    /// `alternateIconName` as last read from the system.
    private var systemName: String?

    public init(switcher: any AppIconSwitching) {
        self.switcher = switcher
        systemName = switcher.supportsAlternateIcons ? switcher.alternateIconName : nil
    }

    public var isSupported: Bool { switcher.supportsAlternateIcons }

    /// The icon on the home screen right now.
    public var current: AppIconOption {
        AppIconCatalog.option(forAlternateIconName: systemName)
    }

    public func isCurrent(_ icon: AppIconOption) -> Bool {
        current == icon
    }

    /// Re-reads the system's icon (on appear: it may have changed outside the app's view).
    public func refresh() {
        guard pendingIcon == nil, switcher.supportsAlternateIcons else { return }
        systemName = switcher.alternateIconName
    }

    /// Switches the home-screen icon. Tapping the current icon does nothing.
    public func select(_ icon: AppIconOption) async {
        guard pendingIcon == nil, !isCurrent(icon) else { return }
        pendingIcon = icon
        errorMessage = nil
        defer {
            pendingIcon = nil
            refresh()
        }
        do {
            try await switcher.setAlternateIconName(icon.alternateIconName)
        } catch {
            errorMessage = "Couldn't change the app icon. \(error.localizedDescription)"
        }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
