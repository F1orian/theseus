public import ChatDomain
public import SwiftUI

/// Content another Feature area adds to the transcript, provided by the host app (ADR 0009). The
/// Artifacts area (`ArtifactsFeature`, ADR 0060) fills these with Artifact cards, tool-embed cards
/// and the "N artifacts" pill; without them Responses render as plain markdown.
public struct TranscriptExtensions {
    /// Identifies what the hooks decide. Change it when their output could change for the same
    /// input (e.g. a setting was switched), so rendered code blocks are re-asked.
    public var id: String
    /// In place of a fenced code block of an assistant Response; `nil` keeps the code block.
    public var codeBlock: (@MainActor (ConversationModel, Message, _ language: String?, _ code: String) -> AnyView?)?
    /// After an assistant Response's own content, before its accessories (e.g. tool embeds).
    public var responseContent: (@MainActor (ConversationModel, Message) -> AnyView)?
    /// Floating under the Chat header (e.g. the "N artifacts" pill, ART-01).
    public var header: (@MainActor (ConversationModel) -> AnyView)?
    /// In place of a Response's tool steps line (CHAT-08), given one run of consecutive steps;
    /// `nil` keeps the line. The sandbox (`SandboxFeature`, ADR 0120) renders its runs and files.
    public var toolSteps: (@MainActor (ConversationModel, Message, _ steps: [ToolActivity]) -> AnyView?)?

    public init(
        id: String = "",
        codeBlock: (@MainActor (ConversationModel, Message, _ language: String?, _ code: String) -> AnyView?)? = nil,
        responseContent: (@MainActor (ConversationModel, Message) -> AnyView)? = nil,
        header: (@MainActor (ConversationModel) -> AnyView)? = nil,
        toolSteps: (@MainActor (ConversationModel, Message, _ steps: [ToolActivity]) -> AnyView?)? = nil
    ) {
        self.id = id
        self.codeBlock = codeBlock
        self.responseContent = responseContent
        self.header = header
        self.toolSteps = toolSteps
    }

    /// Both areas' hooks: `self` first. Code blocks and tool steps go to the first hook that takes
    /// them; Response content and headers stack.
    public func merged(with other: TranscriptExtensions) -> TranscriptExtensions {
        func first<each A, R>(
            _ lhs: (@MainActor (repeat each A) -> R?)?,
            _ rhs: (@MainActor (repeat each A) -> R?)?
        ) -> (@MainActor (repeat each A) -> R?)? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return { (args: repeat each A) in lhs(repeat each args) ?? rhs(repeat each args) }
        }
        func stacked<each A>(
            _ lhs: (@MainActor (repeat each A) -> AnyView)?,
            _ rhs: (@MainActor (repeat each A) -> AnyView)?
        ) -> (@MainActor (repeat each A) -> AnyView)? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return { (args: repeat each A) in
                AnyView(VStack(alignment: .leading, spacing: 12) {
                    lhs(repeat each args)
                    rhs(repeat each args)
                })
            }
        }
        return TranscriptExtensions(
            id: [id, other.id].filter { !$0.isEmpty }.joined(separator: "+"),
            codeBlock: first(codeBlock, other.codeBlock),
            responseContent: stacked(responseContent, other.responseContent),
            header: stacked(header, other.header),
            toolSteps: first(toolSteps, other.toolSteps)
        )
    }
}

extension EnvironmentValues {
    @Entry public var transcriptExtensions = TranscriptExtensions()
}
