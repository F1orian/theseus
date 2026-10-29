import DesignSystem
public import Entitlements
public import SwiftUI

/// Settings › App Icon (BRAND-02): every shipped icon in a grid, grouped as in `icons.json`
/// (Paintings, Cheese, Rooms and ledges, Pixel). The current icon is ringed and ticked; tapping
/// another asks iOS to switch, and iOS confirms with its own alert.
public struct AppIconPickerView: View {
    let model: AppIconPickerModel
    /// ADR 0173: the alternates are Pro; the Renoir stays free. `nil` doesn't gate.
    let pro: ProStore?
    @State private var paywall: PaywallRequest?

    public init(model: AppIconPickerModel, pro: ProStore? = nil) {
        self.model = model
        self.pro = pro
    }

    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 64

    public var body: some View {
        List {
            ForEach(model.sections, id: \.group) { section in
                Section {
                    LazyVGrid(columns: columns, alignment: .center, spacing: Spacing.l) {
                        ForEach(section.icons) { icon in
                            AppIconCell(
                                icon: icon,
                                model: model,
                                thumbnailSize: thumbnailSize,
                                isLocked: isLocked(icon)
                            ) {
                                paywall = PaywallRequest(.appIcons)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.s)
                    .settingsRowBackground()
                } header: {
                    Text(section.group.title)
                        .accessibilityIdentifier("appIcon.section.\(section.group.rawValue)")
                }
            }
            Section {
                CurrentIconPlaque(icon: model.current)
                    .settingsRowBackground()
            } header: {
                Text("Current icon")
            } footer: {
                Text(ui: "The paintings are public domain or CC0. The mouse is Theseus, the app's own pixel art.")
            }
        }
        .settingsList()
        .navigationTitle("App icon")
        .settingsInlineTitle()
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                AppIconErrorToast(message: message) { model.dismissError() }
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.xs)
                    .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .motionSafeAnimation(.spring(duration: 0.35, bounce: 0.18), value: model.errorMessage)
        .hapticFeedback(.selection, trigger: model.current.name)
        .onAppear { model.refresh() }
        .paywall($paywall)
        .accessibilityIdentifier("appIcon.page")
    }

    private func isLocked(_ icon: AppIconOption) -> Bool {
        guard let pro, !pro.isPro else { return false }
        return icon.alternateIconName != nil && !model.isCurrent(icon)
    }

    /// As many columns as fit; fewer as Dynamic Type grows the thumbnails.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: max(thumbnailSize + Spacing.xl, 92)), spacing: Spacing.s, alignment: .top)]
    }
}

