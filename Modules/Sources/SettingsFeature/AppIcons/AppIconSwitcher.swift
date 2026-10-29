import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The system's alternate-icon API, behind a seam so Settings › App Icon is testable and
/// previewable (BRAND-02). The system is the source of truth: nothing caches the current name.
@MainActor
public protocol AppIconSwitching: AnyObject {
    /// `UIApplication.supportsAlternateIcons`. Settings hides the App Icon row when it's false.
    var supportsAlternateIcons: Bool { get }
    /// `UIApplication.alternateIconName`: nil while the primary icon shows.
    var alternateIconName: String? { get }
    /// `UIApplication.setAlternateIconName(_:)`: nil restores the primary icon. iOS shows its own
    /// "You have changed the icon" alert.
    func setAlternateIconName(_ name: String?) async throws
}

#if canImport(UIKit)
/// The real switcher: `UIApplication.shared`.
public final class SystemAppIconSwitcher: AppIconSwitching {
    public init() {}

    public var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    public var alternateIconName: String? { UIApplication.shared.alternateIconName }

    public func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}
#endif

/// A platform without alternate icons (the macOS test host): the row stays hidden.
public final class UnsupportedAppIconSwitcher: AppIconSwitching {
    public init() {}
    public var supportsAlternateIcons: Bool { false }
    public var alternateIconName: String? { nil }
    public func setAlternateIconName(_ name: String?) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// An in-memory switcher for previews, tests and the UI-testing launch mode.
public final class FakeAppIconSwitcher: AppIconSwitching {
    public var supportsAlternateIcons: Bool
    public var alternateIconName: String?
    /// Thrown by the next `setAlternateIconName(_:)`, then cleared.
    public var nextError: (any Error)?
    /// Every name the app asked for, in order.
    public private(set) var requests: [String?] = []

    public init(supportsAlternateIcons: Bool = true, alternateIconName: String? = nil) {
        self.supportsAlternateIcons = supportsAlternateIcons
        self.alternateIconName = alternateIconName
    }

    public func setAlternateIconName(_ name: String?) async throws {
        requests.append(name)
        if let error = nextError {
            nextError = nil
            throw error
        }
        alternateIconName = name
    }
}

/// `SystemAppIconSwitcher` on iOS, `UnsupportedAppIconSwitcher` elsewhere.
@MainActor
func systemAppIconSwitcher() -> any AppIconSwitching {
    #if canImport(UIKit)
    SystemAppIconSwitcher()
    #else
    UnsupportedAppIconSwitcher()
    #endif
}
