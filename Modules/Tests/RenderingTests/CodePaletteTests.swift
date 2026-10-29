import DesignSystem
@testable import Rendering
import Testing

/// BRAND-03: highlighted code stays legible on the code block's `recessedSurface`.
@Suite("Code palette (BRAND-03)")
struct CodePaletteTests {
    @Test func everyTokenKindMeetsAAOnTheCodeBlock() {
        let surface = Palette.recessedSurface
        for token in [CodePalette.keyword, CodePalette.string, CodePalette.comment, CodePalette.number, CodePalette.type] {
            #expect(RGBA.contrast(token.light, surface.light) >= 4.5, "\(token.light.hexString) on light")
            #expect(RGBA.contrast(token.dark, surface.dark) >= 4.5, "\(token.dark.hexString) on dark")
        }
    }
}
