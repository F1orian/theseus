import ComposerFeature
import DesignSystem
public import SwiftUI

/// The recording bar that replaces the composer's text field and buttons during Dictation
/// (VOICE-01): the live transcript in italics, then cancel (X), the dotted waveform and the
/// blue confirm check.
public struct DictationBar: View {
    let model: DictationModel

    public init(model: DictationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            transcript
            HStack(spacing: Spacing.xs) {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textPrimary.color)
                        .frame(width: 36, height: 36)
                        .background(Palette.recessedSurface.color, in: .circle)
                        .minimumHitTarget()  // PLAT-06
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("dictation.cancel")

                LevelWaveform(levels: model.levels, isActive: model.phase == .recording)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                Button {
                    Task { await model.confirm() }
                } label: {
                    Group {
                        if model.phase == .finishing || model.phase == .starting {
                            ProgressView().tint(Palette.onAccent.color)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundStyle(Palette.onAccent.color)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent.color, in: .circle)
                    .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .recording)
                .accessibilityLabel("Done dictating")
                .accessibilityIdentifier("dictation.confirm")
            }
        }
        .hapticFeedback(.start, trigger: model.phase == .recording)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation.bar")
    }

    @ViewBuilder
    private var transcript: some View {
        let text = model.transcript
        Group {
            if text.isEmpty {
                Text(model.phase == .starting ? "Starting…" : model.showsLiveTranscript ? "Listening…" : "Recording…")
                    .foregroundStyle(Palette.textTertiary.color)
            } else {
                Text(text)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .font(Typography.body.italic())
        .lineLimit(4)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
        .motionSafeAnimation(Motion.live, value: text)
        .accessibilityIdentifier("dictation.transcript")
    }
}

/// A row of bars that follow the microphone level; silence draws dots (VOICE-01, VOICE-04).
///
/// The levels arrive about 16 times a second, oldest first. Between two updates the bars glide
/// one slot to the left on a `TimelineView`, so the waveform scrolls continuously instead of
/// stepping (ADR 0130). Reduce Motion keeps the steps.
struct LevelWaveform: View {
    let levels: [Float]
    var isActive: Bool = true
    var color: Color = Palette.textPrimary.color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastUpdate = Date.distantPast

    /// About how often a new level arrives (DictationModel keeps ~16 a second).
    private static let interval: Double = 0.06

    var body: some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { timeline in
            let progress = reduceMotion || !isActive
                ? 1
                : min(max(timeline.date.timeIntervalSince(lastUpdate) / Self.interval, 0), 1)
            Canvas { context, size in
                guard !levels.isEmpty else { return }
                let step = size.width / CGFloat(levels.count)
                let barWidth = max(2, min(3, step * 0.45))
                // The newest bar slides in from the right edge as `progress` runs to 1.
                let shift = step * CGFloat(1 - progress)
                for (index, level) in levels.enumerated() {
                    let height = max(barWidth, CGFloat(isActive ? level : 0) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * step + (step - barWidth) / 2 + shift,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    guard rect.minX < size.width else { continue }
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(level > 0.05 ? 1 : 0.55)))
                }
            }
        }
        .onChange(of: levels) { lastUpdate = .now }
    }
}
