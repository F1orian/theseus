public import ChatDomain
import DesignSystem
import OpenWebUIKit
import Rendering
public import SwiftUI

/// A user Message: a right-aligned bubble in verdigris-tinted `accentSoft` in the sans UI face
/// (CHAT-01, brand.md §1).
struct UserBubble: View {
    let text: String
    /// Extra long-press entries after Copy (`MessageAccessories.userMessageMenu`).
    var menuExtras: AnyView?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .textSelection(.enabled)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(Palette.accentSoft.color, in: .rect(cornerRadius: Radius.large))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                    if let menuExtras { menuExtras }
                }
        }
        .accessibilityIdentifier("message.user")
    }
}

/// An assistant Response: bubble-less serif text with its Thinking, tool steps, Sources and
/// errors (CHAT-01, 03, 06, 07, 08, 13).
///
/// Equatable on what it draws (the closures are the same hooks for the same Message), so the
/// transcript can skip every Response but the streaming one (ADR 0130).
struct ResponseView: View, @MainActor Equatable {
    let state: ResponseState
    let showsSources: Bool
    let showsStatus: Bool
    let onRetry: (() -> Void)?
    /// Renders a run of tool steps in place of the status line (`TranscriptExtensions.toolSteps`).
    var toolSteps: (([ToolActivity]) -> AnyView?)?

    @State private var sourcesShown = false
    @State private var highlightedCitation: Int?
    /// The revision at which the stream was last seen quiet for `ResponseActivity.stallDelay`
    /// (#173): stalled while it's still the current one, so new text hides the mouse at once.
    @State private var quietRevision: Int?
    /// The steps whose details are open (#195), kept by the transcript: an older Response's row is
    /// rebuilt when it scrolls back into view (#197).
    private var disclosures = TranscriptDisclosureScope()

