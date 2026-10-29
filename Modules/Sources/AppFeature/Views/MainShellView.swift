import ArtifactsFeature
import ChatDomain
import ChatFeature
import ComposerFeature
import ConnectorsFeature
import DesignSystem
import Entitlements
import LibraryFeature
import OnboardingFeature
import MessageActionsFeature
import OpenWebUIKit
import PersonalizationFeature
import ProjectsFeature
import SandboxFeature
import SettingsFeature
import SwiftUI
import VoiceFeature

/// The signed-in shell: the navigation drawer (CHATS-01) over the screen for `model.route`.
struct MainShellView: View {
    @Bindable var model: MainShellModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// PLAT-05: on regular width (iPad, Mac) the drawer is a persistent sidebar.
    private var usesSidebar: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if usesSidebar {
                SidebarShell(isSidebarHidden: $model.isSidebarHidden) { drawer } detail: { screen }
            } else {
                DrawerContainer(isOpen: $model.isDrawerOpen) { drawer } content: { screen }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: Spacing.s) {
                LibraryNotice(library: model.library)
                ProjectsNotice(library: model.projects)
            }
            // Top toasts (MSG-02 style) drop in and lift away (ADR 0130).
            .motionSafeAnimation(Motion.toast, value: model.library.errorMessage)
            .motionSafeAnimation(Motion.toast, value: model.projects.notice)
            .motionSafeAnimation(Motion.toast, value: model.projects.errorMessage)
            // PLAT-02: a failed library or Project action plays the error pattern.
            .hapticCue(trigger: model.library.errorMessage) { _, new in new == nil ? nil : .error }
            .hapticCue(trigger: model.projects.errorMessage) { _, new in new == nil ? nil : .error }
        }
        .environment(\.libraryNavigate, LibraryNavigateAction { [model] destination in
            model.navigate(to: AppRoute(destination))
        })
        // PROJ-06: "Add to project" in the Chat menu.
        .environment(\.chatMenuExtras, ChatMenuExtras(addToProject: { [model] chat in
            // The sheet can only appear once the Chat menu popover has finished dismissing.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                model.chatAddingToProject = chat
            }
        }, files: { [model] chat in
            // OT-04: the Chat's sandbox files, once the popover is gone.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                model.chatBrowsingFiles = chat
            }
        }))
        .sheet(item: $model.chatBrowsingFiles) { chat in
            if let sandbox = model.sandbox,
               let terminalID = Sandbox.terminalID(for: model.chat?.model(id: model.chat?.preferredModelID), among: model.terminals ?? []) {
                SandboxBrowserView(model: sandbox.browser(terminalID: terminalID, chatID: chat.id))
            }
        }
        .sheet(item: $model.chatAddingToProject) { chat in
            AddToProjectSheet(library: model.projects, chat: chat) { [model] moved in
                model.library.upsert(moved)
            }
        }
        .sheet(isPresented: $model.isSettingsPresented, onDismiss: {
            // Profile, Instructions or Memory may have changed (PERS-01..03).
            Task { await model.refreshPersonalization() }
        }) {
            if let settings = model.settings {
                SettingsView(model: settings)
                    // AUTH-07: presented on top of Settings, which offers "Switch account".
                    .sheet(item: $model.accountSwitcher) { switcher in
                        AccountSwitcherView(model: switcher)
                    }
            }
        }
        // AUTH-08: the one-time welcome after an Account's first sign-in.
        .sheet(item: $model.welcome, onDismiss: { [model] in model.finishWelcome() }) { summary in
            WelcomeSheet(summary: summary) { [model] in model.finishWelcome() }
        }
        // ADR 0173: a widget, Shortcut, Share or link in the free tier, and `theseus://pro`.
        .paywall($model.paywallRequest) { [model] in model.paywallDismissed() }
        // VOICE-03…07: Voice mode over the whole shell, its ended banner and the Dictation intro.
        .voice(model.voice)
        // SET-02 / SET-03: the Account's appearance and haptics apply to the whole shell.
        .appearance(model.preferences.preferences.appearance)
        .environment(\.hapticFeedbackEnabled, model.preferences.preferences.hapticFeedback)
        // HOME-01 (BRAND-03): "Today in the collection" on the new-chat home, unless turned off.
        .environment(\.showsTodayArtwork, model.preferences.preferences.showsTodayArtwork)
        .onChange(of: scenePhase) {
            model.isSceneActive = scenePhase == .active
            // Chats may have changed on other devices while Theseus was in the background.
            if scenePhase == .active, model.state == .loaded {
                Task { await model.library.refresh() }
                // PLAT-04: something shared while Theseus couldn't be opened.
                model.openWaitingShare()
            }
        }
        // ADR 0100: keep the widgets' and Shortcuts' view of this Account current.
        .onChange(of: model.sharedSnapshot, initial: true) {
            model.publishSharedSnapshot()
        }
        // ADR 0173: every paywall, upgrade card and Pro page under the shell (sheets included)
        // promises only what this Server offers.
        .environment(\.serverSupport, model.serverSupport)
    }

    /// The drawer's content: the persistent sidebar on regular width (PLAT-05).
    private var drawer: some View {
        DrawerView(
            library: model.library,
            accountName: model.account.name,
            // The library lists saved Chats' Artifacts, so it goes with the history (ART-04).
            showsArtifacts: model.showsArtifacts && model.incognitoPolicy.savesChats,
            // Enforced Incognito chats: nothing is saved, so there's no history (INCOG-02).
            showsHistory: model.incognitoPolicy.savesChats,
            activeSection: model.route.drawerSection,
            activeChatID: model.route.chatID
        )
    }

    private var screen: some View {
        destination(for: model.route)
            // A new Incognito chat replaces the current one (it has no id of its own).
            // A deep-linked new Chat (PLAT-03) replaces the new-chat screen already showing.
            // A new Chat that just got its id keeps its screen (`screenRoute`, ADR 0130).
            .id([
                AnyHashable(model.screenRoute), AnyHashable(model.screenGeneration),
                AnyHashable(model.incognitoGeneration), AnyHashable(model.launchGeneration),
            ])
    }

    /// The screen for each route. Feature areas replace their placeholder here.
    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        // Every Chat route is the same view in the same place, so a new Chat becoming a saved
        // one (`promoteNewChat(to:)`) keeps its screen, state and running animations.
        if let services = model.chat, let conversation = conversation(for: route) {
            chatScreen(conversation, services: services)
        } else {
            placeholderOrList(for: route)
        }
    }

    /// The Conversation for a Chat route (new, Incognito, saved), or `nil` for other screens.
    private func conversation(for route: AppRoute) -> ConversationView? {
        switch route {
        case .newChat(let projectID):
            model.preparedConversation.map(ConversationView.init(model:)) ?? ConversationView(chatID: nil, projectID: projectID)
        case .incognitoChat:
            model.preparedConversation.map(ConversationView.init(model:)) ?? .incognito()
        case .chat(let id):
            ConversationView(chatID: id)
        default:
            nil
        }
    }

    @ViewBuilder
    private func placeholderOrList(for route: AppRoute) -> some View {
        switch route {
        case .newChat, .incognitoChat:
            HomePlaceholderView(model: model)
        case .chat(let id):
            ChatPlaceholderView(chatID: id, library: model.library)
        case .chatsList:
            // ⌘K opens it searching (PLAT-05).
            ChatsListView(library: model.library, startsSearching: model.isChatsSearchRequested)
        case .projects:
            ProjectsListView(library: model.projects)
        case .artifacts:
            ArtifactsLibraryView(library: model.artifactLibrary)
        case .settings:
            // Presented as a sheet by `navigate(to:)`; never a screen of its own.
            HomePlaceholderView(model: model)
        }
    }
}

