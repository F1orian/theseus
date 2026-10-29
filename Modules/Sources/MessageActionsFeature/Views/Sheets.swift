import ChatDomain
import DesignSystem
import OpenWebUIKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The sheet header of the Visual language: a round X on the left, the title, and a round check
/// on the right that turns filled when there's something to confirm.
struct SheetHeader: View {
    let title: String
    var confirmLabel = "Done"
    var canConfirm = false
    var isWorking = false
    let close: () -> Void
    var confirm: (() -> Void)?

    var body: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("sheet.close")
            Spacer()
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let confirm {
                Button(action: confirm) {
                    Group {
                        if isWorking {
                            ProgressView().tint(Palette.background.color)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(canConfirm ? Palette.background.color : Palette.textTertiary.color)
                    .frame(width: 44, height: 44)
                    .background(canConfirm ? Palette.textPrimary.color : Palette.recessedSurface.color, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm || isWorking)
                .accessibilityLabel(confirmLabel)
                .accessibilityIdentifier("sheet.confirm")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.l)
    }
}

/// A multi-line text box with a placeholder, in the rounded field style.
struct TextBox: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 140
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textTertiary.color)
                        .padding(.horizontal, Spacing.m + 5)
                        .padding(.vertical, Spacing.s + 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
            .onAppear { focused = true }
    }
}

/// "Feedback" after a thumb (MSG-06): an optional comment, then submit. The chosen thumb fills
/// once the Server has stored it. A thumbs-down can also report the Response as harmful or
/// offensive to the Server's admins (App Review 1.2, ADR 0172).
struct FeedbackSheet: View {
    let draft: MessageActions.FeedbackDraft
    let actions: MessageActions
    @State private var comment: String
    @State private var isReport: Bool
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    init(draft: MessageActions.FeedbackDraft, actions: MessageActions) {
        self.draft = draft
        self.actions = actions
        _comment = State(initialValue: draft.comment)
        _isReport = State(initialValue: draft.isReport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(title: draft.isReport ? "Report response" : "Feedback", confirmLabel: isReport ? "Report" : "Submit", canConfirm: true, isWorking: isSending, close: { dismiss() }) {
                Task {
                    isSending = true
                    let sent = await actions.submit(draft, comment: comment, isReport: isReport)
                    isSending = false
                    if sent { dismiss() }
                }
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                TextBox(text: $comment, placeholder: placeholder)
                    .accessibilityIdentifier("feedback.comment")
                if draft.rating == .bad {
                    Toggle(isOn: $isReport) {
                        Label("Report as harmful or offensive", systemImage: "flag")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary.color)
                    }
                    .tint(Palette.accent.color)
                    .padding(.horizontal, Spacing.l)
                    .accessibilityIdentifier("feedback.report")
                }
                Text(note)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(.horizontal, Spacing.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.l)
            Spacer(minLength: 0)
        }
        .themedBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedback.sheet")
    }

    private var placeholder: String {
        switch draft.rating {
        case .good: "What made this response helpful?"
        case .bad: "What was wrong with this response?"
        }
    }

    private var note: String {
        let host = actions.client.server.host() ?? "this Server"
        if isReport {
            return "Your report, comment and a copy of this chat go to the admins of \(host), who run its models "
                + "and decide what they may answer."
        }
        return "Your rating, comment and a copy of this chat are saved on \(host), where its admins can review them."
    }
}

/// Editing a sent user Message (MSG-05): sending creates a new Branch next to the original.
struct EditMessageSheet: View {
    let draft: MessageActions.EditDraft
    let actions: MessageActions
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(draft: MessageActions.EditDraft, actions: MessageActions) {
        self.draft = draft
        self.actions = actions
        _text = State(initialValue: draft.text)
    }