    private var citations: [Citation] { showsSources ? Citation.list(from: state.sources) : [] }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.showsSources == rhs.showsSources && lhs.showsStatus == rhs.showsStatus
            && (lhs.onRetry == nil) == (rhs.onRetry == nil) && (lhs.toolSteps == nil) == (rhs.toolSteps == nil)
    }

    var body: some View {
        // Built from the content on every read, so once per body.
        let allParts = state.parts
        let parts = allParts.filter { part in
            if case .status = part { return showsStatus }
            // Artifact steps (imported Chats) are cards, not status (#180).
            if case .tools(_, let steps) = part { return showsStatus || steps.contains { $0.name == ToolActivity.artifactsName } }
            return true
        }
        let activity = ResponseActivity(state)
        // A hook's view for a run of tool steps (Open Terminal runs, Artifacts), by part.
        let custom = customToolViews(parts)
        let live = LiveStep(parts: parts, activity: activity) { custom[$0.id] != nil }
        let work = activity.indicator(stalled: quietRevision == state.revision)
        VStack(alignment: .leading, spacing: ResponseTypography.blockSpacing) {
            // #195: a live step row at the tail is drawn by the tail mouse (its title is the
            // plaque), so it isn't drawn here until it finishes.
            ForEach(parts.filter { $0.id != live.absorbedPartID }) { part in
                partView(part, custom: custom[part.id])
                    // Each row moves as one piece, so a row whose content changes mid-move (a new
                    // title, a label) can't jump ahead of its own background (#191).
                    .geometryGroup()
                    // A new part (Thinking, a tool step, the text) eases in under the last one, once
                    // the rows below have made room for it (#191).
                    .motionSafeTransition(.arrive)
            }
            // The tail mouse is the one live indicator (#195): rows and cards drop their spinners.
            .environment(\.liveStatusAtTail, work != nil)
            if activity.isLive {
                // #173: the mouse keeps running at the tail while the Response works without a
                // visible stream. Its row stays reserved while the Response is live, so showing
                // and hiding it only fades (the transcript never reflows).
                WorkingIndicator(work: work, plaque: work.flatMap(live.plaque(for:)), details: tailDetails(live, parts: parts))
                    .geometryGroup()
                    .motionSafeTransition(.leaveAtOnce)
                    .task(id: state.revision) {
                        guard activity == .streamingText else { return }
                        let revision = state.revision
                        try? await Task.sleep(for: ResponseActivity.stallDelay)
                        if !Task.isCancelled { quietRevision = revision }
                    }
            }
            if !citations.isEmpty {
                SourcesButton(citations: citations) { sourcesShown = true }
                    // One piece: its label (a new count, new hosts) moves with its capsule (#191).
                    .geometryGroup()
                    .motionSafeTransition(.arrive)
            }
            if state.phase == .stopped {
                Label("Stopped", systemImage: "stop.circle")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
                    .accessibilityIdentifier("response.stopped")
                    .geometryGroup()
                    .motionSafeTransition(.arrive)
            }
            if state.phase == .failed {
                ResponseErrorView(message: state.error ?? "Something went wrong.", onRetry: onRetry)
                    .geometryGroup()
                    .motionSafeTransition(.arrive)
            } else if state.phase == .completed, parts.isEmpty, citations.isEmpty {
                // The model finished without writing anything (seen with some providers).
                ResponseErrorView(message: "The model didn't return a response.", onRetry: onRetry)
                    .geometryGroup()
                    .motionSafeTransition(.arrive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The mark hands over to the first words, a new part slides in under the last; the text
        // itself reveals glyph by glyph (Rendering's `streamingReveal`), so no height animates.
        // A finished step taking its row back from the tail (#195) is a new part too.
        .motionSafeAnimation(Motion.smooth, value: partsShape(allParts) + [live.absorbedPartID ?? ""])
        .environment(\.openURL, OpenURLAction { url in
            if let number = CitationLink.number(from: url) {
                highlightedCitation = number
                sourcesShown = true
                return .handled
            }
            return .systemAction
        })
        .sheet(isPresented: $sourcesShown) {
            SourcesSheet(citations: citations, highlighted: highlightedCitation)
                .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(verbatim: debugSummary(allParts)))
        .accessibilityIdentifier("message.response")
    }

    /// Which parts show, by id and kind — changes when a part arrives, not when text grows.
    private func partsShape(_ parts: [ResponsePart]) -> [String] {
        parts.map(\.id) + [state.sources.isEmpty ? "" : "sources", "\(state.phase)"]
    }

    /// The Response's state as its accessibility value (with sizes in debug builds, for UI tests).
    private func debugSummary(_ parts: [ResponsePart]) -> String {
        let phase = switch state.phase {
        case .waiting, .streaming: "Writing"
        case .awaitingAnswer: "Waiting for your answer"
        case .completed: "Complete"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
        #if DEBUG
        return "\(phase) chars:\(state.text.count) parts:\(parts.count)"
        #else
        return phase
        #endif
    }

    /// The hook's view for each run of tool steps that has one (`TranscriptExtensions.toolSteps`).
    private func customToolViews(_ parts: [ResponsePart]) -> [String: AnyView] {
        guard let toolSteps else { return [:] }
        var views: [String: AnyView] = [:]
        for part in parts {
            if case .tools(let id, let tools) = part, let view = toolSteps(tools) { views[id] = view }
        }
        return views
    }

    /// Whether the step `id` shows its details, kept across the live tail and its finished row
    /// (#195), so a step opened while it runs stays open.
    private func expansion(_ id: String) -> Binding<Bool> {
        disclosures.binding("part-\(id)")
    }

    /// The details of the live step the tail draws (#195): its tool steps or its reasoning, the
    /// same as the finished row's.
    private func tailDetails(_ live: LiveStep, parts: [ResponsePart]) -> WorkingIndicator.Details? {
        guard let id = live.absorbedPartID, let part = parts.first(where: { $0.id == id }) else { return nil }
        switch part {
        case .tools(_, let tools):
            guard tools.count > 1 || tools.first?.detail != nil else { return nil }
            return .init(isExpanded: expansion(id), shows: "Shows the steps", hides: "Hides the steps") {
                ToolStepDetails(tools: tools)
            }
        case .thinking(_, let text, let summary, _, _):
            return .init(isExpanded: expansion(id), shows: "Shows the model's reasoning", hides: "Hides the model's reasoning") {
                ThinkingDetails(text: text, summary: summary)
            }
        case .status, .text, .code, .answers:
            return nil
        }
    }

    @ViewBuilder
    private func partView(_ part: ResponsePart, custom: AnyView?) -> some View {
        switch part {
        case .thinking(let id, let text, let summary, let streaming, let duration):
            ThinkingBlock(text: text, summary: summary, isStreaming: streaming, duration: duration, expanded: expansion(id))
        case .text(_, let markdown, let streaming):
            StreamingMarkdownView(text: markdown, isStreaming: streaming, citations: !citations.isEmpty)
        case .tools(let id, let tools):
            if let custom {
                custom
            } else {
                ToolActivityLine(tools: tools, expanded: expansion(id))
            }
        case .status(_, let update):
            StatusLine(update: update, isLive: !state.isFinished)
        case .code(_, let execution):
            CodeExecutionView(execution: execution, isLive: !state.isFinished)
        case .answers(_, let answers):
            AnsweredQuestionsCard(answers: answers)
        }
    }
}

/// At the tail of a live Response (CHAT-01, #173, #185, brand.md §3): while the model works
/// without a visible stream, the working mouse plays the compact scene for the work (a globe for
/// web search, the keyboard for a command, …; 6 fps, a still frame under Reduce Motion) beside a
/// plaque naming it (`SEARCHING THE WEB…`, `RUNNING COMMAND…`, `THINKING…`). A new kind of work
/// cross-fades in, in place. Paused on the user it peeks with a blinking `?` (`YOUR TURN`) above
/// the card. With `work == nil` (text is streaming) it keeps its room but fades out, so it can come
/// back without a reflow.
struct WorkingIndicator: View {
    let work: ResponseActivity.Work?
    /// What the plaque says; `nil` shows the mouse alone, while a live card says what runs (#195).
    let plaque: String?
    /// The live step's details under the tail, when the tail draws a step row (#195).
    let details: Details?
    /// The last work and plaque shown, kept while the indicator fades out.
    @State private var shownWork: ResponseActivity.Work
    @State private var shownPlaque: String?
    /// The scenes, cross-fading in place (#194).
    @State private var layers: SceneLayers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A live step row's details (its tool steps, its reasoning), opened from the plaque's
    /// chevron as from the finished row's (#195).
    struct Details {
        let isExpanded: Binding<Bool>
        /// The accessibility hints while closed and while open.
        let shows: String
        let hides: String
        let content: AnyView

        init(isExpanded: Binding<Bool>, shows: String, hides: String, @ViewBuilder content: () -> some View) {
            self.isExpanded = isExpanded
            self.shows = shows
            self.hides = hides
            self.content = AnyView(content())
        }
    }

    /// The tail for `work`, with its own plaque.
    init(work: ResponseActivity.Work?) {
        self.init(work: work, plaque: work?.plaque)
    }

    init(work: ResponseActivity.Work?, plaque: String?, details: Details? = nil) {
        self.work = work
        self.plaque = plaque
        self.details = details
        _shownWork = State(initialValue: work ?? .thinking)
        _shownPlaque = State(initialValue: work == nil ? ResponseActivity.Work.thinking.plaque : plaque)
        _layers = State(initialValue: SceneLayers((work ?? .thinking).scene))
    }

    var body: some View {
        let isShown = work != nil
        let isExpanded = details?.isExpanded.wrappedValue ?? false
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                // Every compact scene has the same size, so swapping one never moves the plaque. The
                // two layers share one frame: a new scene fades in where the old one fades out, in
                // the same view. (An `.id` swap would fade the old scene out where the tail used to
                // be while new parts push the tail down, a second mouse for a moment, #190.) Each
                // layer's opacity is a function of `layers.front`, animated towards it, so the front
                // scene always ends fully drawn: no sequenced phase can strand it at 0 (#194).
                ZStack {
                    ForEach(SceneLayers.Slot.allCases, id: \.self) { slot in
                        let isFront = slot == layers.front
                        PettableMouse(.working(layers[slot], label: shownWork.accessibilityLabel), scale: 2, isAnimating: isShown && isFront)
                            .opacity(layers.opacity(of: slot))
                            .animation(reduceMotion ? nil : Motion.fade, value: layers.front)
                            .allowsHitTesting(isFront)
                            .accessibilityHidden(!isFront)
                    }
                }
                if let shownPlaque {
                    HStack(spacing: Spacing.s) {
                        Text(shownPlaque)
                            .plaqueStyle(color: Palette.textSecondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        if details != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary.color)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .transition(.opacity)
                        }
                    }
                    // A taller hit target without changing the row's height.
                    .padding(.vertical, Spacing.s)
                    .contentShape(.rect)
                    .onTapGesture(perform: toggle)
                    .padding(.vertical, -Spacing.s)
                    .allowsHitTesting(details != nil)
                    .transition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(shownPlaque ?? ""))
            .accessibilityAddTraits(details != nil ? .isButton : [])
            // Paused on the user, it's static: VoiceOver shouldn't re-read it while they answer.
            .accessibilityAddTraits(shownWork.isPausedOnYou ? [] : .updatesFrequently)
            .accessibilityHint(details.map { isExpanded ? $0.hides : $0.shows } ?? "")
            .accessibilityAction { toggle() }
            // Without a plaque a card says what runs, and the mouse is decorative (#195).
            .accessibilityHidden(!isShown || shownPlaque == nil)
            .accessibilityIdentifier("response.waiting")
            if let details, isExpanded {
                details.content
                    .motionSafeTransition(.expand)
            }
        }
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        // In with a soft fade; out quickly, so the mouse doesn't linger over the first words.
        .motionSafeAnimation(isShown ? Motion.fade : .easeOut(duration: Motion.Duration.instant), value: isShown)
        .motionSafeAnimation(Motion.smooth, value: shownWork)
        .motionSafeAnimation(Motion.smooth, value: shownPlaque)
        .onChange(of: work, initial: true) { _, new in
            guard let new else { return }
            if new != shownWork { shownWork = new }
            if plaque != shownPlaque { shownPlaque = plaque }
            layers.show(new.scene)
        }
        .onChange(of: plaque) { _, new in
            if work != nil, new != shownPlaque { shownPlaque = new }
        }
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        guard let details else { return }
        withMotion(Motion.smooth) { details.isExpanded.wrappedValue.toggle() }
    }

    /// What VoiceOver reads: the plaque without its ellipsis.
    static func accessibilityLabel(_ plaque: String) -> String {
        plaque.hasSuffix("…") ? String(plaque.dropLast()) : plaque
    }
}

/// The tail's two scene layers (#194): both sit in the same frame, the front one shows the
/// latest scene at full opacity and the other is hidden. A new scene goes on the hidden layer and
/// becomes the front, so the swap is a cross-fade in place (no ghost where the tail used to be,
/// #190). Opacity follows from `front` alone, never from a sequence of phases, so no timing of
/// changes can leave the mouse hidden while there's work.
struct SceneLayers: Equatable {
    enum Slot: CaseIterable, Hashable {
        case a, b

        var other: Slot { self == .a ? .b : .a }
    }

    private(set) var front: Slot = .a
    private var a: WorkingMouse.Scene
    private var b: WorkingMouse.Scene

    init(_ scene: WorkingMouse.Scene) {
        a = scene
        b = scene
    }

    subscript(slot: Slot) -> WorkingMouse.Scene {
        slot == .a ? a : b
    }

    /// Brings `scene` to the front: nothing changes if it's already there; back to the scene
    /// that's fading out, it flips back.
    mutating func show(_ scene: WorkingMouse.Scene) {
        guard scene != self[front] else { return }
        let back = front.other
        if self[back] != scene {
            if back == .a { a = scene } else { b = scene }
        }
        front = back
    }

    func opacity(of slot: Slot) -> Double {
        slot == front ? 1 : 0
    }
}

/// Thinking above or between a Response's tool steps (CHAT-06), a quiet step row in the tool
/// rows' style: "Thinking" (with the tool rows' spinner) while it's the Response's live tail,
/// then "Thought for 4s ›" ("Thought ›" when the Server didn't time it); tap to read it.
///
/// It never shows a mouse (#190): the Response's one working mouse is the tail indicator, which
/// ponders with `THINKING…` while this part streams. A Thinking part that isn't the live tail is
/// finished (`ResponsePart.build`), so a long tool-heavy Response stacks quiet rows, not mice. The
/// row's height is the same live and finished, so finishing never reflows the transcript (#185).
struct ThinkingBlock: View {
    let text: String
    let summary: String
    let isStreaming: Bool
    let duration: TimeInterval?
    /// Shared with the live tail when the Response keeps it (#195); its own otherwise.
    private let sharedExpansion: Binding<Bool>?
    @State private var ownExpansion = false

    init(text: String, summary: String, isStreaming: Bool, duration: TimeInterval?, expanded: Binding<Bool>? = nil) {
        self.text = text
        self.summary = summary
        self.isStreaming = isStreaming
        self.duration = duration
        sharedExpansion = expanded
    }

    private var expanded: Bool {
        get { sharedExpansion?.wrappedValue ?? ownExpansion }
        nonmutating set {
            if let sharedExpansion { sharedExpansion.wrappedValue = newValue } else { ownExpansion = newValue }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button {
                withMotion(Motion.smooth) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.s) {
                    // One fixed slot, so the spinner settling into the icon never moves the title.
                    ZStack {
                        StepStatusIcon(isRunning: isStreaming, systemImage: "lightbulb")
                    }
                    .frame(width: Self.iconWidth)
                    Text(Self.title(isStreaming: isStreaming, duration: duration))
                        .font(Typography.callout)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Palette.textSecondary.color)
                .frame(minHeight: AccessibilityMetrics.minimumHitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityTitle(isStreaming: isStreaming, duration: duration))
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the model's reasoning" : "Shows the model's reasoning")
            .accessibilityIdentifier("response.thinking")

            if expanded {
                ThinkingDetails(text: text, summary: summary)
                    .motionSafeTransition(.expand)
            }
        }
        // "Thinking" settles into "Thought for 12s".
        .motionSafeAnimation(Motion.smooth, value: isStreaming)
    }

    /// Wide enough for the small spinner and the icon alike.
    static let iconWidth: CGFloat = 20

    /// The row's title: "Thinking" while it's the live tail, then "Thought for 12s", or
    /// "Thought" when the Server didn't time it (or it took under a second).
    static func title(isStreaming: Bool, duration: TimeInterval?) -> String {
        if isStreaming { return "Thinking" }
        if let duration, duration >= 1 { return "Thought for \(Int(duration.rounded()))s" }
        return "Thought"
    }

    /// What VoiceOver reads: "Thinking", "Thought for 12 seconds", "Thought".
    static func accessibilityTitle(isStreaming: Bool, duration: TimeInterval?) -> String {
        if isStreaming { return "Thinking" }
        if let duration, duration >= 1 {
            let seconds = Int(duration.rounded())
            return "Thought for \(seconds) second\(seconds == 1 ? "" : "s")"
        }
        return "Thought"
    }
}

/// A Thinking step's reasoning, under its row or under the live tail (#195).
struct ThinkingDetails: View {
    let text: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !summary.isEmpty {
                Text(summary).font(Typography.callout.italic())
            }
            Text(text)
                .font(.system(.callout, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .foregroundStyle(Palette.textSecondary.color)
        .padding(.leading, Spacing.m)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.separator.color).frame(width: 2)
        }
    }
}

