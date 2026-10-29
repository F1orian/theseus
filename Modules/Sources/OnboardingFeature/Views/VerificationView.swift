import ChatDomain
import Auth
import CoreImage.CIFilterBuiltins
import DesignSystem
import OpenWebUIKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// AUTH-03: the centred verification card (TOTP verify, authenticator enrolment, reset token,
/// recovery codes), in a "check your email" card layout.
struct VerificationView: View {
    @Bindable var model: VerificationModel
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        WelcomeScaffold(headline: headline, showsIllustration: false) {
            OnboardingCard {
                switch model.stage {
                case .verify:
                    verify
                case .enroll(let setup):
                    enroll(setup)
                case .recover:
                    recover
                case .recoveryCodes(let codes):
                    RecoveryCodesList(codes: codes)
                }
            }
            .animation(.snappy, value: model.stage)

            ErrorText(message: model.errorMessage, identifier: "verify.error")

            if case .recoveryCodes = model.stage {
                Button("I've saved them") { Task { await model.finish() } }
                    .buttonStyle(.pill)
                    .accessibilityIdentifier("verify.finish")
            } else {
                Button("Back to sign in") { model.back() }
                    .font(Typography.callout)
                    .accessibilityIdentifier("verify.back")
            }
        } footer: {
            Text(ServerDisplay.host(model.server.url, fallback: model.server.name))
        }
        .task { await model.load() }
        .onAppear { isCodeFocused = true }
    }

    private var headline: String {
        switch model.stage {
        case .verify: "Two-step verification"
        case .enroll: "Set up two-step verification"
        case .recover: "Reset two-step verification"
        case .recoveryCodes: "Save your recovery codes"
        }
    }

    // MARK: Stages

    @ViewBuilder private var verify: some View {
        CardTitle(model.usesRecoveryCode ? "Enter a recovery code" : "Enter the code from your authenticator")
        RecessedBox {
            Text(model.usesRecoveryCode ? "One of the codes you saved for" : "Open your authenticator app for")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            Text(model.email)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            codeField(placeholder: model.usesRecoveryCode ? "Recovery code" : "Code")
        }
        Button(model.usesRecoveryCode ? "Use your authenticator instead" : "Use a recovery code") {
            model.toggleRecoveryCode()
            isCodeFocused = true
        }
        .font(Typography.callout.weight(.medium))
        .accessibilityIdentifier("verify.toggleRecovery")
    }

    @ViewBuilder private func enroll(_ setup: MFASetup?) -> some View {
        CardTitle("\(ServerDisplay.name(model.server.name)) asks for an authenticator app")
        if let setup, let uri = model.provisioningURI {
            QRCodeImage(text: uri.absoluteString)
                .frame(width: 168, height: 168)
                .padding(Spacing.m)
                .background(.white, in: .rect(cornerRadius: Radius.medium))
                .accessibilityLabel("QR code for your authenticator app")
            Text("Scan the code, or add this key by hand:")
                .font(Typography.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textSecondary.color)
            ManualKey(key: setup.manualKey)
            #if os(iOS)
            Link("Open in authenticator app", destination: uri)
                .font(Typography.callout.weight(.medium))
            #endif
            RecessedBox {
                Text("Then enter the 6-digit code it shows")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                codeField(placeholder: "Code")
            }
        } else {
            ProgressView().frame(height: 120)
        }
    }

    @ViewBuilder private var recover: some View {
        CardTitle("An admin reset your authenticator")
        Text("Enter the reset token they gave you, then set up your authenticator again.")
            .font(Typography.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textSecondary.color)
        codeField(placeholder: "Reset token")
    }

    private func codeField(placeholder: String) -> some View {
        PillField {
            TextField(placeholder, text: $model.code)
                .multilineTextAlignment(.center)
                .font(model.expectsNumericCode ? Typography.code : Typography.body)
                .autocorrectionDisabled()
                #if os(iOS)
                .textContentType(model.expectsNumericCode ? .oneTimeCode : nil)
                .keyboardType(model.expectsNumericCode ? .numberPad : .asciiCapable)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isCodeFocused)
                .submitLabel(.go)
                .onSubmit { Task { await model.submit() } }
                .disabled(model.isWorking)
                .accessibilityIdentifier("verify.code")
        } accessory: {
            InlineSubmitButton(isBusy: model.isWorking, isEnabled: model.canSubmit, accessibilityLabel: "Verify") {
                Task { await model.submit() }
            }
            .accessibilityIdentifier("verify.submit")
        }
        .animation(.snappy, value: model.canSubmit)
    }
}

private struct CardTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textPrimary.color)
    }
}

/// The inset box inside the card that holds the address and the code field.
private struct RecessedBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Spacing.s) {
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
    }
}

/// The base32 secret, grouped for reading, with a copy button.
private struct ManualKey: View {
    let key: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(grouped)
                .font(Typography.code)
                .textSelection(.enabled)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityIdentifier("verify.manualKey")
            #if canImport(UIKit)
            Button {
                UIPasteboard.general.string = key
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(copied ? "Copied" : "Copy key")
            #endif
        }
    }

    private var grouped: String {
        stride(from: 0, to: key.count, by: 4).map { offset in
            let start = key.index(key.startIndex, offsetBy: offset)
            let end = key.index(start, offsetBy: 4, limitedBy: key.endIndex) ?? key.endIndex
            return String(key[start..<end])
        }
        .joined(separator: " ")
    }
}

/// Recovery codes after enrolment: shown once, copyable and shareable.
private struct RecoveryCodesList: View {
    let codes: [String]
    @State private var copied = false

    var body: some View {
        CardTitle("Keep these somewhere safe")
        Text("Each code signs you in once if you lose your authenticator. Theseus won't show them again.")
            .font(Typography.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textSecondary.color)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
            ForEach(codes, id: \.self) { code in
                Text(code)
                    .font(Typography.code)
                    .foregroundStyle(Palette.textPrimary.color)
            }
        }
        .padding(Spacing.l)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .textSelection(.enabled)
        .accessibilityIdentifier("verify.recoveryCodes")
        HStack(spacing: Spacing.xl) {
            #if canImport(UIKit)
            Button(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = codes.joined(separator: "\n")
                copied = true
            }
            #endif
            ShareLink(item: codes.joined(separator: "\n")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .font(Typography.callout.weight(.medium))
    }
}

/// A crisp QR code rendered on-device from `text` (Core Image), so no SVG decoding is needed.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit()
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
