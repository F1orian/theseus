import ChatDomain
import ComposerFeature
import DesignSystem
import OpenWebUIKit
import Rendering
public import SwiftUI

/// The conversation screen for one Chat, or a new Chat when `chatID` is `nil` (CHAT-01, 10).
/// Needs `ChatServices` in the environment.
///
/// ```swift
/// ConversationView(chatID: chat.id).environment(services)
/// ```
public struct ConversationView: View {
    private let chatID: String?
    private let projectID: String?
    private let isIncognito: Bool
    private let provided: ConversationModel?
    @Environment(ChatServices.self) private var services
    @State private var resolved: ConversationModel?

    /// - Parameter projectID: For a new Chat (`chatID == nil`): the Project it starts in.
    public init(chatID: String?, projectID: String? = nil) {
        self.chatID = chatID
        self.projectID = projectID
        isIncognito = false
        provided = nil
    }

    /// A new Incognito chat (INCOG-01).
    init(incognito: Void) {
        chatID = nil
        projectID = nil
        isIncognito = true
        provided = nil
    }

    public init(model: ConversationModel) {
        chatID = model.chatID
        projectID = model.projectID
        isIncognito = model.isIncognito
        provided = model
    }

    /// A new Incognito chat (INCOG-01), as a `ConversationView` so the app shell can keep one
    /// view type for every Chat route.
    public static func incognito() -> ConversationView {
        ConversationView(incognito: ())
    }

    public var body: some View {
        // After a new Chat gets its id the shell asks for `chatID`, but this view (and its state)
        // stays: keep showing the same live Conversation (ADR 0130).
        let live = resolved.flatMap { $0.chatID == chatID || chatID == nil ? $0 : nil }
            ?? chatID.flatMap(services.liveConversation(chatID:))
        if let model = provided ?? live {
            ConversationScreen(model: model)
        } else {
            Color.clear
                .themedBackground()
                .onAppear {
                    resolved = chatID.map(services.conversation(chatID:))
                        ?? (isIncognito ? services.newIncognitoConversation() : services.newConversation(projectID: projectID))
                }
        }
    }
}

/// An Incognito chat (INCOG-01; server term: temporary chat): it's never saved, listed or cached,
/// and it's gone once the screen goes away. Needs `ChatServices` in the environment.
public struct IncognitoChatView: View {
    public init() {}

    public var body: some View {
        ConversationView(incognito: ())
    }
}

/// The new-chat entry: an empty Conversation that becomes a saved Chat on first send, inside
/// `projectID`'s Project when there is one.
public struct NewChatView: View {
    private let projectID: String?

    public init(projectID: String? = nil) {
        self.projectID = projectID
    }

    public var body: some View {
        ConversationView(chatID: nil, projectID: projectID)
    }
}

