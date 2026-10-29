import ChatDomain
public import ChatFeature
import SwiftUI

/// The Artifacts Feature area's entry point (ART-01…03, ADR 0060). The host app puts
/// `transcriptExtensions` into the Chat screen's environment when the Account's Artifacts
/// Capability default (SET-05) is on:
///
/// ```swift
/// ConversationView(chatID: id)
///     .environment(\.transcriptExtensions, Artifacts.transcriptExtensions)
/// ```
public enum Artifacts {
    /// Artifact cards in place of qualifying code blocks and of imported `artifacts` tool steps,
    /// tool-embed cards after Responses, and the "N artifacts" pill under the Chat header.
    @MainActor
    public static var transcriptExtensions: TranscriptExtensions {
        TranscriptExtensions(
            id: "artifacts",
            codeBlock: { model, message, language, code in
                // Ordinary code (Swift, Python…) never pays for detection.
                guard ArtifactDetector.candidateKind(language: language) != nil else { return nil }
                return AnyView(ArtifactCodeBlock(model: model, messageID: message.id, language: language, code: code))
            },
            responseContent: { model, message in
                AnyView(ToolEmbedCards(model: model, messageID: message.id))
            },
            header: { model in
                AnyView(ArtifactsPill(model: model))
            },
            toolSteps: { model, message, steps in
                // Claude's `artifacts` calls in imported Chats become cards in place (#180).
                guard steps.contains(where: { $0.name == ToolActivity.artifactsName }) else { return nil }
                return AnyView(ImportedArtifactSteps(model: model, messageID: message.id, steps: steps))
            }
        )
    }
}
