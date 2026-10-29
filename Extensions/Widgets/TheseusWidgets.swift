import AppIntents
import AppIntentsFeature
import DesignSystem
import Persistence
import SwiftUI
import WidgetKit

/// The home-screen widget (PLAT-01): a wide "Chat" pill over round Camera and Mic buttons that
/// open a new Chat, the camera or Dictation; the medium size adds Voice mode and the active
/// Account's recent Chats. Reads the `SharedSnapshot` the app keeps current (ADR 0100), so
/// Incognito chats and other Accounts never show.
@main
struct TheseusWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickChatWidget()
        NewChatAccessoryWidget()
    }
}

/// Registers the App Intents the widget's buttons run (they open the app).
struct TheseusWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [AppIntentsFeaturePackage.self]
    }
}

// MARK: Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// `nil` when signed out.
    let snapshot: SharedSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = SharedSnapshotStore.appGroup()?.read()
        completion(SnapshotEntry(date: .now, snapshot: stored ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads the timeline whenever the snapshot changes; relative times stay fresh
        // through `Text(_:style:)`, so nothing needs scheduling here.
        let entry = SnapshotEntry(date: .now, snapshot: SharedSnapshotStore.appGroup()?.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: Quick chat (small, medium)

struct QuickChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.unrush.theseus.quick-chat", provider: SnapshotProvider()) { entry in
            QuickChatView(entry: entry)
                .containerBackground(Palette.background.color, for: .widget)
        }
        .configurationDisplayName("Quick chat")
        .description("Start a chat, snap a photo or dictate. The larger size also shows your recent chats.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickChatView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.isProUnlocked {
            // ADR 0173: widgets are part of Theseus Pro; a tap opens the paywall.
            ProLockedView()
        } else if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                HStack(spacing: Spacing.l) {
                    QuickActions(actions: snapshot.actions, includesVoiceMode: true)
                    RecentChatsList(chats: Array(snapshot.recentChats.prefix(3)))
                }
            default:
                QuickActions(actions: snapshot.actions, includesVoiceMode: false)
            }
        } else {
            SignedOutView()
        }
    }
}

/// The "Chat" pill on top, round action buttons below.
struct QuickActions: View {
    let actions: SharedSnapshot.Actions
    let includesVoiceMode: Bool

    private var buttons: [(ChatStartOption, String, String)] {
        var buttons: [(ChatStartOption, String, String)] = []
        if actions.photos { buttons.append((.camera, "camera", "Take a photo")) }
        if actions.dictation { buttons.append((.dictation, "mic", "Dictate")) }
        if includesVoiceMode, actions.voiceMode { buttons.append((.voiceMode, "waveform", "Voice mode")) }
        return buttons
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            Button(intent: NewChatIntent(start: nil)) {
                HStack(spacing: Spacing.s) {
                    BrandMark().frame(width: 22, height: 22)
                    Text("Chat")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.textPrimary.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.recessedSurface.color, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New chat")
            if !buttons.isEmpty {
                HStack(spacing: Spacing.s) {
                    ForEach(buttons, id: \.0) { option, symbol, label in
                        Button(intent: NewChatIntent(start: option)) {
                            Image(systemName: symbol)
                                .font(.system(size: 19, weight: .regular))
                                .foregroundStyle(Palette.textPrimary.color)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Palette.recessedSurface.color, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label)
                    }
                }
            }
        }
    }
}

/// Up to three recent Chats; each opens its Chat.
struct RecentChatsList: View {
    let chats: [SharedSnapshot.Chat]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Recents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary.color)
            if chats.isEmpty {
                Text("Your chats show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textTertiary.color)
                Spacer(minLength: 0)
            } else {
                ForEach(chats) { chat in
                    Link(destination: DeepLink.chat(id: chat.id).url) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.title.isEmpty ? "New chat" : chat.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.textPrimary.color)
                                .lineLimit(1)
                            Text(chat.updatedAt, format: .relative(presentation: .named))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textTertiary.color)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SignedOutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            BrandMark().frame(width: 28, height: 28)
            Spacer(minLength: 0)
            Text("Sign in to Theseus to start chatting.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textSecondary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLink.newChat.url)
    }
}

/// The widget in the free tier (ADR 0173): what it is, and that a tap unlocks it.
struct ProLockedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            BrandMark().frame(width: 28, height: 28)
            Spacer(minLength: 0)
            Text("Quick chat is part of Theseus Pro.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary.color)
            Text("Tap to unlock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.accent.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLink.pro.url)
    }
}

// MARK: Lock Screen

/// A Lock Screen circle that opens a new Chat.
struct NewChatAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.unrush.theseus.new-chat", provider: SnapshotProvider()) { entry in
            // ADR 0173: in the free tier the circle shows a lock and opens the paywall.
            let isLocked = entry.snapshot?.isProUnlocked == false
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: isLocked ? "lock" : "plus.bubble")
                    .font(.system(size: 20, weight: .medium))
            }
            .widgetURL(isLocked ? DeepLink.pro.url : DeepLink.newChat.url)
            .accessibilityLabel(isLocked ? "Unlock Theseus Pro" : "New chat in Theseus")
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("New chat")
        .description("Opens a new chat in Theseus.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: Previews

extension SharedSnapshot {
    static let preview = SharedSnapshot(
        accountID: "preview",
        accountName: "Ada",
        serverHost: "chat.example.com",
        actions: .init(voiceMode: true, dictation: true, photos: true, incognitoChat: true),
        recentChats: [
            .init(id: "1", title: "Weekend in Lisbon", updatedAt: .now.addingTimeInterval(-600)),
            .init(id: "2", title: "Sourdough schedule", updatedAt: .now.addingTimeInterval(-7200)),
            .init(id: "3", title: "Swift concurrency questions", updatedAt: .now.addingTimeInterval(-90000)),
        ]
    )
}

#Preview("Small", as: .systemSmall) {
    QuickChatWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}

#Preview("Medium", as: .systemMedium) {
    QuickChatWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
    SnapshotEntry(date: .now, snapshot: nil)
}
