import DesignSystem
public import SwiftUI
import SwiftMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders LaTeX to images with SwiftMath (native, no web view) and caches them (CHAT-05).
/// SwiftMath's font manager isn't thread-safe, so rendering stays on the main actor.
@MainActor
public final class MathRenderer {
    public static let shared = MathRenderer()

    public struct Rendered {
        public let image: Image
        public let size: CGSize
    }

    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let display: Bool
        let dark: Bool
    }

    private var cache: [Key: Rendered?] = [:]

    /// The rendered formula, or `nil` when SwiftMath can't parse it (callers show the source).
    public func render(_ latex: String, fontSize: CGFloat, display: Bool, dark: Bool) -> Rendered? {
        let key = Key(latex: latex, fontSize: fontSize, display: display, dark: dark)
        if let cached = cache[key] { return cached }
        let token = Palette.textPrimary
        let rgba = dark ? token.dark : token.light
        #if canImport(UIKit)
        let color = UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        #else
        let color = NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        #endif
        let renderer = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        let (error, image) = renderer.asImage()
        var result: Rendered?
        if error == nil, let image {
            #if canImport(UIKit)
            result = Rendered(image: Image(uiImage: image), size: image.size)
            #else
            result = Rendered(image: Image(nsImage: image), size: image.size)
            #endif
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// A display formula, horizontally scrollable when wide; falls back to its source.
struct MathBlockView: View {
    let latex: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 19

    var body: some View {
        if let rendered = MathRenderer.shared.render(latex, fontSize: fontSize, display: true, dark: colorScheme == .dark) {
            ScrollView(.horizontal, showsIndicators: false) {
                rendered.image
                    .frame(width: rendered.size.width, height: rendered.size.height)
                    .padding(.vertical, Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(Text(latex))
        } else {
            Text(latex)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Palette.textSecondary.color)
                .textSelection(.enabled)
        }
    }
}
