public import ChatDomain
public import ChatFeature
public import ComposerFeature
public import Entitlements
public import OpenWebUIKit
import SwiftUI

/// The Open Terminal Feature area's entry point (epic #139, ADR 0120): code execution and file
/// creation in the Server's sandbox. One per signed-in Account. The host app merges
/// `transcriptExtensions` into the Chat screen's environment:
///
/// ```swift
/// ConversationView(chatID: id)
///     .environment(\.transcriptExtensions, artifacts.merged(with: sandbox.transcriptExtensions(images: images)))
/// ```
@MainActor
public final class Sandbox {
    /// Downloads of sandbox files and files on Responses.
    public let files: SandboxFiles
    private let client: OpenWebUIClient
    private let accountKey: String
    /// Theseus Pro (ADR 0173): free code execution runs get a footer with the day's allowance.
    private let pro: ProStore

    public init(client: OpenWebUIClient, accountKey: String, pro: ProStore = .unlocked()) {
        self.client = client
        self.accountKey = accountKey
        self.pro = pro
        files = SandboxFiles(client: client, accountKey: accountKey)
    }

    /// Whether `response` ran anything in the sandbox (a terminal tool call), which is what counts
    /// against the free allowance (ADR 0173).
    public nonisolated static func usedSandbox(_ response: ResponseState) -> Bool {
        response.parts.contains { part in
            guard case .tools(_, let tools) = part else { return false }
            return tools.contains { TerminalTool(rawValue: $0.name) != nil }
        }
    }

    /// Whether `response` ran code: in the sandbox, or through the Server's code interpreter
    /// (Jupyter). Either is one code execution run against the free allowance (ADR 0173).
    public nonisolated static func ranCode(_ response: ResponseState) -> Bool {
        usedSandbox(response) || response.ranCodeInterpreter
    }

    /// Counts a finished Response that was sent with code execution against `pro`'s free runs,
    /// once, when it really ran code (`ranCode`). Messages that only had the switch on don't count.
    public static func recordRun(of response: ResponseState, in pro: ProStore) {
        if ranCode(response) { pro.recordSandboxUse() }
    }

    /// The file browser for a Chat's session on `terminalID` (OT-04).
    public func browser(terminalID: String, chatID: String) -> SandboxBrowserModel {
        SandboxBrowserModel(client: client, terminalID: terminalID, chatID: chatID, files: files, accountKey: accountKey)
    }

    /// The terminal a Chat's sandbox runs on: the model's when it names one of `terminals`, else
    /// the first one the Account may use.
    public static func terminalID(for model: Model?, among terminals: [TerminalServer]) -> String? {
        if let id = model?.terminalID, terminals.contains(where: { $0.id == id }) { return id }
        return terminals.first?.id
    }

    /// Run cards, file lines and file cards in place of the generic step line (OT-02, OT-03),
    /// and the files the Server attached after each Response's content.
    public func transcriptExtensions(images: AttachmentImageCache) -> TranscriptExtensions {
        let files = files
        let pro = pro
        return TranscriptExtensions(
            id: "sandbox",
            responseContent: { model, message in
                let response = model.response(for: message)
                let attached = response.files
                // ADR 0173: the latest Response that ran code (sandbox or code interpreter) shows
                // the free allowance.
                let showsAllowance = !pro.isPro && message.id == model.thread.last?.id
                    && response.isFinished && Self.ranCode(response)
                guard !attached.isEmpty || showsAllowance else { return AnyView(EmptyView()) }
                return AnyView(VStack(alignment: .leading, spacing: 8) {
                    if !attached.isEmpty {
                        ResponseFilesView(attachments: attached, files: files, images: images)
                    }
                    if showsAllowance {
                        FreeSandboxRunFooter(allowance: pro.allowance)
                    }
                })
            },
            toolSteps: { model, message, steps in
                guard steps.contains(where: { TerminalTool(rawValue: $0.name) != nil }) else { return nil }
                // Later calls (status polls) fold into earlier runs, so the whole Response counts.
                let all = model.response(for: message).parts.flatMap { part -> [ToolActivity] in
                    if case .tools(_, let tools) = part { return tools }
                    return []
                }
                return AnyView(SandboxToolSteps(steps: steps, log: SandboxLog(all), chatID: model.chatID, files: files))
            }
        )
    }

    /// Forgets this Account's downloads (sign-out, Account removed).
    public func tearDown() {
        files.removeAll()
    }
}