extension MainShellView {
    /// A Chat & streaming screen with the shell's drawer, new-chat route and Chat menu (CHATS-08).
    private func chatScreen(_ screen: some View, services: ChatServices) -> some View {
        NavigationStack {
            screen
                .modifier(MessageActionsWiring(actions: model.messageActions, library: model.library))
                // ART-01…03: Artifact cards, tool embeds and the "N artifacts" pill (ADR 0060);
                // PERS-05: the chosen Style's chip on the new-chat home; the sandbox's run cards and
                // created files (OT-02/03, ADR 0120).
                .environment(\.transcriptExtensions, transcriptExtensions
                    .merged(with: model.sandbox?.transcriptExtensions(images: services.composer.images) ?? TranscriptExtensions()))
        }
        .environment(services)
        // CONN-02: Add to Chat › Connectors; PERS-05: Choose style. Add to the inherited
        // extensions; don't replace them.
        .transformEnvironment(\.addToChatExtensions) { [connectors = model.connectors, styles = model.styles] extensions in
            ConnectorsRegistration.register(in: &extensions, directory: connectors)
            StylesRegistration.register(in: &extensions, library: styles)
        }
        .environment(\.chatNavigation, drawerLabelled(ChatNavigation(
            openDrawer: { [model, usesSidebar] in
                if usesSidebar { model.toggleSidebar() } else { model.isDrawerOpen = true }
            },
            startNewChat: { [model] in model.navigate(to: .newChat()) },
            overflowMenu: { [model] chatID in AnyView(ChatOverflowMenu(chatID: chatID, library: model.library)) },
            // The new Chat now has an id: show it as that Chat (drawer highlight, menus). The live
            // ConversationModel is reused, so the stream continues.
            chatCreated: { [model] chatID in model.promoteNewChat(to: chatID) },
            chatTitle: { [model] chatID in model.library.chat(id: chatID)?.title },
            startIncognitoChat: incognitoSwitch(to: .incognitoChat),
            leaveIncognitoChat: incognitoSwitch(to: .newChat())
        )))
        // VOICE-01 / VOICE-03: the composer's mic and voice buttons.
        .environment(\.conversationVoice, model.voice?.conversationVoice ?? ConversationVoice())
    }