    private var canSend: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(title: "Edit message", confirmLabel: "Send", canConfirm: canSend, close: { dismiss() }) {
                let edited = text
                dismiss()
                Task { await actions.send(draft, text: edited) }
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                TextBox(text: $text, placeholder: "Message", minHeight: 160)
                    .accessibilityIdentifier("edit.text")
                Text("Sending starts a new branch from here. The original stays one branch back (‹ ›).")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(.horizontal, Spacing.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.l)
            Spacer(minLength: 0)
        }
        .themedBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edit.sheet")
    }
}

/// "Share" (MSG-08): the Chat title, who has access, and Share link (enabled once the link is
/// open), which re-snapshots the Chat and opens the system share sheet.
struct ShareChatSheet: View {
    let sharing: ChatLinkSharing
    @State private var sharedLink: SharedLink?
    @Environment(\.dismiss) private var dismiss
    /// #149: icons scale with the text and keep their gap to the labels.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    struct SharedLink: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(title: "Share", close: { dismiss() })
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(Palette.textSecondary.color)
                    Text(sharing.title.isEmpty ? "Untitled chat" : sharing.title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(Spacing.l)
                .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large))

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Who has access")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .padding(.horizontal, Spacing.l)
                    switch sharing.state {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 112)
                    case .failed(let message):
                        VStack(spacing: Spacing.s) {
                            Text(message)
                                .font(Typography.callout)
                                .foregroundStyle(Palette.textSecondary.color)
                            Button("Try again") { Task { await sharing.load() } }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112)
                    case .ready:
                        accessOptions
                    }
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(sharing.errorMessage == nil ? Palette.textSecondary.color : Palette.destructive.color)
                        .padding(.horizontal, Spacing.l)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("share.caption")
                }

                Button {
                    Task {
                        if let url = await sharing.freshLink() { sharedLink = SharedLink(url: url) }
                    }
                } label: {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .font(Typography.headline)
                        .foregroundStyle(Palette.background.color)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            canShare ? Palette.textPrimary.color : Palette.textTertiary.color,
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canShare)
                .accessibilityIdentifier("share.link")
            }
            .padding(.horizontal, Spacing.l)
            Spacer(minLength: 0)
        }
        .themedBackground()
        .task { await sharing.load() }
        .sheet(item: $sharedLink) { link in
            ActivitySheet(url: link.url)
                .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.sheet")
    }

    private var canShare: Bool {
        sharing.state == .ready && sharing.access == .anyoneWithLink && !sharing.isWorking
    }

    private var caption: String {
        if let error = sharing.errorMessage { return error }
        switch sharing.access {
        case .onlyYou:
            return "Only you can see this chat."
        case .anyoneWithLink:
            let host = sharing.serverHost
            return "Anyone signed in to \(host) can open the link. It shows the chat as it is when you share it."
        }
    }

    private var accessOptions: some View {
        VStack(spacing: 0) {
            option(.onlyYou, title: "Only you have access", symbol: "lock", id: "share.onlyYou")
            Divider().padding(.leading, 52)
            option(.anyoneWithLink, title: "Anyone with the link", symbol: "globe", id: "share.anyone")
        }
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large))
        .disabled(sharing.isWorking)
    }

    private func option(_ access: ChatLinkSharing.Access, title: String, symbol: String, id: String) -> some View {
        Button {
            Task { await sharing.setAccess(access) }
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .frame(minWidth: iconWidth)
                    .foregroundStyle(Palette.textSecondary.color)
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Spacer(minLength: 0)
                if sharing.access == access {
                    if sharing.isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent.color)
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sharing.access == access ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

extension ChatLinkSharing {
    var serverHost: String { ServerDisplay.host(serverURL, fallback: "this Server") }
}

/// The system share sheet for a URL.
struct ActivitySheet: View {
    let url: URL

    var body: some View {
        #if canImport(UIKit)
        ActivityView(items: [url]).ignoresSafeArea()
        #else
        ShareLink(item: url)
        #endif
    }
}

#if canImport(UIKit)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
