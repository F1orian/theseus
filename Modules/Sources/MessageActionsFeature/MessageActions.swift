public import ChatDomain
public import ChatFeature
import DesignSystem
public import Foundation
public import Observation
public import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Message actions of one signed-in Account (MSG-01…08): copy with its toast, retry, the
/// Branch pager, edit, feedback, read aloud and Chat links. The app shell creates one per
/// Account, plugs it into the transcript with `accessories`, and applies `.messageActions(_:)`
/// to present its sheets and toasts.
@MainActor
@Observable
public final class MessageActions {
    /// A top toast ("Message copied") with a close button (Visual language).
    public struct Toast: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
        public let systemImage: String
    }

    /// The thumb a user picked, waiting for the Feedback sheet's submit.
    public struct FeedbackDraft: Identifiable {
        public var id: String { messageID }
        public let messageID: String
        public let rating: MessageAnnotation.Rating
        public let comment: String
        /// Opened from Report (ADR 0172): starts with "Report as harmful or offensive" on.
        public var isReport = false
        let conversation: ConversationModel
    }

    /// A sent user Message being edited (MSG-05).
    public struct EditDraft: Identifiable {
        public var id: String { messageID }
        public let messageID: String
        public let text: String
        let conversation: ConversationModel
    }

    /// A whole Message in the Select text sheet (#175).
    public struct SelectTextDraft: Identifiable, Sendable {
        public var id: String { messageID }
        public let messageID: String
        public let text: String
        /// A Response's markdown (rendered), rather than a user Message's plain text.
        public let isMarkdown: Bool
    }

    public enum Sheet: Identifiable {
        case feedback(FeedbackDraft)
        case share(ChatLinkSharing)
        case edit(EditDraft)
        case selectText(SelectTextDraft)

        public var id: String {
            switch self {
            case .feedback(let draft): "feedback.\(draft.id)"
            case .share(let sharing): "share.\(sharing.chatID)"
            case .edit(let draft): "edit.\(draft.id)"
            case .selectText(let draft): "selectText.\(draft.id)"
            }
        }
    }

    public private(set) var toast: Toast?
    /// The Message whose copy icon shows a checkmark right now (MSG-02).
    public private(set) var copiedMessageID: String?
    public var sheet: Sheet?
    public let readAloud: ReadAloudController
    /// The on-device voice for read aloud, once Voice settings (VOICE-06) let the user pick one.
    @ObservationIgnored public var onDeviceVoiceIdentifier: @MainActor () -> String? = { nil }
    /// How long the copy checkmark and toasts stay.
    @ObservationIgnored var confirmationDuration: Duration = .seconds(2)

    @ObservationIgnored let client: OpenWebUIClient
    @ObservationIgnored private let feedback: FeedbackService
    @ObservationIgnored private var copyReset: Task<Void, Never>?
    @ObservationIgnored private var toastReset: Task<Void, Never>?
    @ObservationIgnored private let copyText: @MainActor (String) -> Void

    public convenience init(client: OpenWebUIClient) {
        let speech = LiveSpeech(client: client)
        self.init(
            client: client,
            readAloud: ReadAloudController(makeOutput: { await speech.makeOutput() }),
            copyText: MessageActions.copyToPasteboard
        )
        speech.voiceIdentifier = { [weak self] in self?.onDeviceVoiceIdentifier() }
    }

    init(client: OpenWebUIClient, readAloud: ReadAloudController, copyText: @escaping @MainActor (String) -> Void) {
        self.client = client
        self.readAloud = readAloud
        self.copyText = copyText
        feedback = FeedbackService(client: client)
    }

    // MARK: Copy (MSG-02)

    /// Puts `text` on the clipboard, flips the Message's copy icon to a checkmark and shows a toast.
    public func copy(_ text: String, messageID: String) {
        copyText(text)
        copiedMessageID = messageID
        copyReset?.cancel()
        let duration = confirmationDuration
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.copiedMessageID = nil
        }
        show(Toast(text: "Message copied", systemImage: "doc.on.clipboard"))
    }

    public func show(_ toast: Toast) {
        self.toast = toast
        toastReset?.cancel()
        let duration = confirmationDuration + .milliseconds(500)
        toastReset = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    public func showToast(_ text: String, systemImage: String = "exclamationmark.circle") {
        show(Toast(text: text, systemImage: systemImage))
    }

    public func dismissToast() {
        toast = nil
    }

    // MARK: Feedback (MSG-06)

    /// Opens the Feedback sheet for a thumb on `message`.
    public func rate(_ message: Message, _ rating: MessageAnnotation.Rating, in conversation: ConversationModel) {
        let comment = message.annotation?.rating == rating ? message.annotation?.comment ?? "" : ""
        sheet = .feedback(FeedbackDraft(messageID: message.id, rating: rating, comment: comment, conversation: conversation))
    }

    /// Report (App Review 1.2, ADR 0172). On a saved Chat whose Account may rate Responses, the
    /// thumbs-down sheet opens with Report on, so the report lands in the Server's Evaluations for
    /// its admins. Otherwise (Incognito, rating turned off) returns an email to the Server's admin
    /// with the Response, or to Theseus support when the Server publishes no admin contact.
    public func report(_ message: Message, text: String, in conversation: ConversationModel) async -> URL? {
        if conversation.chatID != nil, conversation.capabilities.contains(.rateResponse) {
            sheet = .feedback(FeedbackDraft(messageID: message.id, rating: .bad, comment: "", isReport: true, conversation: conversation))
            return nil
        }
        let contact = try? await client.send(.adminContact)
        return Self.reportMail(to: contact?.email, host: client.server.host() ?? "this server", model: message.modelID, text: text)
    }

    /// A report by email: the Response quoted, so the recipient sees what was reported.
    static func reportMail(to adminEmail: String?, host: String, model: String?, text: String) -> URL? {
        let recipient = adminEmail.flatMap { $0.isEmpty ? nil : $0 } ?? PublicLinks.supportEmail
        let excerpt = text.count > 1500 ? String(text.prefix(1500)) + "…" : text
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Reported response on \(host)"),
            URLQueryItem(
                name: "body",
                value: "I'm reporting this response as harmful or offensive.\n\nServer: \(host)\nModel: \(model ?? "unknown")\n\n---\n\(excerpt)\n---\n\nWhy: "
            ),
        ]
        return components.url
    }

    /// Sends the feedback; the thumb fills once the Server has it. Returns whether it worked.
    @discardableResult
    public func submit(_ draft: FeedbackDraft, comment: String, isReport: Bool = false) async -> Bool {
        let conversation = draft.conversation
        guard let chatID = conversation.chatID, let message = conversation.message(id: draft.messageID) else { return false }
        let rating = FeedbackService.Rating(
            chatID: chatID,
            messageID: message.id,
            rating: draft.rating,
            comment: comment,
            modelID: message.modelID,
            siblingModelIDs: conversation.siblingModelIDs(of: message.id),
            feedbackID: message.annotation?.feedbackID,
            isReport: isReport && draft.rating == .bad
        )
        do {
            let annotation = try await feedback.submit(rating)
            conversation.setAnnotation(annotation, for: message.id)
            show(isReport && draft.rating == .bad
                ? Toast(text: "Reported to the server's admins", systemImage: "flag")
                : Toast(text: "Thanks for your feedback", systemImage: "checkmark.bubble"))
            return true
        } catch {
            showToast("Couldn't send your feedback. \(error.message)")
            return false
        }
    }

    // MARK: Share (MSG-08)

    /// Opens the Share sheet for a Chat (from the action row or the Chat menu).
    public func share(chatID: String, title: String) {
        sheet = .share(ChatLinkSharing(chatID: chatID, title: title, client: client))
    }

    // MARK: Edit (MSG-05)

    public func edit(_ message: Message, in conversation: ConversationModel) {
        sheet = .edit(EditDraft(messageID: message.id, text: message.content, conversation: conversation))
    }

    public func send(_ draft: EditDraft, text: String) async {
        await draft.conversation.edit(draft.messageID, to: text)
    }

    // MARK: Select text (#175)

    /// Opens the whole Message as one selectable text, so any range can be copied: a Response's
    /// `text` is markdown, a user Message's is plain.
    public func selectText(_ message: Message, text: String) {
        sheet = .selectText(SelectTextDraft(messageID: message.id, text: text, isMarkdown: message.role == .assistant))
    }

    // MARK: Read aloud (MSG-07)

    public func toggleReadAloud(_ message: Message, text: String) {
        readAloud.toggle(messageID: message.id, markdown: text)
    }

    private static func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
