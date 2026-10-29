import ChatDomain
import DesignSystem
import Entitlements
import GameController
import OpenWebUIKit
import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// Hooks the Voice epic plugs into the composer's mic (Dictation, VOICE-01) and voice-mode
/// (VOICE-03) buttons. Without them the buttons are placeholders that say what's coming.
public struct ComposerVoiceActions {
    public var dictate: (@MainActor (ComposerModel) -> Void)?
    public var startVoiceMode: (@MainActor () -> Void)?
    /// While Dictation records into this composer, the recording bar that replaces the text field
    /// and the button row (VOICE-01); `nil` otherwise.
    public var dictationBar: (@MainActor (ComposerModel) -> AnyView?)?

    public init(
        dictate: (@MainActor (ComposerModel) -> Void)? = nil,
        startVoiceMode: (@MainActor () -> Void)? = nil,
        dictationBar: (@MainActor (ComposerModel) -> AnyView?)? = nil
    ) {
        self.dictate = dictate
        self.startVoiceMode = startVoiceMode
        self.dictationBar = dictationBar
    }
}

extension EnvironmentValues {
    @Entry public var composerVoice = ComposerVoiceActions()
}

/// A notice docked on top of the composer card (HOME-04).
public struct ComposerNotice: Identifiable, Equatable {
    public let id: String
    public var text: String
    public var actionTitle: String?
    public var isDismissible: Bool
    public var tone: Tone

    public enum Tone: Equatable, Sendable {
        case neutral
        case warning
    }

    public init(id: String, text: String, actionTitle: String? = nil, isDismissible: Bool = true, tone: Tone = .neutral) {
        self.id = id
        self.text = text
        self.actionTitle = actionTitle
        self.isDismissible = isDismissible
        self.tone = tone
    }
}