    /// The Artifacts hooks (when on) plus the Style chip under the new-chat home's header.
    private var transcriptExtensions: TranscriptExtensions {
        var extensions = model.showsArtifacts ? Artifacts.transcriptExtensions : TranscriptExtensions()
        let artifactsHeader = extensions.header
        extensions.header = { [styles = model.styles] conversation in
            AnyView(VStack(spacing: Spacing.s) {
                artifactsHeader?(conversation)
                if conversation.isNewChat, conversation.capabilities.contains(.instructions) {
                    StyleChip(library: styles)
                }
            })
        }
        return extensions
    }

    /// The drawer button's label: the sidebar's state on regular width (PLAT-05).
    private func drawerLabelled(_ navigation: ChatNavigation) -> ChatNavigation {
        var navigation = navigation
        if usesSidebar { navigation.openDrawerLabel = model.isSidebarHidden ? "Show sidebar" : "Hide sidebar" }
        return navigation
    }

    /// INCOG-01: the home's ghost button and the Incognito chat's X. When the Server enforces
    /// Incognito chats there's nothing to switch between (INCOG-02).
    private func incognitoSwitch(to route: AppRoute) -> (@MainActor () -> Void)? {
        guard model.incognitoPolicy == .available else { return nil }
        // The header, the masks and the copy cross-fade in and out of Incognito.
        return { [model] in withMotion(Motion.fade) { model.navigate(to: route) } }
    }
}

/// Stand-in for the new-chat home (HOME-01, Home & composer epic): lists the Server's models.
private struct HomePlaceholderView: View {
    let model: MainShellModel

