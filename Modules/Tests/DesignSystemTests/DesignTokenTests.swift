import DesignSystem
import Testing

@Suite("Design tokens")
struct DesignTokenTests {
    enum Scheme: CaseIterable { case light, dark }

    func value(_ token: ColorToken, _ scheme: Scheme) -> RGBA {
        scheme == .light ? token.light : token.dark
    }

    @Test func contrastMath() {
        let black = RGBA(hex: 0x000000)
        let white = RGBA(hex: 0xFFFFFF)
        #expect(abs(RGBA.contrast(black, white) - 21) < 0.01)
        #expect(RGBA.contrast(white, white) == 1)
        #expect(RGBA.contrast(black, white) == RGBA.contrast(white, black))
    }

    /// Light, dark, and both Increase Contrast variants (PLAT-06, brand.md §1).
    enum Variant: CaseIterable, CustomTestStringConvertible {
        case light, dark, highContrastLight, highContrastDark

        func value(_ token: ColorToken) -> RGBA {
            switch self {
            case .light: token.light
            case .dark: token.dark
            case .highContrastLight: token.highContrastLight
            case .highContrastDark: token.highContrastDark
            }
        }

        var testDescription: String { "\(self)" }
    }

    static let surfaces: [(String, ColorToken)] = [
        ("background", Palette.background), ("surface", Palette.surface), ("recessedSurface", Palette.recessedSurface),
    ]
    static let textTokens: [(String, ColorToken)] = [
        ("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary),
        ("textTertiary", Palette.textTertiary), ("destructive", Palette.destructive),
    ]

    /// Every text token (tertiary text and destructive labels are text too) reaches WCAG AA 4.5:1 on
    /// all three surfaces, in every variant.
    @Test(arguments: Variant.allCases)
    func textMeetsWCAGAAOnEverySurface(variant: Variant) {
        for (surfaceName, surface) in Self.surfaces {
            for (textName, text) in Self.textTokens {
                let ratio = RGBA.contrast(variant.value(text), variant.value(surface))
                #expect(ratio >= 4.5, "\(textName) on \(surfaceName) is \(ratio):1 in \(variant)")
            }
        }
    }

    /// The accent labels buttons and links on the plain surfaces, and the user bubble keeps body
    /// text readable, for every accent choice (#179).
    @Test(arguments: AccentChoice.allCases, Variant.allCases)
    func accentAndAccentSoftCarryText(choice: AccentChoice, variant: Variant) {
        let tokens = choice.tokens
        for (surfaceName, surface) in Self.surfaces {
            let ratio = RGBA.contrast(variant.value(tokens.accent), variant.value(surface))
            #expect(ratio >= 4.5, "\(choice) accent on \(surfaceName) is \(ratio):1 in \(variant)")
        }
        for (textName, text) in Self.textTokens.prefix(3) {
            let ratio = RGBA.contrast(variant.value(text), variant.value(tokens.accentSoft))
            #expect(ratio >= 4.5, "\(textName) on \(choice) accentSoft is \(ratio):1 in \(variant)")
        }
    }

    @Test(arguments: AccentChoice.allCases, Variant.allCases)
    func labelsOnAccentAreReadable(choice: AccentChoice, variant: Variant) {
        let tokens = choice.tokens
        let ratio = RGBA.contrast(variant.value(tokens.onAccent), variant.value(tokens.accent))
        #expect(ratio >= 4.5, "\(choice) onAccent on accent is \(ratio):1 in \(variant)")
    }

    /// Increase Contrast never lowers the accent's contrast on a surface.
    @Test(arguments: AccentChoice.allCases, Scheme.allCases)
    func increaseContrastRaisesAccentContrast(choice: AccentChoice, scheme: Scheme) {
        let accent = choice.tokens.accent
        let high = scheme == .light ? accent.highContrastLight : accent.highContrastDark
        for (_, surface) in Self.surfaces {
            #expect(RGBA.contrast(high, value(surface, scheme)) > RGBA.contrast(value(accent, scheme), value(surface, scheme)))
        }
    }

    /// #179's table, pinned: the swatch is the accent, and the default is the brand's Verdigris.
    @Test func accentChoiceValues() {
        #expect(AccentChoice.default == .verdigris)
        #expect(AccentChoice.allCases.map(\.displayName) == ["Verdigris", "Ultramarine", "Oxblood"])
        #expect(AccentChoice.ultramarine.tokens.accent.light.hexString == "#2A3DB0")
        #expect(AccentChoice.ultramarine.tokens.accent.highContrastDark.hexString == "#B9C4FF")
        #expect(AccentChoice.oxblood.tokens.accent.dark.hexString == "#F08C9C")
        #expect(AccentChoice.oxblood.tokens.onAccent.dark.hexString == "#2A0A12")
        #expect(AccentChoice.oxblood.tokens.accentSoft.light.hexString == "#F1DFE2")
        #expect(AccentChoice.verdigris.tokens.accentSoft.dark.hexString == "#17302A")
        for choice in AccentChoice.allCases {
            #expect(choice.swatch == choice.tokens.accent)
        }
        #expect(Set(AccentChoice.allCases.map(\.tokens.accent)).count == 3)
    }

    /// brand.md §1 quotes these ratios; keep the spec honest.
    @Test func brandSpecRatios() {
        #expect(abs(RGBA.contrast(Palette.textTertiary.light, Palette.recessedSurface.light) - 4.76) < 0.02)
        let verdigris = AccentChoice.verdigris.tokens
        #expect(RGBA.contrast(verdigris.accent.light, Palette.background.light) >= 6.0 - 0.05)
        #expect(RGBA.contrast(verdigris.accent.dark, Palette.surface.dark) >= 8.6 - 0.05)
        #expect(RGBA.contrast(verdigris.onAccent.light, verdigris.accent.light) >= 6.7 - 0.05)
        #expect(RGBA.contrast(verdigris.onAccent.dark, verdigris.accent.dark) >= 8.7 - 0.05)
    }

    /// Gilt is decorative: in light mode it's too faint for text, which is why it never carries any.
    @Test func giltIsNotATextColour() {
        #expect(RGBA.contrast(Palette.gilt.light, Palette.background.light) < 4.5)
        #expect(Palette.frameInk.light == Palette.frameInk.dark)
    }

    @Test func hexStrings() {
        #expect(RGBA(hex: 0x2C6656).hexString == "#2C6656")
        #expect(RGBA(hex: 0x000A0B).hexString == "#000A0B")
        #expect(Palette.background.light.hexString == "#F3F3F0")
    }

    @Test(arguments: Scheme.allCases)
    func tertiaryAndAccentMeetNonTextContrast(scheme: Scheme) {
        for surface in [Palette.background, Palette.surface] {
            #expect(RGBA.contrast(value(Palette.textTertiary, scheme), value(surface, scheme)) >= 3)
            for choice in AccentChoice.allCases {
                #expect(RGBA.contrast(value(choice.tokens.accent, scheme), value(surface, scheme)) >= 3)
            }
            #expect(RGBA.contrast(value(Palette.destructive, scheme), value(surface, scheme)) >= 3)
        }
    }

    /// PLAT-06: Increase Contrast never lowers contrast, and secondary text reaches 7:1 (AAA).
    @Test(arguments: Scheme.allCases)
    func increaseContrastRaisesTextContrast(scheme: Scheme) {
        func high(_ token: ColorToken) -> RGBA { scheme == .light ? token.highContrastLight : token.highContrastDark }
        for surface in [Palette.background, Palette.surface, Palette.recessedSurface] {
            for text in [Palette.textPrimary, Palette.textSecondary, Palette.textTertiary] {
                let regular = RGBA.contrast(value(text, scheme), value(surface, scheme))
                let increased = RGBA.contrast(high(text), high(surface))
                #expect(increased >= regular)
            }
            #expect(RGBA.contrast(high(Palette.textSecondary), high(surface)) >= 7)
            #expect(RGBA.contrast(high(Palette.separator), high(surface)) > RGBA.contrast(value(Palette.separator, scheme), value(surface, scheme)))
        }
    }

    @Test func tokensWithoutHighContrastValuesKeepTheirOwn() {
        let token = ColorToken(light: RGBA(hex: 0x111111), dark: RGBA(hex: 0xEEEEEE))
        #expect(token.highContrastLight == token.light)
        #expect(token.highContrastDark == token.dark)
    }

    @Test func lightAndDarkDiffer() {
        for token in [Palette.background, Palette.surface, Palette.textPrimary, Palette.separator] {
            #expect(token.light != token.dark)
        }
        for tokens in AccentChoice.allCases.map(\.tokens) {
            #expect(tokens.accent.light != tokens.accent.dark)
            #expect(tokens.accentSoft.light != tokens.accentSoft.dark)
        }
    }

    @Test func spacingScaleIsStrictlyIncreasing() {
        #expect(Spacing.scale == Spacing.scale.sorted())
        #expect(Set(Spacing.scale).count == Spacing.scale.count)
        #expect(Radius.small < Radius.medium && Radius.medium < Radius.large)
    }
}