struct ConversationScreen: View {
    @Bindable var model: ConversationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatNavigation) private var navigation
    @Environment(\.messageAccessories) private var accessories
    @Environment(\.transcriptExtensions) private var extensions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position = ScrollPosition(edge: .bottom)
    /// Scroll facts that change many times a second; kept out of SwiftUI's dependency graph so a
    /// gliding follow-scroll doesn't re-render the transcript on every frame (ADR 0130).
    @State private var tracking = ScrollTracking()
    @State private var following = true
    /// Away from the bottom, and not just trailing a stream that the view is following.
    @State private var showsScrollToBottom = false
    @State private var confirmingDelete = false
    /// Off while the Chat first loads (its Messages appear at once); on from then, so new
    /// Messages, the Response and its footer animate in (ADR 0130).
    @State private var animatesChanges = false
    /// The first Message of the transcript's always-built tail (`TranscriptSections`, #197).
    @State private var tailStart: String?
    /// Which steps are open, for every row (#197).
    @State private var disclosures = TranscriptDisclosures()
    /// The floating header's height (taller when an extension adds a row, e.g. the Artifacts pill).
    @State private var headerHeight: CGFloat = 64
    /// The docked composer's height, with its notices and Skills suggestions (#152).
    @State private var bottomBarHeight: CGFloat = 120

    private var services: ChatServices { model.services }
    /// The widest the transcript and composer get (PLAT-05); iPhone windows are narrower.
    static let readableWidth: CGFloat = 780
    static let rowSpacing = Spacing.xl + 4

    var body: some View {
        ZStack(alignment: .top) {
            content
                // Loading → the transcript (or the error) cross-fades.
                .motionSafeAnimation(Motion.fade, value: contentPhase)
            VStack(spacing: 0) {
                ConversationHeader(
                    chatID: model.chatID,
                    title: model.title,
                    projectName: model.projectName,
                    canDelete: model.chatID != nil && model.capabilities.contains(.deleteChat),
                    isHome: model.isNewChat,
                    isIncognito: model.isIncognito,
                    // Incognito chats are never saved, so they can't start inside a Project.
                    canGoIncognito: model.capabilities.contains(.incognitoChat) && model.projectID == nil,
                    // The Incognito hero reaches the top edge, under the header's buttons.
                    showsBackdrop: !(model.isIncognito && model.isNewChat),
                    onBack: { dismiss() },
                    onDelete: { confirmingDelete = true },
                    onIncognitoPlaceholder: { model.composer.notice = "Incognito chats are coming to Theseus soon." }
                )
                extensions.header?(model)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Its own view: what it reads (the draft, through `canSend`) re-renders the bar on each
            // keystroke, not the transcript.
            ConversationBottomBar(model: model)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
        }
        .overlay(alignment: .bottom) {
            ZStack { scrollToBottomButton }
                .motionSafeAnimation(Motion.snappy, value: showsScrollToBottom)
        }
        .themedBackground()
        // Every mouse here (avatar, home, the working tail) sits on its dark-mode backdrop (brand.md §3).
        .mouseBackdrop()
        // INCOG-01 (brand.md §4): an Incognito chat is always night, the art and the composer alike.
        .preferredColorScheme(model.isIncognito ? .dark : nil)
        // A sent Message rises from the composer while the composer clears, the greeting fades
        // and the send button turns into stop: one spring for the whole send (CHAT-01).
        .motionSafeAnimation(animatesChanges ? Motion.message : nil, value: model.thread.count)
        // MSG-04: switching Branches cross-fades the Messages that differ (a send is the spring
        // above: the inner modifier wins when both change).
        .motionSafeAnimation(animatesChanges ? Motion.fade : nil, value: model.thread.map(\.id))
        // The footer, the action row and follow-ups arrive with the finished Response.
        .motionSafeAnimation(animatesChanges ? Motion.smooth : nil, value: model.isStreaming)
        .environment(\.animatesContentAppearance, animatesChanges)
        .navigationTitle(model.title)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            await model.load()
            // Let the loaded transcript lay out before changes start to animate.
            try? await Task.sleep(for: .milliseconds(150))
            animatesChanges = true
        }
        .conversationHaptics(model)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { services.resume() }
        }
        .onChange(of: model.chatID) { old, new in
            if old == nil, let new { navigation.chatCreated?(new) }
        }
        .onDisappear {
            if let chatID = model.chatID { services.release(chatID: chatID) }
        }
        .alert("Delete this chat?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from this Server for good.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .failed(let message) where model.thread.isEmpty:
            // Brand: Piranesi's labyrinth, the mouse peeking over the frame, and "Try again".
            LabyrinthErrorView(message: loadErrorMessage(message)) { Task { await model.load() } }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.loadError")
        case .loading where model.thread.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            transcript
        }
    }

    private var transcript: some View {
        let sections = TranscriptSections(thread: model.thread, tailStart: tailStart)
        return ScrollView {
            // #197: one lazy stack as the scroll content, so it and the scroll view keep what's on
            // screen in place as their estimates of unbuilt rows change. Older Messages are its
            // rows, in chunks of similar size; the tail is its last row, always built, so the end
            // (opening there, a stream, a send, the footer) never meets estimated rows.
            LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(sections.historyChunks) { chunk in
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(chunk.messages) { message in
                            row(message)
                        }
                    }
                    // Older Messages never arrive: they show at once when they scroll back in.
                    .environment(\.animatesContentAppearance, false)
                }
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(sections.tail) { message in
                        row(message)
                    }
                    if showsFooter {
                        ResponseFooter()
                            .motionSafeTransition(.rise)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl - 4)
            // PLAT-05: a readable column in wide windows (iPad, Mac).
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, max(72, headerHeight + 8))
            // Clear of the composer's fade (#188) when scrolled to the end.
            .padding(.bottom, Spacing.l + ComposerBackdrop.fade)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Open steps stay open while their rows come and go (#197).
        .environment(\.transcriptDisclosures, disclosures)
        // Keep the boundary while the Chat is open, so no Message moves between the sections.
        .onChange(of: sections.tailStartID, initial: true) { _, id in tailStart = id }
        .accessibilityIdentifier("conversation.transcript")
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($position)
        .overlay {
            if model.isNewChat {
                Group {
                    if model.isIncognito {
                        IncognitoNotice()
                            .allowsHitTesting(false)
                    } else {
                        // Only "Today in the collection" and the mouse (#174) take taps; the greeting lets them through.
                        HomeGreetingView(services: services.composer) { [model] prompt in
                            model.composer.prefill(prompt)
                        }
                        .padding(.top, headerHeight)
                    }
                }
                // The greeting gives way to the first Message (HOME-01); a fade, since the mouse
                // never scales (brand.md §3).
                .motionSafeTransition(.opacity)
            }
        }
        .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
            // `visibleRect` spans the insets too; the bottom inset is the composer docked on top.
            ScrollFacts(
                distanceFromBottom: geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom),
                // `scrollTo(y:)` counts from the top of the content, inside the top inset.
                offsetY: geometry.contentOffset.y + geometry.contentInsets.top
            )
        } action: { _, facts in
            tracking.offsetY = facts.offsetY
            // Never follows again on its own (#183): a stream growing under a resting finger, or a
            // small drag near the end, doesn't pull the view along.
            tracking.follow.geometryChanged(distanceFromBottom: facts.distanceFromBottom)
            syncFollowing()
            // While following, the end stays at the end (#197). The lazy stack places a row, then
            // learns its real height: while the loaded Chat settles that leaves the end above or
            // below the composer, and later a row that turns out shorter leaves room below the
            // last Message. Growth after that is the follow's to glide to; a user's own bounce at
            // the end is theirs.
            let settling = !animatesChanges && abs(facts.distanceFromBottom) > 1
            if following, !tracking.follow.isUserScrolling, settling || facts.distanceFromBottom < -1 {
                var snap = Transaction(animation: nil)
                snap.disablesAnimations = true
                withTransaction(snap) { position.scrollTo(edge: .bottom) }
            }
        }
        .onScrollPhaseChange { _, phase in
            apply(tracking.follow.phaseChanged(to: TranscriptFollow.Phase(phase)))
        }
        // #183: SwiftUI reports no scroll phase for a finger that rests (or lands during a follow
        // animation), so the transcript watches its touches too.
        .onTouches(
            began: { apply(tracking.follow.touchBegan()) },
            ended: { apply(tracking.follow.touchEnded()) }
        )
        .onChange(of: streamRevision) {
            // Glide along with the stream rather than jumping a line at a time; each chunk
            // retargets the scroll, so it reads as one continuous follow.
            guard following, !tracking.follow.isUserScrolling else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: Motion.Duration.medium)) {
                position.scrollTo(edge: .bottom)
            }
        }
        // #151: what lands after the stream (the footer, the action row, follow-up suggestions)
        // stays in view while the user follows along.
        .onChange(of: tailKey) {
            guard following, !tracking.follow.isUserScrolling else { return }
            withAnimation(reduceMotion ? nil : Motion.smooth) { position.scrollTo(edge: .bottom) }
        }
        // Sending a Message follows again.
        .onChange(of: model.thread.count) {
            followAgain()
            withAnimation(reduceMotion ? nil : .snappy) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.thread.isEmpty) { updateScrollToBottom() }
    }

    /// The full-screen error's line, naming the Server: it isn't answering (offline or
    /// unreachable), or it answered with `message`.
    private func loadErrorMessage(_ message: String) -> String {
        let host = ServerDisplay.host(services.client.server, fallback: "Your server")
        switch services.connection {
        case .offline:
            return "You're offline, so \(host) can't be reached. Try again once you're back online."
        case .serverUnreachable:
            return "\(host) isn't answering. Try again in a moment."
        default:
            return "\(host) couldn't open this chat. \(message)"
        }
    }

    /// Mirrors the scroll tracker into the rendered state, writing only what changed (each write
    /// re-renders the screen).
    private func syncFollowing() {
        let follow = tracking.follow
        if following != follow.isFollowing { following = follow.isFollowing }
        updateScrollToBottom()
    }

    /// Acts on a change of who drives the transcript (#183).
    private func apply(_ change: TranscriptFollow.Change?) {
        if change == .stopped {
            // A finger on the transcript stops it where it is: cancel the follow scroll in flight
            // by holding the current offset, without animation.
            var hold = Transaction(animation: nil)
            hold.disablesAnimations = true
            withTransaction(hold) { position.scrollTo(y: tracking.offsetY) }
        }
        syncFollowing()
    }

    /// The jump-to-bottom button or a sent Message: follow the stream again.
    private func followAgain() {
        tracking.follow.follow()
        syncFollowing()
    }

    private func updateScrollToBottom() {
        let shows = tracking.follow.showsJumpToBottom && !model.thread.isEmpty
        if showsScrollToBottom != shows { showsScrollToBottom = shows }
    }

    /// Changes when content arrives under the latest Response after its stream ended.
    private var tailKey: [Int] {
        let followUps = model.thread.last.map { model.followUps(for: $0).count } ?? 0
        return [model.isStreaming ? 1 : 0, showsFooter ? 1 : 0, followUps]
    }

    /// Which of loading, failed or the transcript shows.
    private var contentPhase: Int {
        guard model.thread.isEmpty else { return 0 }
        switch model.loadState {
        case .failed: return 2
        case .loading: return 1
        default: return 0
        }
    }

    /// Changes whenever streamed content grows, so the view can follow it.
    private var streamRevision: Int {
        guard let id = model.streamingMessageID else { return -1 }
        return model.responses[id]?.revision ?? 0
    }

    private var showsFooter: Bool {
        guard let last = model.thread.last, last.role == .assistant, !model.isStreaming else { return false }
        return model.response(for: last).isFinished
    }

    private func row(_ message: Message) -> some View {
        rowContent(message)
            .environment(\.transcriptRowID, message.id)
    }

    @ViewBuilder
    private func rowContent(_ message: Message) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                // ATT-04: the Message's photos and files sit above its bubble.
                if !message.attachments.isEmpty {
                    MessageAttachmentsView(attachments: message.attachments, images: services.composer.images)
                        .padding(.bottom, Spacing.xs)
                }
                if !message.content.isEmpty {
                    UserBubble(text: message.content, menuExtras: accessories.userMessageMenu?(model, message))
                }
                accessories.userMessage?(model, message)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .motionSafeTransition(.messageInsert)
        case .assistant:
            let state = model.response(for: message)
            VStack(alignment: .leading, spacing: Spacing.m) {
                responseView(message, state: state)
                    .environment(\.codeBlockReplacement, codeBlockReplacement(for: message))
                extensions.responseContent?(model, message)
                accessories.response?(model, message)
                // #141: suggested next prompts under the latest Response, when the user wants them.
                let suggestions = model.followUps(for: message)
                if !suggestions.isEmpty {
                    FollowUpChips(suggestions: suggestions) { text in
                        Task { await model.sendFollowUp(text) }
                    }
                    // #141: they arrive a moment after the Response, from a background task.
                    .appearsWithFade()
                    .motionSafeTransition(.rise)
                }
            }
            .id(message.id)
            .motionSafeTransition(.opacity)
        case .system:
            EmptyView()
        }
    }

    /// Routes a Response's code blocks through `extensions.codeBlock` (e.g. Artifact cards).
    private func codeBlockReplacement(for message: Message) -> CodeBlockReplacement? {
        guard let hook = extensions.codeBlock else { return nil }
        return CodeBlockReplacement(id: "\(extensions.id)|\(message.id)") { [model] language, code in
            hook(model, message, language, code)
        }
    }

    private func responseView(_ message: Message, state: ResponseState) -> some View {
        // Equatable: while one Response streams, the others skip their body entirely, so a
        // chunk re-renders one Response, not the whole transcript (ADR 0010, ADR 0130).
        ResponseView(
            state: state,
            showsSources: model.capabilities.contains(.sources),
            showsStatus: model.selectedModel?.capabilities.supports("status_updates") ?? true,
            // The latest Response only, checked first: `parts` is built from the content each time.
            onRetry: message.id == model.thread.last?.id && !model.isStreaming
                && (state.phase == .failed || (state.phase == .completed && state.parts.isEmpty))
                ? { Task { await model.retry(message.id) } }
                : nil,
            toolSteps: extensions.toolSteps.map { hook in
                { [model] steps in hook(model, message, steps) }
            }
        )
        .equatable()
    }

    @ViewBuilder
    private var scrollToBottomButton: some View {
        if showsScrollToBottom {
            Button {
                followAgain()
                withAnimation(reduceMotion ? nil : .snappy) { position.scrollTo(edge: .bottom) }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            // #152: just above the composer and whatever it shows (notices, Skills suggestions).
            .padding(.bottom, bottomBarHeight + Spacing.m)
            .accessibilityLabel("Scroll to bottom")
            .accessibilityIdentifier("conversation.scrollToBottom")
            .motionSafeTransition(.pop)
        }
    }

    private func delete() async {
        guard let chatID = model.chatID else { return }
        do {
            _ = try await services.client.send(.deleteChat(id: chatID))
            services.chatListChanged()
            dismiss()
        } catch {
            model.notice = "Couldn't delete the chat. \(error.message)"
        }
    }
}