/// One compact line for the model's tool steps; tap to see each step (CHAT-08).
public struct ToolActivityLine: View {
    let tools: [ToolActivity]
    /// Shared with the live tail when the Response keeps it (#195); its own otherwise.
    private let sharedExpansion: Binding<Bool>?
    private var disclosures = TranscriptDisclosureScope()

    public init(tools: [ToolActivity]) {
        self.tools = tools
        sharedExpansion = nil
    }

    init(tools: [ToolActivity], expanded: Binding<Bool>) {
        self.tools = tools
        sharedExpansion = expanded
    }

    private var expanded: Bool {
        get { sharedExpansion?.wrappedValue ?? disclosures.isOpen(ownKey) }
        nonmutating set {
            if let sharedExpansion { sharedExpansion.wrappedValue = newValue } else { disclosures.setOpen(ownKey, newValue) }
        }
    }

    /// Its own disclosure, kept by the transcript (#197).
    private var ownKey: String { "tools-\(tools.first?.id ?? "")" }

    private var running: ToolActivity? { tools.last(where: \.isRunning) }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button {
                withMotion(Motion.smooth) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.s) {
                    StepStatusIcon(isRunning: running != nil, systemImage: Self.icon(for: (running ?? tools.first)?.name ?? ""))
                    Text(summary)
                        .font(Typography.callout)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    if tools.count > 1 || tools.first?.detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .foregroundStyle(Palette.textSecondary.color)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("response.tools")

            if expanded {
                ToolStepDetails(tools: tools)
                    .motionSafeTransition(.expand)
            }
        }
        // The running step's spinner settles into its icon; the summary follows the steps.
        .motionSafeAnimation(Motion.smooth, value: running?.id)
    }

    private var summary: String {
        if let running { return running.title }
        guard let first = tools.first else { return "" }
        return tools.count == 1 ? first.title : "\(first.title) and \(tools.count - 1) more step\(tools.count == 2 ? "" : "s")"
    }

    static func icon(for name: String) -> String {
        switch name {
        case "search_web", "web_search": "globe"
        case "fetch_url": "doc.text"
        case "generate_image", "edit_image": "photo"
        case "execute_code", "run_code", "code_interpreter": "chevron.left.forwardslash.chevron.right"
        case "view_skill", "read_skill_file": "sparkles"
        case "delegate_task": "person.2"
        case let name where name.contains("memor"): "brain.head.profile"
        case let name where name.contains("knowledge"): "books.vertical"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Each tool step of a run, with its query or URL: under its row or under the live tail (#195).
struct ToolStepDetails: View {
    let tools: [ToolActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(tools) { tool in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: tool.failed ? "exclamationmark.triangle" : ToolActivityLine.icon(for: tool.name))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(tool.title).font(Typography.callout)
                        if let detail = tool.detail {
                            Text(detail)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textTertiary.color)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .foregroundStyle(Palette.textSecondary.color)
        .padding(.leading, Spacing.m)
    }
}

/// A server `status` line ("Searching the web"), collapsed to its result when done (CHAT-08).
struct StatusLine: View {
    let update: StatusUpdate
    let isLive: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            StepStatusIcon(isRunning: !update.isDone && isLive, systemImage: "checkmark.circle")
            Text(update.description)
                .font(Typography.callout)
                .lineLimit(1)
                .contentTransition(.interpolate)
        }
        .foregroundStyle(Palette.textSecondary.color)
        .motionSafeAnimation(Motion.smooth, value: update)
        .accessibilityIdentifier("response.status")
    }
}

/// A code-interpreter run (CONN-08): a compact header ("Running code", "Ran code") that expands
/// to the code, with the run's output underneath. Errors show in the destructive colour.
struct CodeExecutionView: View {
    let execution: CodeExecutionOutput
    let isLive: Bool
    /// Whether the code shows, kept by the transcript (#197).
    private var disclosures = TranscriptDisclosureScope()

    private var showsCode: Bool {
        get { disclosures.isOpen("code-\(execution.id ?? execution.code)") }
        nonmutating set { disclosures.setOpen("code-\(execution.id ?? execution.code)", newValue) }
    }

    private var isRunning: Bool { isLive && (execution.status?.isActive ?? !hasOutput) }
    private var hasOutput: Bool { !outputs.isEmpty }
    private var failed: Bool { !(execution.stderr ?? "").isEmpty && (execution.stdout ?? "").isEmpty && (execution.result ?? "").isEmpty }

    private var outputs: [(text: String, isError: Bool)] {
        [(execution.stdout, false), (execution.result, false), (execution.stderr, true)].compactMap { text, isError in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (text, isError)
        }
    }

    private var title: String {
        if isRunning { return "Running code" }
        return failed ? "Code ran with errors" : "Ran code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button {
                withMotion(Motion.smooth) { showsCode.toggle() }
            } label: {
                HStack(spacing: Spacing.s) {
                    StepStatusIcon(isRunning: isRunning, systemImage: failed ? "exclamationmark.triangle" : "chevron.left.forwardslash.chevron.right")
                    Text(title).font(Typography.callout)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsCode ? 90 : 0))
                }
                .foregroundStyle(Palette.textSecondary.color)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsCode ? "Hides the code" : "Shows the code")
            .accessibilityIdentifier("response.code")

            if showsCode, !execution.code.isEmpty {
                MarkdownView(blocks: [.code(language: "python", code: execution.code)])
                    .motionSafeTransition(.expand)
            }
            ForEach(Array(outputs.enumerated()), id: \.offset) { _, output in
                Text(output.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(output.isError ? Palette.destructive.color : Palette.textSecondary.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
                    .accessibilityIdentifier(output.isError ? "response.code.error" : "response.code.output")
                    .motionSafeTransition(.rise)
            }
        }
        // "Running code" → "Ran code" and the output landing under it.
        .motionSafeAnimation(Motion.smooth, value: isRunning)
    }
}

