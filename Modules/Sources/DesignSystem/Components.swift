public import SwiftUI

/// The filled accent button used for primary actions ("Continue", "Sign in").
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(Palette.onAccent.color)
            .background(Palette.accent.color, in: .rect(cornerRadius: Radius.medium))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    public static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// A rounded input field container on `surface`.
public struct FieldBackground: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(Typography.body)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 50)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
    }
}

extension View {
    /// Styles a `TextField`/`SecureField` as a Theseus input.
    public func fieldStyle() -> some View {
        modifier(FieldBackground())
    }

    /// Fills the background with `Palette.background`, edge to edge.
    public func themedBackground() -> some View {
        background(Palette.background.color.ignoresSafeArea())
    }
}

extension Text {
    /// English UI copy held in a `String` (a row's caption, a model's description). Theseus's UI
    /// is English, but without a language SwiftUI typesets text in the device's language, and a
    /// German device hyphenates English with German rules ("spreads-heets", "infor-mation").
    /// `typesettingLanguage(_:)` on the root fixes that except in `List` rows, so rows say it here.
    public init(ui copy: String) {
        var attributed = AttributedString(copy)
        attributed.languageIdentifier = "en"
        self.init(attributed)
    }
}
