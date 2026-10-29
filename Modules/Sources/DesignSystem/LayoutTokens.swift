public import CoreGraphics
public import SwiftUI

/// The spacing scale (points). Use these instead of literals so rhythm stays consistent.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// The full scale, smallest first.
    public static let scale: [CGFloat] = [xxs, xs, s, m, l, xl, xxl, xxxl]
}

/// Corner radii.
public enum Radius {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 20
    /// Fully rounded ends (buttons, chips).
    public static let capsule: CGFloat = 999
}

/// Type styles (docs/design/brand.md §2). Display text and titles use New York (the serif design):
/// greetings, screen titles, empty-state headlines. Body and UI text use SF Pro. Small labels use the
/// plaque face, Departure Mono (`Typography.plaque`, `.plaqueStyle()`). All styles are Dynamic Type
/// relative.
public enum Typography {
    public static let display = Font.system(.largeTitle, design: .serif)
    public static let title = Font.system(.title2, design: .serif).weight(.medium)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.callout
    public static let caption = Font.caption
    public static let code = Font.system(.body, design: .monospaced)
}
