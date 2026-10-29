import ChatDomain
import ArtCollection
import DesignSystem
import OpenWebUIKit
import SwiftUI

/// The welcome layout shared by the signed-out screens. With the illustration (server connect,
/// sign-in; brand.md §4): a full-bleed painting at the top (Cole's *View of Florence*, Heade's
/// *Point Judith* in dark appearance) fading into the background, the `stand`ing mouse on the
/// scrim's edge, a New York headline, the content (fields and pills) and a small footer. Without
/// it (verification, approval): the lockup on top and everything centred.
struct WelcomeScaffold<Content: View, Footer: View>: View {
    let headline: String
    var subtitle: String?
    var showsIllustration = true
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @Environment(\.colorScheme) private var colorScheme

    /// How far the mouse rises into the hero's scrim.
    static var mouseOverlap: CGFloat { 36 }

    var body: some View {
        GeometryReader { proxy in
            let topInset = showsIllustration ? proxy.safeAreaInsets.top : 0
            ScrollView {
                Group {
                    if showsIllustration {
                        illustrated(height: proxy.size.height, topInset: topInset)
                    } else {
                        plain
                    }
                }
                .frame(minHeight: proxy.size.height + topInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            // The painting runs up under the status bar; the scroll view's content can't reach
            // there through the safe area, so it starts at the top and the hero adds the inset.
            .ignoresSafeArea(.container, edges: showsIllustration ? .top : [])
        }
        .themedBackground()
        .mouseBackdrop()
    }

    private func illustrated(height: CGFloat, topInset: CGFloat) -> some View {
        let artwork = WelcomeArt.artwork(for: colorScheme)
        return VStack(spacing: 0) {
            // The over-art caption sits below the status bar, at the trailing corner (a cancel
            // button can sit at the leading one).
            ArtworkHero(artwork, height: topInset + min(300, max(180, height * 0.36)), showsCaption: false)
                .overlay(alignment: .topTrailing) {
                    Plaque(artwork, style: .overArt)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, Spacing.l)
                        .padding(.top, topInset + Spacing.s)
                }
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    PixelMouse(pose: .stand, scale: 3)
                        .padding(.top, -Self.mouseOverlap)
                        .padding(.bottom, Spacing.xs)
                    Text(headline)
                        .font(Typography.display)
                        .foregroundStyle(Palette.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                VStack(spacing: Spacing.m) {
                    content
                }

                footer
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var plain: some View {
        VStack(spacing: Spacing.xl) {
            BrandLockup(size: 26)
                .padding(.top, Spacing.l)

            Spacer(minLength: 0)

            VStack(spacing: Spacing.s) {
                Text(headline)
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Spacing.m) {
                content
            }

            footer
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

/// The welcome painting for an appearance (brand.md §4 slot map).
enum WelcomeArt {
    static func artwork(for colorScheme: ColorScheme) -> Artwork {
        colorScheme == .dark ? .welcomeDark : .welcome
    }
}

/// An inline error under a field.
struct ErrorText: View {
    let message: String?
    let identifier: String

    var body: some View {
        Group {
            if let message {
                Text(message)
                    .font(Typography.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.destructive.color)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(identifier)
            }
        }
        // PLAT-02: a failed sign-in step plays the error pattern.
        .hapticCue(trigger: message) { _, new in new == nil ? nil : .error }
    }
}

/// AUTH-01: "Connect to your server".
struct ServerEntryView: View {
    @Bindable var model: ServerEntryModel
    @FocusState private var isFocused: Bool

    var body: some View {
        WelcomeScaffold(
            headline: "Hello. I'm Theseus.",
            subtitle: "A home for your models, on your own Open WebUI server. Enter its address to get started."
        ) {
            PillField {
                TextField("chat.example.com", text: $model.address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .submitLabel(.continue)
                    .focused($isFocused)
                    .onSubmit { Task { await model.connect() } }
                    .disabled(model.isConnecting)
                    .accessibilityIdentifier("server.address")
            } accessory: {
                InlineSubmitButton(isBusy: model.isConnecting, isEnabled: model.canSubmit, accessibilityLabel: "Connect", isAccent: true) {
                    Task { await model.connect() }
                }
                .accessibilityIdentifier("server.continue")
            }
            .animation(.snappy, value: model.canSubmit)

            ErrorText(message: model.errorMessage, identifier: "server.error")

            if !model.accountShortcuts.isEmpty {
                OrDivider().padding(.vertical, Spacing.xs)
                ForEach(model.accountShortcuts) { account in
                    Button {
                        Task { await model.pick(account) }
                    } label: {
                        VStack(spacing: 0) {
                            Text(account.name.isEmpty ? account.email : account.name)
                            Text(ServerDisplay.host(account.server.url, fallback: account.server.name))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary.color)
                        }
                    }
                    .buttonStyle(.outlinedPill)
                    .accessibilityIdentifier("server.account.\(account.email)")
                }
            }
        } footer: {
            Text("Works with Open WebUI 0.12 or newer.")
        }
    }
}

/// The Server a sign-in screen talks to: name, host, version, and whether the link is encrypted.
struct ServerChip: View {
    let name: String
    let url: URL
    let version: String?
    let onChange: () -> Void

    private var isEncrypted: Bool { url.scheme == "https" }

    var body: some View {
        Button(action: onChange) {
            HStack(spacing: Spacing.s) {
                Image(systemName: isEncrypted ? "lock.fill" : "lock.open.trianglebadge.exclamationmark")
                    .foregroundStyle(isEncrypted ? Palette.textTertiary.color : Palette.destructive.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary.color)
                    Text(detail)
                        .font(Typography.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(isEncrypted ? Palette.textSecondary.color : Palette.destructive.color)
                }
                Spacer(minLength: Spacing.s)
                Text("Change")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.accent.color)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connect to a different server")
        .accessibilityIdentifier("signin.changeServer")
    }

    private var detail: String {
        let host = url.host(percentEncoded: false).map { host in url.port.map { "\(host):\($0)" } ?? host }
            ?? url.absoluteString
        var parts = [ServerDisplay.alias ?? (host + (url.path().count > 1 ? url.path() : ""))]
        if let version { parts.append("v\(version)") }
        if !isEncrypted { parts.append("not encrypted") }
        return parts.joined(separator: " · ")
    }
}