/// One icon: the thumbnail in the iOS icon shape, its title and a short credit line.
private struct AppIconCell: View {
    let icon: AppIconOption
    let model: AppIconPickerModel
    let thumbnailSize: CGFloat
    var isLocked = false
    var unlock: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isCurrent = model.isCurrent(icon)
        // At the accessibility sizes the grid drops to fewer columns and text wraps freely.
        let lines: Int? = dynamicTypeSize.isAccessibilitySize ? nil : 2
        let isPending = model.pendingIcon == icon
        Button {
            if isLocked {
                unlock()
            } else {
                Task { await model.select(icon) }
            }
        } label: {
            VStack(spacing: Spacing.xs) {
                AppIconThumbnail(icon: icon, size: thumbnailSize, isCurrent: isCurrent, isPending: isPending)
                    .padding(.bottom, Spacing.xxs)
                Text(ui: icon.title)
                    .font(.footnote.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent.color : Palette.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(lines)
                if let line = icon.shortCredit {
                    // A small museum plaque (brand §2: Departure Mono, ≤ 13 pt).
                    Text(ui: line)
                        .plaqueStyle()
                        .multilineTextAlignment(.center)
                        .lineLimit(lines.map { $0 + 1 })
                }
                if isLocked { ProBadge() }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.pendingIcon != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.accessibilityLabel(isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isCurrent ? "" : isLocked ? "Part of Theseus Pro." : "Sets the home screen icon.")
        .accessibilityIdentifier("appIcon.\(icon.name)")
    }
}

/// The flat render in the rounded-square icon shape, ringed in the accent and ticked when current.
private struct AppIconThumbnail: View {
    let icon: AppIconOption
    let size: CGFloat
    let isCurrent: Bool
    let isPending: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        icon.thumbnail
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.separator.color, lineWidth: 0.5) }
            .overlay {
                if isPending {
                    ProgressView()
                        .frame(width: size, height: size)
                        .background(.ultraThinMaterial, in: shape)
                }
            }
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.2237 + 3, style: .continuous)
                    .strokeBorder(isCurrent ? Palette.accent.color : .clear, lineWidth: 2.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: max(18, size * 0.3), weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Palette.onAccent.color, Palette.accent.color)
                        .background(Palette.surface.color, in: .circle)
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The current icon's full plaque: the work, artist, date, museum and licence.
private struct CurrentIconPlaque: View {
    let icon: AppIconOption

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(ui: icon.title)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
            Text(ui: icon.credit.isEmpty ? "Original pixel art" : icon.credit)
                .plaqueStyle(12, relativeTo: .caption, color: Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appIcon.current")
    }
}

/// A top toast for a failed switch: icon, text and an X (MSG-02's look).
private struct AppIconErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(Palette.destructive.color)
                .accessibilityHidden(true)
            Text(ui: message)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(3)
            Spacer(minLength: Spacing.s)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appIcon.toast")
    }
}

/// The Settings row's trailing preview of the current icon.
struct AppIconRowLabel: View {
    let current: AppIconOption
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 28

    var body: some View {
        HStack {
            SettingsRowLabel(title: "App icon", systemImage: "app.badge")
            Spacer(minLength: Spacing.s)
            Text(ui: current.title)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .lineLimit(1)
            current.thumbnail
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.2237, style: .continuous))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("App icon, \(current.title)")
    }
}

extension AppIconOption.Group {
    var title: String { rawValue }
}

extension AppIconOption {
    /// The work and its date from the credit ("Fruits of the Midi · 1881"); nil for pixel art.
    var shortCredit: String? {
        let parts = credit.components(separatedBy: " · ")
        guard let work = parts.first, !work.isEmpty else { return nil }
        if parts.count > 2 { return "\(work) · \(parts[2])" }
        return work
    }

    /// "Renoir, Fruits of the Midi, current icon".
    func accessibilityLabel(isCurrent: Bool) -> String {
        var parts = [title]
        if let work = credit.components(separatedBy: " · ").first, !work.isEmpty { parts.append(work) }
        if isCurrent { parts.append("current icon") }
        return parts.joined(separator: ", ")
    }
}

#Preview("App icon") {
    NavigationStack {
        AppIconPickerView(model: AppIconPickerModel(switcher: FakeAppIconSwitcher()))
    }
}

#Preview("App icon · Monet, dark") {
    NavigationStack {
        AppIconPickerView(model: AppIconPickerModel(switcher: FakeAppIconSwitcher(alternateIconName: "AppIcon-Monet")))
    }
    .preferredColorScheme(.dark)
}

#Preview("App icon · accessibility size") {
    NavigationStack {
        AppIconPickerView(model: AppIconPickerModel(switcher: FakeAppIconSwitcher(alternateIconName: "AppIcon-PixelMousehole")))
    }
    .dynamicTypeSize(.accessibility3)
}

#Preview("App icon · error") {
    let switcher = FakeAppIconSwitcher()
    switcher.nextError = CocoaError(.featureUnsupported)
    let model = AppIconPickerModel(switcher: switcher)
    return NavigationStack { AppIconPickerView(model: model) }
        .task { await model.select(AppIconCatalog.all[1]) }
}