/// The docked composer, or the card the Response waits on (a clarifying question, a tool call to
/// allow), with connection and notice banners.
struct ConversationBottomBar: View {
    let model: ConversationModel
    @Environment(\.conversationVoice) private var conversationVoice
    @Environment(\.composerVoice) private var inheritedComposerVoice

    private var services: ChatServices { model.services }

    var body: some View {
        VStack(spacing: Spacing.s) {
            ConnectionBanner(status: services.connection, host: ServerDisplay.host(services.client.server, fallback: "the server"))
            if let pending = model.pendingQuestion {
                ClarifyingQuestionCard(
                    questions: pending.questions,
                    onSubmit: { model.answer($0) },
                    onDismiss: { model.answer(nil) }
                )
                .id(pending.questions.callID)
                .motionSafeTransition(.move(edge: .bottom).combined(with: .opacity))
            } else if let approval = model.pendingApproval {
                // OT-06: a tool call waits for Allow or Deny.
                ToolApprovalCard(call: approval.call) { allow in model.resolveApproval(allow: allow) }
                    .id(approval.call.resolvedCallID)
                    .motionSafeTransition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ComposerView(
                    model: model.composer,
                    isNewChat: model.isNewChat,
                    isStreaming: model.isStreaming,
                    canSend: model.canSend,
                    notices: notices,
                    onNoticeDismiss: dismissNotice,
                    onSend: { Task { await model.send() } },
                    onStop: { Task { await model.stop() } }
                )
                // Dictation and Voice mode (VOICE-01, VOICE-03), when the app provides them.
                .environment(\.composerVoice, conversationVoice.composerActions?(model) ?? inheritedComposerVoice)
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(maxWidth: ConversationScreen.readableWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.s)
        // #188: Messages fade out behind and below the composer, as they do under the header.
        .background { ComposerBackdrop() }
        .animation(.snappy, value: services.connection)
        .animation(.snappy, value: model.pendingQuestion)
        .animation(.snappy, value: model.pendingApproval?.call)
    }

    /// Notices docked on the composer (HOME-04): this Chat's problems, a model the Server
    /// dropped, and the admin's banners.
    private var notices: [ComposerNotice] {
        var notices: [ComposerNotice] = []
        if let notice = model.notice {
            notices.append(ComposerNotice(id: "conversation.notice", text: notice))
        }
        if let missing = model.composer.unavailableModelID {
            notices.append(ComposerNotice(
                id: ComposerNotice.unavailableModelID,
                text: "\(missing) is no longer available on this Server. Replies use \(model.composer.chipTitle).",
                actionTitle: "Choose a model",
                isDismissible: false,
                tone: .warning
            ))
        }
        for banner in services.composer.visibleBanners {
            let text = [banner.title, banner.content].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
            notices.append(ComposerNotice(id: "banner.\(banner.id)", text: text, isDismissible: banner.isDismissible, tone: banner.kind == .warning || banner.kind == .error ? .warning : .neutral))
        }
        return notices
    }

    private func dismissNotice(_ notice: ComposerNotice) {
        if notice.id == "conversation.notice" {
            model.notice = nil
        } else if notice.id.hasPrefix("banner."),
                  let banner = services.composer.visibleBanners.first(where: { "banner.\($0.id)" == notice.id }) {
            services.composer.dismiss(banner)
        }
    }
}

/// Scroll position facts the transcript reads in callbacks but never renders from.
@MainActor
private final class ScrollTracking {
    /// Whether the transcript follows the stream, from the user's scrolling (#183).
    var follow = TranscriptFollow()
    /// The scroll offset now (from the top of the content), to hold it when a finger lands
    /// mid-follow.
    var offsetY: CGFloat = 0
}

/// What the transcript reads from its scroll geometry.
private struct ScrollFacts: Equatable {
    var distanceFromBottom: CGFloat
    var offsetY: CGFloat
}

extension TranscriptFollow.Phase {
    init(_ phase: ScrollPhase) {
        switch phase {
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        default: self = .idle
        }
    }
}

/// Under the latest Response: the assistant's avatar, the mouse's `head` at 2 pt per pixel
/// (brand.md §3), which reacts when tapped (#174), and a small disclaimer (CHAT-10).
struct ResponseFooter: View {
    var body: some View {
        HStack(alignment: .center) {
            PettableMouse(.pose(.head), scale: 2)
            Spacer(minLength: Spacing.l)
            Text("Models can be wrong.\nCheck what matters.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.disclaimer")
    }
}
