public import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An sRGB colour value. Tokens keep raw values (not just `Color`) so contrast is testable.
public struct RGBA: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// `RGBA(hex: 0xFAF9F5)`.
    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two opaque colours (1…21).
    public static func contrast(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        let (light, dark) = (max(lhs.relativeLuminance, rhs.relativeLuminance), min(lhs.relativeLuminance, rhs.relativeLuminance))
        return (light + 0.05) / (dark + 0.05)
    }

    /// `#RRGGBB` (alpha is dropped), for CSS in HTML the app renders (Artifacts, Mermaid).
    public var hexString: String {
        func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
        let value = byte(red) << 16 | byte(green) << 8 | byte(blue)
        let digits = String(value, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// The colour as a SwiftUI `Color` in sRGB, for values that don't adapt (sprite pixels).
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// A colour that adapts to light and dark appearance, and to Increase Contrast (PLAT-06).
public struct ColorToken: Sendable, Hashable {
    public let light: RGBA
    public let dark: RGBA
    /// The values under Settings › Accessibility › Increase Contrast; the regular ones by default.
    public let highContrastLight: RGBA
    public let highContrastDark: RGBA

    public init(light: RGBA, dark: RGBA, highContrastLight: RGBA? = nil, highContrastDark: RGBA? = nil) {
        self.light = light
        self.dark = dark
        self.highContrastLight = highContrastLight ?? light
        self.highContrastDark = highContrastDark ?? dark
    }

    public var color: Color {
        #if canImport(UIKit)
        let (light, dark) = (UIColor(light), UIColor(dark))
        let (highLight, highDark) = (UIColor(highContrastLight), UIColor(highContrastDark))
        return Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            return traits.userInterfaceStyle == .dark ? (high ? highDark : dark) : (high ? highLight : light)
        })
        #elseif canImport(AppKit)
        let (light, dark) = (NSColor(light), NSColor(dark))
        let (highLight, highDark) = (NSColor(highContrastLight), NSColor(highContrastDark))
        return Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastDarkAqua: highDark
            case .accessibilityHighContrastAqua: highLight
            default: light
            }
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(_ value: RGBA) {
        self.init(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(_ value: RGBA) {
        self.init(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
}
#endif

/// Theseus colours, "The Museum After Hours" (docs/design/brand.md §1, ADR 0140): cool gallery
/// plaster and ink neutrals, so the paintings and their gilt frames carry the warmth, and **one**
/// accent (verdigris by default; ultramarine or oxblood if chosen, `AccentChoice`), used once per
/// screen for the thing that matters (send, the primary action, live state). Every text token meets 4.5:1 on every surface in light, dark and Increase Contrast.
public enum Palette {
    /// Plaster / Nocturne: the app background behind lists and the transcript.
    public static let background = ColorToken(light: RGBA(hex: 0xF3F3F0), dark: RGBA(hex: 0x111318))
    /// Gesso / Slate: cards, the composer and grouped rows.
    public static let surface = ColorToken(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x1A1D24))
    /// Stone / Vault: sidebars and sheets that sit below `surface`.
    public static let recessedSurface = ColorToken(light: RGBA(hex: 0xE7E8E4), dark: RGBA(hex: 0x0B0D10))
    /// Ivory black / Moon white: body text, titles.
    public static let textPrimary = ColorToken(
        light: RGBA(hex: 0x16181D), dark: RGBA(hex: 0xECEBE6),
        highContrastLight: RGBA(hex: 0x000000), highContrastDark: RGBA(hex: 0xFFFFFF)
    )
    /// Graphite / Pewter: secondary labels and subtitles.
    public static let textSecondary = ColorToken(
        light: RGBA(hex: 0x4A505B), dark: RGBA(hex: 0xB4B7BF),
        highContrastLight: RGBA(hex: 0x343840), highContrastDark: RGBA(hex: 0xD7D9DE)
    )
    /// Placeholders, metadata and plaques. Meets 4.5:1 on every surface (PLAT-06), so it can carry
    /// small text.
    public static let textTertiary = ColorToken(
        light: RGBA(hex: 0x5F6571), dark: RGBA(hex: 0x8E929C),
        highContrastLight: RGBA(hex: 0x474C55), highContrastDark: RGBA(hex: 0xC2C5CC)
    )
    /// The single accent (Verdigris unless the owner picked another `AccentChoice`, #179): send,
    /// the primary action, live state. Once per screen.
    ///
    /// The three accent tokens resolve against `AccentSelection.shared` each time they're read, and
    /// reading them inside a SwiftUI `body` subscribes that view to the choice (ADR 0145). So read
    /// them where they're drawn; don't keep their `.color` in a `static let` or a stored property.
    public static var accent: ColorToken { AccentSelection.shared.choice.tokens.accent }
    /// Text and icons placed on `accent`.
    public static var onAccent: ColorToken { AccentSelection.shared.choice.tokens.onAccent }
    /// A quiet wash of the accent: the user's message bubble, selected rows. Text on it uses the
    /// text tokens.
    public static var accentSoft: ColorToken { AccentSelection.shared.choice.tokens.accentSoft }
    public static let separator = ColorToken(
        light: RGBA(hex: 0xDCDDD8), dark: RGBA(hex: 0x2A2E37),
        highContrastLight: RGBA(hex: 0x8E918A), highContrastDark: RGBA(hex: 0x6A707B)
    )
    public static let destructive = ColorToken(
        light: RGBA(hex: 0xB42318), dark: RGBA(hex: 0xF0736A),
        highContrastLight: RGBA(hex: 0x8F1B12), highContrastDark: RGBA(hex: 0xFF9C94)
    )
    /// Gilt, decorative only: the 2-pt rule of a picture frame. It's under 4.5:1 in light mode, so
    /// it's **never** used for text.
    public static let gilt = ColorToken(light: RGBA(hex: 0xC9A24A), dark: RGBA(hex: 0xD6AE55))
    /// The dark inner frame (the mat) between the gilt rule and a painting, in both appearances.
    public static let frameInk = ColorToken(light: RGBA(hex: 0x15130F), dark: RGBA(hex: 0x15130F))
}
