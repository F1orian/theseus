import ChatDomain
import ArtCollection
import DesignSystem
public import SwiftUI

/// AUTH-02: sign in to one Server. Shows only the methods the Server offers: single sign-on pills,
/// the email (or LDAP) form with an inline arrow, or a plain "Continue" for Servers without auth.
struct SignInView: View {
    @Bindable var model: SignInModel
    @FocusState private var focusedField: Field?

    // Every field is bound: an unbound field lets a stale focus value pull the cursor back on re-render.
    private enum Field { case identifier, password }

    var body: some View {
        WelcomeScaffold(headline: headline) {
            ServerChip(name: ServerDisplay.name(model.server.name), url: model.server.url, version: model.serverVersion) {
                model.changeServer()
            }
            .padding(.bottom, Spacing.s)

            if let notice = model.notice {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("signin.notice")
            }

            methods
                .disabled(model.isSigningIn)

            ErrorText(message: model.errorMessage, identifier: "signin.error")
        } footer: {
            Text("Your chats stay on \(ServerDisplay.host(model.server.url, fallback: model.server.name)). Theseus has no servers of its own.")
        }
        .animation(.snappy, value: model.showsPasswordField)
        .animation(.snappy, value: model.mode)
        .task { await model.loadConfigIfNeeded() }
        #if os(iOS)
        .sheet(item: $model.webSignIn) { webSignIn in
            WebSignInSheet(model: webSignIn)
        }
        #endif
        .onAppear { focusedField = model.showsPasswordField ? .password : nil }
    }

    @ViewBuilder private var methods: some View {
        let methods = model.methods
        if !methods.requiresAuth {
            Button {
                Task { await model.continueWithoutAccount() }
            } label: {
                if model.isSigningIn { ProgressView().tint(Palette.onAccent.color) } else { Text("Continue") }
            }
            .buttonStyle(.accentPill)
            .accessibilityIdentifier("signin.continue")
        } else if methods.isFirstRun {
            // Theseus never creates Accounts (ADR 0170), including the first admin.
            Text("This server has no accounts yet. Finish setting it up in a browser, then sign in here.")
                .font(Typography.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary.color)
                .accessibilityIdentifier("signin.firstRun")
        } else if !methods.hasAnyMethod {
            Text("This server doesn't offer a way to sign in that Theseus supports. Ask its admin to enable the sign-in form.")
                .font(Typography.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary.color)
                .accessibilityIdentifier("signin.noMethods")
        } else {
            if !methods.ssoProviders.isEmpty || methods.trustedHeader {
                ForEach(methods.ssoProviders) { provider in
                    Button {
                        model.startSSO(provider)
                    } label: {
                        Label("Continue with \(provider.name)", systemImage: "person.badge.key.fill")
                    }
                    .buttonStyle(.pill)
                    .accessibilityIdentifier("signin.sso.\(provider.id)")
                }
                if methods.trustedHeader {
                    Button {
                        model.startWebPageSignIn()
                    } label: {
                        Label("Continue with \(ServerDisplay.name(model.server.name))", systemImage: "globe")
                    }
                    .buttonStyle(.pill)
                    .accessibilityIdentifier("signin.webPage")
                }
                if model.showsCredentialForm {
                    OrDivider().padding(.vertical, Spacing.xs)
                }
            }
            if model.showsCredentialForm {
                credentialForm
            }
        }
    }

    private var headline: String { "Find your way in" }

    @ViewBuilder private var credentialForm: some View {
        PillField {
            TextField(model.mode == .ldap ? "Username" : "Email", text: $model.email)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(model.mode == .ldap ? .default : .emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(model.showsPasswordField ? .next : .continue)
                .focused($focusedField, equals: .identifier)
                .onSubmit(submitIdentifier)
                .accessibilityIdentifier("signin.email")
        } accessory: {
            if !model.showsPasswordField {
                InlineSubmitButton(isBusy: false, isEnabled: model.canSubmitIdentifier, isAccent: true, action: submitIdentifier)
                    .accessibilityIdentifier("signin.next")
            }
        }
        .animation(.snappy, value: model.canSubmitIdentifier)

        if model.showsPasswordField {
            PillField {
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await model.signIn() } }
                    .accessibilityIdentifier("signin.password")
            } accessory: {
                InlineSubmitButton(
                    isBusy: model.isSigningIn,
                    isEnabled: model.canSubmit,
                    accessibilityLabel: "Sign in",
                    isAccent: true
                ) {
                    Task { await model.signIn() }
                }
                .accessibilityIdentifier("signin.submit")
            }
            .animation(.snappy, value: model.canSubmit)
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
        }

        if model.methods.ldap, model.methods.password {
            Button(model.mode == .ldap ? "Sign in with email instead" : "Sign in with LDAP instead") {
                model.setMode(model.mode == .ldap ? .email : .ldap)
                focusedField = .identifier
            }
            .font(Typography.callout)
            .accessibilityIdentifier("signin.toggleLDAP")
        }
    }

    private func submitIdentifier() {
        model.submitIdentifier()
        if model.showsPasswordField { focusedField = .password }
    }
}

/// OR between single sign-on pills and the credential form.
struct OrDivider: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            Rectangle().fill(Palette.separator.color).frame(height: 1)
            Text("or")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary.color)
            Rectangle().fill(Palette.separator.color).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// The launch splash: the Theseus lockup, centred, while the app restores the last Account.
public struct BrandSplashView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        BrandLockup(size: 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .mouseBackdrop()
            .accessibilityIdentifier("splash")
            // The welcome painting decodes while the app restores the last Account, so the
            // server-connect screen opens with it in place.
            .task { await Artwork.preload([WelcomeArt.artwork(for: colorScheme)], maxPixelSize: 1600) }
    }
}
