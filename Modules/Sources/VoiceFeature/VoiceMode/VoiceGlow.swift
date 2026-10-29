import DesignSystem
import SwiftUI

/// The soft glow at the bottom of the Voice mode canvas: a cool moonlit slate while the user talks,
/// the chosen accent (brand.md §1, #179) while the Response is spoken, faint otherwise
/// (Visual language: Voice glow). A `MeshGradient`
/// whose inner points drift and breathe on a `TimelineView`; a turn change blends the colours
/// over `blendDuration` instead of switching. Reduce Motion holds it still (and blends faster).
struct VoiceGlow: View {
    enum Tone: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    let tone: Tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// The tone being blended away from, and when the blend started.
    @State private var previous: Tone?
    @State private var changedAt = Date.distantPast

    private var blendDuration: Double { reduceMotion ? 0.3 : 0.9 }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion && !isBlending(at: .now))) { timeline in
            let date = timeline.date
            let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
            let blend = blendFraction(at: date)
            let palette = Palette3.mix(previous.map(Self.palette) ?? Self.palette(tone), Self.palette(tone), blend)
            let breath = reduceMotion ? 0.5 : (sin(time * 1.6) + 1) / 2
            let strength = mix(previous.map(intensity) ?? intensity(tone), intensity(tone), blend) * (0.88 + 0.12 * breath)
            MeshGradient(
                width: 3,
                height: 3,
                points: points(time: time),
                colors: colors(palette, strength: strength),
                smoothsColors: true
            )
        }
        .onChange(of: tone) { old, _ in
            previous = old
            changedAt = .now
        }
        .accessibilityHidden(true)
    }

    // MARK: Geometry

    /// The middle row and the bottom centre drift slowly, so the glow seems to breathe and move.
    private func points(time: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(sin(time * speed + phase) * amount)
        }
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5 + wave(0.5, 0, 0.08)], [0.5 + wave(0.35, 2.1, 0.12), 0.55 + wave(0.6, 1, 0.08)], [1, 0.45 + wave(0.45, 4.2, 0.08)],
            [0, 1], [0.5 + wave(0.3, 3.3, 0.15), 1], [1, 1],
        ]
    }

    /// Transparent at the top, a hint in the middle, full at the bottom edge.
    private func colors(_ palette: Palette3, strength: Double) -> [Color] {
        let top = 0.0, middle = 0.38 * strength, bottom = strength
        return [
            palette.a.color(top), palette.b.color(top), palette.c.color(top),
            palette.a.color(middle), palette.b.color(middle * 1.2), palette.c.color(middle),
            palette.a.color(bottom), palette.b.color(bottom), palette.c.color(bottom),
        ]
    }

    // MARK: Tone

    private func isBlending(at date: Date) -> Bool {
        date.timeIntervalSince(changedAt) < blendDuration
    }

    private func blendFraction(at date: Date) -> Double {
        guard previous != nil else { return 1 }
        let linear = min(max(date.timeIntervalSince(changedAt) / blendDuration, 0), 1)
        return linear * linear * (3 - 2 * linear)  // smoothstep
    }

    private func intensity(_ tone: Tone) -> Double {
        let base: Double = switch tone {
        case .idle: 0.22
        case .thinking: 0.34
        case .listening: 0.6
        case .speaking: 0.72
        }
        return colorScheme == .dark ? base * 0.8 : base
    }

    private static func palette(_ tone: Tone) -> Palette3 {
        switch tone {
        case .speaking:
            // The chosen accent (#179; Verdigris by default): its light and dark values and the
            // tone between. Reading `Palette.accent` here observes the choice, so the glow follows it.
            let accent = DesignSystem.Palette.accent
            let light = RGB(accent.light), dark = RGB(accent.dark)
            return Palette3(a: light, b: dark, c: RGB.mix(light, dark, 0.4))
        case .listening, .idle:
            // Moonlit slate, after the Nocturne neutrals: cool, but not a second accent hue.
            return Palette3(a: RGB(0.50, 0.60, 0.70), b: RGB(0.68, 0.76, 0.84), c: RGB(0.56, 0.66, 0.76))
        case .thinking:
            return Palette3(a: RGB(0.66, 0.68, 0.72), b: RGB(0.76, 0.77, 0.80), c: RGB(0.70, 0.72, 0.76))
        }
    }
}

private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

private struct RGB {
    let r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }
    init(_ value: RGBA) { self.init(value.red, value.green, value.blue) }

    func color(_ opacity: Double) -> Color { Color(red: r, green: g, blue: b, opacity: min(max(opacity, 0), 1)) }

    static func mix(_ x: RGB, _ y: RGB, _ t: Double) -> RGB {
        RGB(VoiceFeature.mix(x.r, y.r, t), VoiceFeature.mix(x.g, y.g, t), VoiceFeature.mix(x.b, y.b, t))
    }
}

private struct Palette3 {
    let a, b, c: RGB

    static func mix(_ x: Palette3, _ y: Palette3, _ t: Double) -> Palette3 {
        Palette3(a: .mix(x.a, y.a, t), b: .mix(x.b, y.b, t), c: .mix(x.c, y.c, t))
    }
}

#Preview("Voice glow") {
    @Previewable @State var tone = VoiceGlow.Tone.listening
    ZStack(alignment: .bottom) {
        Color(white: 0.98).ignoresSafeArea()
        VoiceGlow(tone: tone).frame(height: 360)
        Button("Next tone") {
            tone = switch tone {
            case .idle: .listening
            case .listening: .thinking
            case .thinking: .speaking
            case .speaking: .idle
            }
        }
        .padding(.bottom, 80)
    }
}
