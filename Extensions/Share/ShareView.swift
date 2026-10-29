import DesignSystem
import Persistence
import SwiftUI
import UIKit

/// "Share to Theseus" (PLAT-04): what's being shared, an optional message, and the Account the new
/// Chat starts in. The round X cancels; the round arrow starts the Chat in Theseus.
struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    content
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background.color)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { model.cancel() }
                        .accessibilityIdentifier("share.cancel")
                }
                if model.phase != .saved, model.phase != .needsPro {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start chat", systemImage: "arrow.up") {
                            Task { await model.send() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent.color)
                        .disabled(!model.canSend)
                        .accessibilityIdentifier("share.send")
                    }
                }
            }
        }
        .tint(Palette.textPrimary.color)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .signedOut:
            Notice(symbol: "person.crop.circle.badge.questionmark", title: "Sign in to Theseus first",
                   message: "Open Theseus and sign in to your Server, then share again.")
        case .needsPro:
            Notice(symbol: "seal", title: "Sharing is part of Theseus Pro",
                   message: "Pro starts chats from the Share sheet, widgets, Siri and Shortcuts. Pay once: no subscription, no ads, no tracking.")
            Button("Open Theseus") { Task { await model.openPaywall() } }
                .buttonStyle(.primary)
                .accessibilityIdentifier("share.unlock")
        case .unsupported:
            Notice(symbol: "questionmark.square.dashed", title: "Nothing to share",
                   message: "Theseus can take text, links, photos and files.")
        case .tooLarge:
            Notice(symbol: "externaldrive.badge.exclamationmark", title: "That's too much at once",
                   message: "Share fewer or smaller files.")
        case .failed(let message):
            Notice(symbol: "exclamationmark.triangle", title: "Couldn't share", message: message)
        case .saved:
            Notice(symbol: "tray.and.arrow.down", title: "Waiting in Theseus",
                   message: "Open Theseus to continue: a new chat with what you shared is ready.")
            Button("Done") { model.finish() }
                .buttonStyle(.primary)
                .accessibilityIdentifier("share.done")
        case .ready:
            TextField("Add a message (optional)", text: $model.note, axis: .vertical)
                .font(Typography.body)
                .lineLimit(1...6)
                .focused($noteFocused)
                .padding(Spacing.m)
                .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
                .accessibilityIdentifier("share.note")
            ForEach(model.contents) { item in
                SharedItemRow(content: item)
            }
            if let snapshot = model.snapshot {
                Text("Starts a new chat as \(snapshot.accountName) on \(snapshot.displayServerHost).")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("share.account")
            }
        }
    }
}

private struct SharedItemRow: View {
    let content: SharedContent

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            leading
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(3)
                if let detail {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        if case .image(let data, _, _) = content.kind, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: Radius.small))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 44, height: 44)
                .background(Palette.surface.color, in: .rect(cornerRadius: Radius.small))
        }
    }

    private var symbol: String {
        switch content.kind {
        case .text: "text.quote"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    private var title: String {
        switch content.kind {
        case .text(let text): text
        case .url(let url): url.host() ?? url.absoluteString
        case .image(_, let filename, _), .file(_, let filename, _): filename
        }
    }

    private var detail: String? {
        switch content.kind {
        case .text: nil
        case .url(let url): url.absoluteString
        case .image(let data, _, _), .file(let data, _, _):
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
    }
}

private struct Notice: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 48, height: 48)
                .background(Palette.recessedSurface.color, in: .circle)
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.notice")
    }
}

#Preview("Ready") {
    let model = ShareModel(
        snapshot: SharedSnapshot(accountID: "a", accountName: "Ada", serverHost: "chat.example.com", actions: .init(), recentChats: []),
        inbox: nil
    )
    model.show([
        SharedContent(kind: .url(URL(string: "https://www.swift.org/blog/") ?? URL(fileURLWithPath: "/"))),
        SharedContent(kind: .text("Swift 6.4 brings faster builds and better diagnostics.")),
        SharedContent(kind: .file(Data(count: 182_000), filename: "Release notes.pdf", contentType: "application/pdf")),
    ])
    return ShareView(model: model)
}

#Preview("Signed out") {
    let model = ShareModel(snapshot: nil, inbox: nil)
    Task { await model.load([]) }
    return ShareView(model: model)
}
