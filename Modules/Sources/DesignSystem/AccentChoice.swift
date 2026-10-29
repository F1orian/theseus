public import Observation
import Synchronization

/// The accent pigment the owner picks in Settings › Appearance (#179, brand.md §1 "Accent
/// choices"). Verdigris is the default and the brand's identity; Ultramarine and Oxblood are the
/// other two pigments from the brand board. The choice recolours `Palette.accent`, `onAccent` and
/// `accentSoft` everywhere; app icons don't change with it.
///
/// Raw values are persisted (`AccountPreferences`): never rename them.
public enum AccentChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case verdigris
    case ultramarine
    case oxblood

    public static let `default`: AccentChoice = .verdigris

    public var id: Self { self }

    /// The pigment's name, as Settings shows it.
    public var displayName: String {
        switch self {
        case .verdigris: "Verdigris"
        case .ultramarine: "Ultramarine"
        case .oxblood: "Oxblood"
        }
    }

    /// The colour of this choice's swatch: its `accent` (light/dark and Increase Contrast aware),
    /// whatever the current choice is.
    public var swatch: ColorToken { tokens.accent }

    /// This choice's `accent`, `onAccent` and `accentSoft` (values from #179). Every pair meets
    /// WCAG 4.5:1 (`DesignTokenTests`).
    public var tokens: AccentTokens {
        switch self {
        case .verdigris: AccentTokens(
            accent: ColorToken(
                light: RGBA(hex: 0x2C6656), dark: RGBA(hex: 0x7CC7B0),
                highContrastLight: RGBA(hex: 0x1F4D41), highContrastDark: RGBA(hex: 0xA3DCCB)
            ),
            onAccent: ColorToken(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x0B1F19)),
            accentSoft: ColorToken(light: RGBA(hex: 0xDDEBE6), dark: RGBA(hex: 0x17302A))
        )
        case .ultramarine: AccentTokens(
            accent: ColorToken(
                light: RGBA(hex: 0x2A3DB0), dark: RGBA(hex: 0x93A4FF),
                highContrastLight: RGBA(hex: 0x1F2E8A), highContrastDark: RGBA(hex: 0xB9C4FF)
            ),
            onAccent: ColorToken(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x0B1033)),
            accentSoft: ColorToken(light: RGBA(hex: 0xE3E6F7), dark: RGBA(hex: 0x1B2240))
        )
        case .oxblood: AccentTokens(
            accent: ColorToken(
                light: RGBA(hex: 0x7E2234), dark: RGBA(hex: 0xF08C9C),
                highContrastLight: RGBA(hex: 0x5E1726), highContrastDark: RGBA(hex: 0xF7B3BE)
            ),
            onAccent: ColorToken(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x2A0A12)),
            accentSoft: ColorToken(light: RGBA(hex: 0xF1DFE2), dark: RGBA(hex: 0x33161D))
        )
        }
    }
}

/// The three accent tokens of one `AccentChoice`.
public struct AccentTokens: Sendable, Hashable {
    /// Send, the primary action, live state. Once per screen.
    public let accent: ColorToken
    /// Text and icons placed on `accent`.
    public let onAccent: ColorToken
    /// A quiet wash of the accent: the user's message bubble, selected rows.
    public let accentSoft: ColorToken
}

/// The process-wide current `AccentChoice` that `Palette.accent`, `onAccent` and `accentSoft`
/// resolve against (ADR 0145).
///
/// Reading `choice` registers an Observation dependency, so every SwiftUI `body` that read one
/// of the accent tokens is invalidated when the app sets a new choice, and re-renders with the
/// new colour in place: no `.id()` reset, navigation and sheet state survive. It's thread-safe
/// (a `Mutex`), so tokens can be read off the main actor too (CSS for web views); set it from
/// the main actor, where SwiftUI expects its invalidations.
///
/// Only the app sets it (AppFeature, from the Account's preferences). Extensions never do, so
/// the widget and Share extension stay Verdigris (there's no App Group to share the choice yet).
public final class AccentSelection: Observable, Sendable {
    /// The selection the palette reads.
    public static let shared = AccentSelection()

    private let registrar = ObservationRegistrar()
    private let storage: Mutex<AccentChoice>

    public init(_ choice: AccentChoice = .default) {
        storage = Mutex(choice)
    }

    public var choice: AccentChoice {
        get {
            registrar.access(self, keyPath: \.choice)
            return storage.withLock { $0 }
        }
        set {
            guard storage.withLock({ $0 }) != newValue else { return }
            registrar.withMutation(of: self, keyPath: \.choice) {
                storage.withLock { $0 = newValue }
            }
        }
    }
}
