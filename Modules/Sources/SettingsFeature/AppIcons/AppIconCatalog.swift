import Foundation
public import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One home-screen icon the app ships (BRAND-02, ADR 0141): a layered Icon Composer package in
/// `App/Icons/<name>.icon`, compiled into the app's asset catalog. The values come from the brand
/// export's `icons.json` through `scripts/brand/gen_app_icons.py`.
public struct AppIconOption: Identifiable, Hashable, Sendable {
    /// The asset name: `AppIcon` for the primary, `AppIcon-*` for an alternate.
    public let name: String
    /// The picker's label, e.g. "Renoir" or "Hammershøi, mousehole".
    public let title: String
    public let group: Group
    /// The artwork's plaque ("Fruits of the Midi · Pierre-Auguste Renoir · 1881 · …"), or empty
    /// for the pixel-art icons.
    public let credit: String
    public let isPrimary: Bool

    public init(name: String, title: String, group: Group, credit: String, isPrimary: Bool) {
        self.name = name
        self.title = title
        self.group = group
        self.credit = credit
        self.isPrimary = isPrimary
    }

    public var id: String { name }

    /// The value for `UIApplication.setAlternateIconName(_:)`: nil restores the primary icon.
    public var alternateIconName: String? { isPrimary ? nil : name }

    /// The picker thumbnail: the flat ictool render at 180 px, already in the rounded-square shape.
    public var thumbnail: Image { Image(name, bundle: .module) }

    /// Whether the thumbnail is in the module's asset catalog (tests).
    var hasThumbnail: Bool {
        #if canImport(UIKit)
        UIImage(named: name, in: .module, with: nil) != nil
        #elseif canImport(AppKit)
        Bundle.module.image(forResource: name) != nil
        #else
        false
        #endif
    }
}

/// The icons the app ships, in picker order. `all` is generated (`AppIconCatalog+Generated.swift`).
public enum AppIconCatalog {
    /// The primary icon (`AppIcon`, Renoir).
    public static var primary: AppIconOption {
        all.first { $0.isPrimary } ?? all[0]
    }

    /// The alternates' names, as listed in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
    public static var alternateNames: [String] {
        all.filter { !$0.isPrimary }.map(\.name)
    }

    /// The picker's sections in order, each with its icons.
    public static var sections: [(group: AppIconOption.Group, icons: [AppIconOption])] {
        AppIconOption.Group.allCases.compactMap { group in
            let icons = all.filter { $0.group == group }
            return icons.isEmpty ? nil : (group, icons)
        }
    }

    /// The icon for `UIApplication.alternateIconName`: nil, or a name the app doesn't ship (an icon
    /// removed in an update), is the primary.
    public static func option(forAlternateIconName name: String?) -> AppIconOption {
        guard let name else { return primary }
        return all.first { $0.name == name } ?? primary
    }
}
