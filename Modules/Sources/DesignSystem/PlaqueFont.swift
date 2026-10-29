public import SwiftUI
import CoreText
import Foundation

/// Departure Mono, the plaque face (docs/design/brand.md §2, ADR 0140): small uppercase labels
/// such as museum plaques under artworks, `THINKING…`, `OPUS 5.5 ▾` and dates. **Only for labels
/// at 13 pt or smaller**, never body text or chat content. Bundled with DesignSystem (SIL OFL 1.1)
/// and registered for this process the first time a plaque font is asked for.
public enum PlaqueFont {
    /// The PostScript name of the bundled face.
    public static let postScriptName = "DepartureMono-Regular"
    /// The design size the face is drawn on (its pixel grid is 11 pt): sizes that are multiples
    /// of it render crispest.
    public static let defaultSize: CGFloat = 11

    /// Registers the bundled face with Core Text, once per process. Idempotent and safe from any
    /// thread (a `static let` initialiser runs exactly once); `Font.plaque` calls it for you.
    /// Returns whether the face is available (registered now, or already registered).
    @discardableResult
    public static func register() -> Bool {
        registration
    }

    private static let registration: Bool = {
        guard let url = Bundle.module.url(forResource: "DepartureMono-Regular", withExtension: "otf", subdirectory: "Fonts")
        else { return false }
        // The singular call is synchronous, so the face exists before the first `Font.custom`
        // resolves (`CTFontManagerRegisterFontURLs` reports through an asynchronous handler).
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        // Another copy of the module (a test host, an extension) may have registered it first.
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }()

    /// The SIL Open Font License text that ships with Departure Mono, for Settings › About.
    public static let licence: String = {
        guard let url = Bundle.module.url(forResource: "DepartureMono-LICENSE", withExtension: "txt", subdirectory: "Fonts"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "Departure Mono is licensed under the SIL Open Font License, Version 1.1." }
        return text
    }()

    /// The credit line for the face.
    public static let credit = "Departure Mono by Helena Zhang · SIL Open Font License 1.1"
}

extension Font {
    /// Departure Mono at `size`, scaling with Dynamic Type relative to `textStyle`.
    ///
    /// The default is `.caption`, not `.caption2`: caption 2 stays at 11 pt from Extra Small to
    /// Large, so text scaled with it doesn't change at those sizes and the accessibility audit
    /// reports it as "Dynamic Type font sizes are partially unsupported" (BRAND-03).
    ///
    /// Pass the environment's `dynamicTypeSize` to fall back to SF Mono at accessibility sizes,
    /// where the pixel face gets too coarse; `View.plaqueFont(_:relativeTo:)` and
    /// `View.plaqueStyle()` do that for you, so prefer them in views.
    public static func plaque(
        _ size: CGFloat = PlaqueFont.defaultSize,
        relativeTo textStyle: Font.TextStyle = .caption,
        dynamicTypeSize: DynamicTypeSize? = nil
    ) -> Font {
        if let dynamicTypeSize, dynamicTypeSize.isAccessibilitySize {
            return .system(textStyle, design: .monospaced)
        }
        PlaqueFont.register()
        return .custom(PlaqueFont.postScriptName, size: size, relativeTo: textStyle)
    }
}

extension Typography {
    /// The plaque face at its design size (11 pt, relative to `.caption`). Use it through
    /// `.plaqueStyle()` to get uppercase, `textTertiary` and the SF Mono fallback.
    public static var plaque: Font { .plaque() }
}

extension View {
    /// Departure Mono at `size`, relative to `textStyle`; SF Mono at accessibility text sizes.
    public func plaqueFont(_ size: CGFloat = PlaqueFont.defaultSize, relativeTo textStyle: Font.TextStyle = .caption) -> some View {
        modifier(PlaqueFontModifier(size: size, textStyle: textStyle))
    }

    /// A plaque label: Departure Mono, uppercase, slightly tracked, in `textTertiary` (pass a
    /// `color` for the rare plaque that isn't). `Text("Thinking…").plaqueStyle()` reads
    /// `THINKING…`.
    public func plaqueStyle(
        _ size: CGFloat = PlaqueFont.defaultSize,
        relativeTo textStyle: Font.TextStyle = .caption,
        color: ColorToken = Palette.textTertiary
    ) -> some View {
        plaqueFont(size, relativeTo: textStyle)
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(color.color)
    }
}

private struct PlaqueFontModifier: ViewModifier {
    let size: CGFloat
    let textStyle: Font.TextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.plaque(size, relativeTo: textStyle, dynamicTypeSize: dynamicTypeSize))
    }
}

#Preview("Plaque labels") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        Text("Thinking…").plaqueStyle()
        Text("Thought for 12 s ›").plaqueStyle()
        Text("Opus 5.5 ▾").plaqueStyle(13, relativeTo: .footnote, color: Palette.textPrimary)
        Text("Added 12 Oct").plaqueStyle()
        Text("Accessibility size falls back to SF Mono").plaqueStyle()
            .dynamicTypeSize(.accessibility2)
    }
    .padding()
    .themedBackground()
}