    var body: some View {
        NavigationStack {
            List {
                Section(ServerDisplay.host(model.account.server.url, fallback: model.account.server.name)) {
                    switch model.state {
                    case .failed(let message) where model.models.isEmpty:
                        Text(message)
                            .foregroundStyle(Palette.destructive.color)
                            .accessibilityIdentifier("models.error")
                    case .loading where model.models.isEmpty, .idle where model.models.isEmpty:
                        ProgressView().frame(maxWidth: .infinity)
                    default:
                        ForEach(model.models) { item in
                            ModelRow(
                                model: item,
                                isDefault: model.isDefault(item),
                                capabilities: model.capabilities(for: item)
                            )
                        }
                    }
                }
            }
            .accessibilityIdentifier("models.list")
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("New chat")
            .inlineNavigationTitle()
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigation) { DrawerButton() }
            }
        }
    }
}

/// Stand-in for the Chat screen (CHAT-*, Chat & streaming epic) with its real header: the
/// drawer button, the new-chat button (CHATS-10) and the `...` menu (CHATS-08).
private struct ChatPlaceholderView: View {
    let chatID: String
    let library: ChatLibrary

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.s) {
                Image(systemName: "text.bubble")
                    .font(.title3)
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(width: 48, height: 48)
                    .background(Palette.recessedSurface.color, in: .circle)
                Text(library.chat(id: chatID)?.title ?? "Chat")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat.title")
                Text("Messages appear here once the Chat screen is ready.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary.color)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .navigation) { DrawerButton() }
                ToolbarItemGroup(placement: .primaryAction) {
                    NewChatButton()
                    ChatOverflowMenu(chatID: chatID, library: library)
                }
            }
        }
        .accessibilityIdentifier("chat.screen")
    }
}

private struct ModelRow: View {
    let model: Model
    let isDefault: Bool
    let capabilities: Capabilities

    /// The Capabilities worth surfacing in a model list, with their SF Symbols.
    private static let badges: [(Capability, String, String)] = [
        (.imageInput, "photo", "Vision"),
        (.webSearch, "globe", "Web search"),
        (.codeInterpreter, "chevron.left.forwardslash.chevron.right", "Code interpreter"),
        (.imageGeneration, "paintbrush", "Image generation"),
    ]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(model.name)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.textPrimary.color)
                    if isDefault {
                        Text("Default")
                            .font(Typography.caption)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xxs)
                            .foregroundStyle(Palette.accent.color)
                            .background(Palette.accent.color.opacity(0.12), in: .capsule)
                    }
                }
                Text(model.description ?? model.id)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.s)
            HStack(spacing: Spacing.s) {
                ForEach(Self.badges.filter { capabilities.contains($0.0) }, id: \.0) { _, symbol, label in
                    Image(systemName: symbol)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary.color)
                        .accessibilityLabel(label)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .listRowBackground(Palette.surface.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model.\(model.id)")
    }
}

/// Plugs the Message actions (MSG-*) into the Chat screen: the action row, Branch pager and Edit
/// in the transcript, their sheets and toasts, and Share in the Chat menu (CHATS-08).
private struct MessageActionsWiring: ViewModifier {
    let actions: MessageActions?
    let library: ChatLibrary

    @ViewBuilder
    func body(content: Content) -> some View {
        if let actions {
            content
                .environment(\.messageAccessories, actions.accessories)
                // Add Share to the inherited extras; don't replace them, or Add to project (PROJ-06) is lost.
                .transformEnvironment(\.chatMenuExtras) { extras in
                    if let share = shareAction(actions) { extras.share = share }
                }
                .messageActions(actions)
        } else {
            content
        }
    }

    private func shareAction(_ actions: MessageActions) -> (@MainActor @Sendable (ChatSummary) -> Void)? {
        guard library.capabilities.contains(.publicChatLink) else { return nil }
        return { chat in actions.share(chatID: chat.id, title: chat.title) }
    }
}