/// The composer card (HOME-02): notices, Attachments, the growing text field, and the row with
/// `+` (Add to Chat), the model/Effort chip, the mic and the voice / send / stop button.
///
/// ```swift
/// ComposerView(model: composer, isNewChat: true, isStreaming: false, canSend: composer.isReady,
///              onSend: { … }, onStop: { … })
/// ```
public struct ComposerView: View {
    @Bindable var model: ComposerModel
    let isNewChat: Bool
    let isStreaming: Bool
    /// Whether sending is possible right now (content ready and the conversation can take it).
    let canSend: Bool
    let notices: [ComposerNotice]
    let onNoticeAction: (ComposerNotice) -> Void
    let onNoticeDismiss: (ComposerNotice) -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.composerVoice) private var voice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var sheet: Sheet?
    @State private var pendingPicker: Picker?
    @State private var picker: Picker?
    @State private var photoItems: [PhotosPickerItem] = []

    enum Sheet: Identifiable {
        case addToChat
        case modelPicker
        var id: Self { self }
    }

    enum Picker: Identifiable {
        case photos
        case files
        case camera
        var id: Self { self }
    }

    public init(
        model: ComposerModel,
        isNewChat: Bool,
        isStreaming: Bool,
        canSend: Bool,
        notices: [ComposerNotice] = [],
        onNoticeAction: @escaping (ComposerNotice) -> Void = { _ in },
        onNoticeDismiss: @escaping (ComposerNotice) -> Void = { _ in },
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.model = model
        self.isNewChat = isNewChat
        self.isStreaming = isStreaming
        self.canSend = canSend
        self.notices = notices
        self.onNoticeAction = onNoticeAction
        self.onNoticeDismiss = onNoticeDismiss
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(allNotices) { notice in
                NoticeCard(notice: notice) {
                    if notice.id == Self.composerNoticeID {
                        model.notice = nil
                    } else if notice.id == Self.sandboxNoticeID {
                        model.isSandboxNoticeDismissed = true
                    } else {
                        onNoticeDismiss(notice)
                    }
                } action: {
                    if notice.id == ComposerNotice.unavailableModelID {
                        sheet = .modelPicker
                    } else if notice.id == Self.sandboxNoticeID {
                        model.paywallRequest = PaywallRequest(.sandbox)
                    }
                    onNoticeAction(notice)
                }
                .transition(.motionSafe(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
                .padding(.horizontal, 4)
            }
            if !model.attachments.isEmpty {
                ComposerAttachmentStrip(model: model)
                    .padding(.horizontal, 4)
                    .motionSafeTransition(.rise)
            }
            // #140: picked Skills, and the `/` menu while a Skill name is typed.
            if !model.selectedSkills.isEmpty {
                SelectedSkillChips(model: model)
            }
            SlashSkillMenu(model: model)
            if let dictationBar = voice.dictationBar?(model) {
                dictationBar
                    .motionSafeTransition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                TextField(model.placeholder(isNewChat: isNewChat), text: $model.text, axis: .vertical)
                    .font(Typography.body)
                    .lineLimit(1...10)
                    .focused($focused)
                    .submitLabel(.return)
                    // PLAT-05: Return on a hardware keyboard sends, ⇧Return types a new line.
                    .onChange(of: model.text) { old, new in handleTypedReturn(old: old, new: new) }
                    // "Ask about it ›" on the home fills the draft and hands over the keyboard.
                    .onChange(of: model.focusRequest) { focused = true }
                    .padding(.horizontal, Spacing.xs + 4)
                    .accessibilityIdentifier("composer.field")
                // The 44 pt hit targets keep the circles about as far apart as before.
                HStack(spacing: Spacing.xxs) {
                    plusButton
                    ModelChip(model: model, isDisabled: isStreaming) { sheet = .modelPicker }
                        // PLAT-02: a selection tick when the user picks another model (not when it first loads).
                        .hapticCue(trigger: model.selectedModelID) { old, new in old != nil && new != old ? .selection : nil }
                    Spacer(minLength: 0)
                    micButton
                    trailingButton
                }
                // Voice ↔ send ↔ stop morph in place (Visual language: Motion & haptics cues).
                .motionSafeAnimation(Motion.snappy, value: trailingKind)
                // PLAT-06: the fixed-size button row stops growing at the first accessibility
                // size; the text field above keeps scaling.
                .chromeDynamicType()
            }
        }
        .padding(.horizontal, Spacing.m - 4)
        .padding(.top, Spacing.l)
        // The buttons' 44 pt hit targets add 4 pt around their circles.
        .padding(.bottom, Spacing.m - 4)
        .background(Palette.surface.color, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.separator.color.opacity(0.6)))
        // The card grows and shrinks with its text (up to ten lines), notices and Attachments.
        .motionSafeAnimation(Motion.snappy, value: model.text)
        .motionSafeAnimation(Motion.smooth, value: allNotices)
        .motionSafeAnimation(Motion.smooth, value: model.attachments)
        .motionSafeAnimation(Motion.snappy, value: model.selectedSkillIDs)
        .motionSafeAnimation(Motion.snappy, value: model.slashQuery)
        .motionSafeAnimation(Motion.smooth, value: voice.dictationBar?(model) != nil)
        // PLAT-02: a rejected Attachment or other composer notice asks for attention.
        .hapticCue(trigger: model.notice) { _, new in new == nil ? nil : .warning }
        // PLAT-01/03: a widget's camera or mic, a Shortcut's Voice mode.
        .onChange(of: LaunchKey(action: model.launchAction, isReady: model.selectedModel != nil), initial: true) {
            performLaunchAction()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer")
        // ADR 0173: Skills from the `/` menu, Voice mode and the sandbox notice.
        .paywall($model.paywallRequest)
        .sheet(item: $sheet, onDismiss: presentPendingPicker) { sheet in
            switch sheet {
            case .addToChat:
                AddToChatSheet(model: model) { picker in
                    pendingPicker = picker
                    self.sheet = nil
                }
            case .modelPicker:
                ModelPickerSheet(model: model)
            }
        }
        .photosPicker(
            isPresented: Binding(get: { picker == .photos }, set: { if !$0 { picker = nil } }),
            selection: $photoItems,
            maxSelectionCount: model.remainingSlots ?? 10,
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await attachPhotos(items) }
        }
        .fileImporter(
            isPresented: Binding(get: { picker == .files }, set: { if !$0 { picker = nil } }),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { attachFiles(urls) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(get: { picker == .camera }, set: { if !$0 { picker = nil } })) {
            CameraPicker { data in
                picker = nil
                if let data {
                    model.attach([PendingAttachment(data: data, filename: CameraPicker.filename(), contentType: "image/jpeg", source: .camera)])
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    static let composerNoticeID = "composer.notice"
    /// ADR 0173: today's free code execution runs (sandbox or code interpreter) are used up.
    static let sandboxNoticeID = "pro.sandbox"

    private var allNotices: [ComposerNotice] {
        var all = notices
        if model.sandboxAllowanceExhausted, !model.isSandboxNoticeDismissed {
            all.append(ComposerNotice(
                id: Self.sandboxNoticeID,
                text: "You've used today's \(model.services.pro.allowance.limit) free code execution runs. They're back tomorrow, or unlimited with Theseus Pro.",
                actionTitle: "Unlock Theseus Pro"
            ))
        }
        if let issue = model.blockingIssue {
            all.append(ComposerNotice(id: "composer.blocking", text: issue, isDismissible: false, tone: .warning))
        }
        if let notice = model.notice {
            all.append(ComposerNotice(id: Self.composerNoticeID, text: notice))
        }
        return all
    }

    private var plusButton: some View {
        Button {
            focused = false
            sheet = .addToChat
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.textPrimary.color)
                .frame(width: 36, height: 36)
                .background(Palette.recessedSurface.color, in: .circle)
                .minimumHitTarget()  // PLAT-06: a 44 pt target around the 36 pt circle
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .accessibilityLabel("Add to chat")
        .accessibilityIdentifier("composer.add")
    }

    @ViewBuilder
    private var micButton: some View {
        if model.capabilities.contains(.dictation), !isStreaming {
            Button {
                if let dictate = voice.dictate {
                    focused = false
                    dictate(model)
                } else {
                    model.notice = "Dictation is coming to Theseus soon."
                }
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 36, height: 36)
                    .background(Palette.recessedSurface.color, in: .circle)
                    .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .pointerHighlight()
            .accessibilityLabel("Dictate")
            .accessibilityIdentifier("composer.mic")
        }
    }

    /// Which trailing button shows; the row animates when it changes.
    private var trailingKind: Int {
        if isStreaming { return 0 }
        if !model.hasContent, model.capabilities.contains(.voiceMode) { return 1 }
        return model.isUploading ? 3 : 2
    }

    /// Voice mode when empty, an accent send arrow with content, stop while streaming.
    @ViewBuilder
    private var trailingButton: some View {
        if isStreaming {
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.background.color)
                    .frame(width: 12, height: 12)
                    .frame(width: 36, height: 36)
                    .background(Palette.textPrimary.color, in: .circle)
                    .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .pointerHighlight()
            .accessibilityLabel("Stop response")
            .accessibilityIdentifier("composer.stop")
            .transition(.pop)
        } else if !model.hasContent, model.capabilities.contains(.voiceMode) {
            Button {
                if let startVoiceMode = voice.startVoiceMode {
                    focused = false
                    model.startVoiceMode(startVoiceMode)
                } else {
                    model.notice = "Voice mode is coming to Theseus soon."
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.background.color)
                    .frame(width: 36, height: 36)
                    .background(Palette.textPrimary.color, in: .circle)
                    .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .pointerHighlight()
            .accessibilityLabel("Start voice mode")
            .accessibilityIdentifier("composer.voice")
            .transition(.pop)
        } else {
            Button {
                focused = false
                onSend()
            } label: {
                Group {
                    if model.isUploading {
                        ProgressView().tint(Palette.textTertiary.color)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    }
                }
                // Verdigris when it can send; recessed stone while it can't (brand.md §1).
                .foregroundStyle(canSend ? Palette.onAccent.color : Palette.textTertiary.color)
                .frame(width: 36, height: 36)
                .background(canSend ? Palette.accent.color : Palette.recessedSurface.color, in: .circle)
                .motionSafeAnimation(Motion.snappy, value: canSend)
                .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .pointerHighlight()
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("composer.send")
            .transition(.pop)
        }
    }

    private struct LaunchKey: Equatable {
        let action: ComposerLaunchAction?
        let isReady: Bool
    }

    /// Carries out `model.launchAction` once the model (and so its Capabilities) is known.
    private func performLaunchAction() {
        guard let action = model.launchAction, model.selectedModel != nil else { return }
        model.launchAction = nil
        switch model.launchOutcome(action, cameraAvailable: CameraPicker.isAvailable) {
        case .camera: picker = .camera
        case .photos: picker = .photos
        case .dictation:
            if let dictate = voice.dictate {
                focused = false
                dictate(model)
            } else {
                model.notice = "Dictation is coming to Theseus soon."
            }
        case .voiceMode:
            if let startVoiceMode = voice.startVoiceMode {
                model.startVoiceMode(startVoiceMode)
            } else {
                model.notice = "Voice mode is coming to Theseus soon."
            }
        case .notice(let text):
            model.notice = text
        }
    }

    /// A hardware keyboard's plain Return: take the line break out again and send (PLAT-05).
    private func handleTypedReturn(old: String, new: String) {
        guard let text = ComposerReturnKey.textBeforeTypedReturn(old: old, new: new),
              ComposerReturnKey.sends(hardwareKeyboard: HardwareKeyboard.isAttached, shift: HardwareKeyboard.isShiftHeld)
        else { return }
        model.text = text
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
        if hasContent, canSend, !isStreaming { onSend() }
    }

    private func presentPendingPicker() {
        guard let next = pendingPicker else { return }
        pendingPicker = nil
        picker = next
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        var pending: [PendingAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.notice = "A photo couldn't be loaded."
                continue
            }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
            let ext = type?.preferredFilenameExtension ?? "jpg"
            pending.append(PendingAttachment(
                data: data,
                filename: "Photo \(index + 1).\(ext)",
                contentType: type?.preferredMIMEType,
                source: .photos
            ))
        }
        model.attach(pending)
    }

    private func attachFiles(_ urls: [URL]) {
        var pending: [PendingAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.notice = "\(url.lastPathComponent) couldn't be read."
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            pending.append(PendingAttachment(data: data, filename: url.lastPathComponent, contentType: type?.preferredMIMEType, source: .files))
        }
        model.attach(pending)
    }
}

extension ComposerNotice {
    /// The id of the "model no longer available" notice; its action opens the picker.
    public static let unavailableModelID = "composer.unavailableModel"
}

/// The model + Effort pill, a plaque ("OPUS 5.5 LOW ▾", brand.md §2); opens Select model
/// (MODEL-01). VoiceOver reads the name as written ("Opus 5.5, Low").
struct ModelChip: View {
    let model: ComposerModel
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs + 2) {
                Text(model.chipTitle)
                    .plaqueStyle(12, relativeTo: .callout, color: Palette.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                if let detail = model.chipDetail {
                    Text(detail)
                        .plaqueStyle(12, relativeTo: .callout, color: Palette.textTertiary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                        .transition(.opacity)
                }
                Text(verbatim: "▾")
                    .plaqueStyle(12, relativeTo: .callout, color: Palette.textPrimary)
                    .accessibilityHidden(true)
            }
            // MODEL-01/02: a new model or Effort morphs the chip's text and width.
            .motionSafeAnimation(Motion.snappy, value: [model.chipTitle, model.chipDetail ?? ""])
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 36)
            .background(Palette.recessedSurface.color, in: .capsule)
            .frame(minHeight: AccessibilityMetrics.minimumHitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerHighlight()
        .disabled(isDisabled)
        .accessibilityLabel(model.chipDetail.map { "\(model.chipTitle), \($0)" } ?? model.chipTitle)
        .accessibilityHint("Choose a model")
        .accessibilityIdentifier("composer.model")
    }
}

/// One notice card on top of the composer (HOME-04).
struct NoticeCard: View {
    let notice: ComposerNotice
    let dismiss: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                if notice.tone == .warning {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Palette.accent.color)
                }
                Text(LocalizedStringKey(notice.text))
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                if notice.isDismissible {
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                            .minimumHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("composer.notice.dismiss")
                }
            }
            if let actionTitle = notice.actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typography.callout.weight(.medium))
                        .foregroundStyle(Palette.textPrimary.color)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(Capsule().stroke(Palette.separator.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.notice.action")
            }
        }
        .padding(Spacing.m)
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium + 4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.notice")
    }
}

/// The hardware keyboard's state (iPad with a keyboard, Mac), from GameController.
@MainActor
enum HardwareKeyboard {
    static var isAttached: Bool { GCKeyboard.coalesced != nil }

    static var isShiftHeld: Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        return input.button(forKeyCode: .leftShift)?.isPressed == true || input.button(forKeyCode: .rightShift)?.isPressed == true
    }
}
