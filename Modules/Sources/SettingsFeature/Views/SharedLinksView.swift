import ChatDomain
import DesignSystem
import OpenWebUIKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Settings > Shared links (SET-08): shared Chats grouped by date ("Shared 2 hours ago").
struct SharedLinksView: View {
    @State private var model: SharedLinksModel
    @State private var isConfirmingDeleteAll = false

    init(model: SharedLinksModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                SettingsEmptyState(title: "Couldn't load your links", message: message, pose: .peek)
                    .frame(maxHeight: .infinity)
            case .loaded where model.links.isEmpty:
                SettingsEmptyState(
                    title: "No shared links",
                    message: "Chats you share with a link appear here."
                )
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("sharedLinks.empty")
            case .loaded:
                list
            }
        }
        .themedBackground()
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                SettingsErrorBanner(message: message) { model.dismissError() }
            }
        }
        .navigationTitle("Shared links")
        .settingsInlineTitle()
        .toolbar {
            if !model.links.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Delete all links", systemImage: "trash", role: .destructive) {
                            isConfirmingDeleteAll = true
                        }
                        .accessibilityIdentifier("sharedLinks.deleteAll")
                    }
                    .tint(Palette.textPrimary.color)
                    .accessibilityIdentifier("sharedLinks.menu")
                }
            }
        }
        .confirmationDialog(
            "Delete all shared links?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all links", role: .destructive) {
                Task { await model.deleteAll() }
            }
        } message: {
            Text("People with these links won't be able to open them anymore. Your chats stay.")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("settings.sharedLinks")
    }

    private var list: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.links) { link in
                        NavigationLink(value: SettingsPage.sharedChat(link)) {
                            SharedLinkRow(link: link)
                        }
                        .settingsRowBackground()
                        .accessibilityIdentifier("sharedLinks.row.\(link.chatID)")
                        .contextMenu { linkActions(link) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(link) }
                            }
                        }
                        .onAppear {
                            if link == model.links.last { Task { await model.loadMore() } }
                        }
                    }
                }
            }
        }
        .settingsList()
    }

    @ViewBuilder
    private func linkActions(_ link: SharedChatLink) -> some View {
        ShareLink(item: model.url(for: link)) {
            Label("Share link", systemImage: "square.and.arrow.up")
        }
        Button("Copy link", systemImage: "doc.on.doc") {
            copyToPasteboard(model.url(for: link).absoluteString)
        }
        Button("Delete link", systemImage: "trash", role: .destructive) {
            Task { await model.delete(link) }
        }
    }
}

private struct SharedLinkRow: View {
    let link: SharedChatLink

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(link.title.isEmpty ? "Untitled chat" : link.title)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(2)
            Text("Shared \(link.updatedAt.formatted(.relative(presentation: .named)))")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// The read-only snapshot behind a Shared link, with a "shared by" line and a caveat banner.
struct SharedChatView: View {
    let link: SharedChatLink
    let model: SharedLinksModel
    @State private var snapshot: SharedChatSnapshot?
    @State private var failure: String?
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                Text("This snapshot may not show attachments or other data that shaped the responses.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
                    .accessibilityIdentifier("sharedChat.caveat")
                if let snapshot {
                    ForEach(snapshot.messages) { message in
                        SnapshotMessage(message: message)
                    }
                } else if let failure {
                    SettingsEmptyState(title: "Couldn't open this link", message: failure, pose: .peek)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.l)
        }
        .themedBackground()
        .navigationTitle("Shared chat")
        .settingsInlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    ShareLink(item: model.url(for: link)) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    Button("Copy link", systemImage: "doc.on.doc") {
                        copyToPasteboard(model.url(for: link).absoluteString)
                    }
                    Button("Delete link", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .accessibilityIdentifier("sharedChat.delete")
                }
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("sharedChat.menu")
            }
        }
        .confirmationDialog("Delete this link?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete link", role: .destructive) {
                Task {
                    if await model.delete(link) { dismiss() }
                }
            }
        } message: {
            Text("People with the link won't be able to open it anymore. The chat stays.")
        }
        .task {
            do {
                snapshot = try await model.snapshot(for: link)
            } catch {
                failure = (error as? OpenWebUIError)?.message ?? "Something went wrong."
            }
        }
        .accessibilityIdentifier("settings.sharedChat")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(snapshot?.title ?? link.title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
            Text(sharedLine)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
        }
    }

    private var sharedLine: String {
        let when = link.updatedAt.formatted(.relative(presentation: .named))
        if let name = snapshot?.sharedByName, !name.isEmpty {
            return "Shared by \(name) \(when)"
        }
        return "Shared \(when)"
    }
}

/// One Message of a snapshot: user Messages in a right-aligned bubble, Responses as full-width serif text.
private struct SnapshotMessage: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            Text(message.content)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, Spacing.xxxl)
        case .assistant, .system:
            Text(rendered)
                .font(.system(.body, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(Palette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// Inline Markdown (bold, italics, links, code); block structure keeps its line breaks.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.content, options: options)) ?? AttributedString(message.content)
    }
}

func copyToPasteboard(_ string: String) {
    #if os(iOS)
    UIPasteboard.general.string = string
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
}
