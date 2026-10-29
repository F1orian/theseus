@testable import ChatFeature
import ChatDomain
import DesignSystem
import Testing

@Suite("Conversation haptic cues (PLAT-02)")
struct ConversationHapticsTests {
    typealias State = ConversationHaptics.State

    @Test func startingAResponseIsASend() {
        let idle = State()
        let sending = State(streamingMessageID: "a1", lastPhase: .waiting)
        #expect(ConversationHaptics.cue(from: idle, to: sending) == .send)
    }

    @Test(arguments: [
        (ResponseState.Phase.completed, HapticCue?.some(.responseDone)),
        (.stopped, .stop),
        (.failed, .error),
        (.awaitingAnswer, nil),
    ])
    func endingAResponseSaysHowItEnded(phase: ResponseState.Phase, cue: HapticCue?) {
        let streaming = State(streamingMessageID: "a1", lastPhase: .streaming)
        let ended = State(streamingMessageID: nil, lastPhase: phase)
        #expect(ConversationHaptics.cue(from: streaming, to: ended) == cue)
    }

    @Test func streamingTokensStayQuiet() {
        let first = State(streamingMessageID: "a1", lastPhase: .waiting)
        let second = State(streamingMessageID: "a1", lastPhase: .streaming)
        #expect(ConversationHaptics.cue(from: first, to: second) == nil)
    }

    @Test func openingAChatThatFailsToLoadIsAnError() {
        #expect(ConversationHaptics.cue(from: State(), to: State(loadFailed: true)) == .error)
        #expect(ConversationHaptics.cue(from: State(loadFailed: true), to: State(loadFailed: true)) == nil)
    }

    @Test func aNewNoticeIsAWarningButClearingItIsSilent() {
        #expect(ConversationHaptics.cue(from: State(), to: State(notice: "Couldn't stop")) == .warning)
        #expect(ConversationHaptics.cue(from: State(notice: "Couldn't stop"), to: State()) == nil)
    }

    @Test func aFailedResponseWinsOverItsNotice() {
        let streaming = State(streamingMessageID: "a1", lastPhase: .streaming)
        let failed = State(lastPhase: .failed, notice: "Network lost")
        #expect(ConversationHaptics.cue(from: streaming, to: failed) == .error)
    }
}