#Preview("Code execution") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        CodeExecutionView(
            execution: CodeExecutionOutput(id: "1", status: .completed, code: "print(sum(range(10)))", stdout: "45"),
            isLive: false
        )
        CodeExecutionView(
            execution: CodeExecutionOutput(id: "2", status: .completed, code: "import missing", stderr: "ModuleNotFoundError: No module named 'missing'"),
            isLive: false
        )
        CodeExecutionView(execution: CodeExecutionOutput(id: "3", status: .inProgress, code: "while True: pass"), isLive: true)
    }
    .padding()
}

/// Inline error with Retry (CHAT-13), compact: the mouse `peek`s beside the message (no
/// painting in the transcript, brand.md §4; the full-screen error is `LabyrinthErrorView`).
struct ResponseErrorView: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            PixelMouse(pose: .peek, scale: 2)
                .padding(.top, Spacing.xxs)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(message)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetry {
                    Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                        .font(Typography.callout.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("response.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(alignment: .leading) {
            // The one note of alarm: a destructive rule on the leading edge.
            UnevenRoundedRectangle(topLeadingRadius: Radius.medium, bottomLeadingRadius: Radius.medium)
                .fill(Palette.destructive.color)
                .frame(width: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("response.error")
    }
}

/// The Q/A summary of answered clarifying questions (CHAT-09).
struct AnsweredQuestionsCard: View {
    let answers: ClarifyingAnswers

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if answers.entries.isEmpty {
                Text(answers.wasCancelled ? "Questions skipped" : "Answered")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            ForEach(Array(answers.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(entry.question)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                    Text(entry.answer)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("response.answers")
    }
}

/// "Sources" pill under a Response: favicon-free host chips plus a count (CHAT-07).
struct SourcesButton: View {
    let citations: [Citation]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "books.vertical")
                Text(label)
                    .lineLimit(1)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary.color)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Palette.recessedSurface.color, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("response.sources")
    }

    private var label: String { Self.label(for: citations) }

    /// "caredge.com, kbb.com · 3 sources"; empty without citations (then there's no pill, #191).
    static func label(for citations: [Citation]) -> String {
        guard !citations.isEmpty else { return "" }
        let hosts = citations.compactMap(\.host)
        var unique: [String] = []
        for host in hosts where !unique.contains(host) { unique.append(host) }
        let names = unique.prefix(2).joined(separator: ", ")
        let count = "\(citations.count) source\(citations.count == 1 ? "" : "s")"
        return names.isEmpty ? count : "\(names) · \(count)"
    }
}

struct SourcesSheet: View {
    let citations: [Citation]
    let highlighted: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(citations) { citation in
                    Button {
                        if let link = citation.link { openURL(link) }
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.m) {
                            Text("\(citation.number)")
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.onAccent.color)
                                .frame(width: 22, height: 22)
                                .background(Palette.accent.color, in: .circle)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(citation.title)
                                    .font(Typography.headline)
                                    .foregroundStyle(Palette.textPrimary.color)
                                    .lineLimit(2)
                                if let host = citation.host {
                                    Text(host).font(Typography.caption).foregroundStyle(Palette.accent.color)
                                }
                                if !citation.snippet.isEmpty {
                                    Text(citation.snippet)
                                        .font(Typography.caption)
                                        .foregroundStyle(Palette.textSecondary.color)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    .disabled(citation.link == nil)
                    .listRowBackground(citation.number == highlighted ? Palette.accent.color.opacity(0.08) : Palette.surface.color)
                    .id(citation.number)
                }
                .scrollContentBackground(.hidden)
                .themedBackground()
                .onAppear {
                    if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
                }
            }
            .navigationTitle("Sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sources.sheet")
    }
}

@MainActor
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
