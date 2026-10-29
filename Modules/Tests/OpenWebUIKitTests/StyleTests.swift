import ChatDomain
import Foundation
@testable import OpenWebUIKit
import Testing

private func json(_ data: Data?) throws -> JSONValue {
    try WireCoding.decoder.decode(JSONValue.self, from: try #require(data))
}

@Suite("Styles: settings and the system prompt (PERS-05)")
struct StyleTests {
    private func request(instructions: String?, style: String?) -> CompletionRequest {
        CompletionRequest(
            chatID: "c1", modelID: "m", prompt: "hi", parentMessageID: "a0",
            personalization: ChatPersonalization(instructions: instructions, preferredName: "Ada", usesMemory: false, styleInstructions: style)
        )
    }

    @Test func theStyleFollowsProfileInstructionsInTheSystemMessage() throws {
        let body = try json(CompletionSession.socketBody(request(instructions: "Call me Ada.", style: "Be concise."), sessionID: "sid"))
        #expect(body[path: "messages"]?.arrayValue?.count == 1)
        #expect(body[path: "messages"]?.arrayValue?.first?[path: "role"]?.stringValue == "system")
        #expect(body[path: "messages"]?.arrayValue?.first?[path: "content"]?.stringValue == "Call me Ada.\n\nBe concise.")
        // The Chat's system prompt, as the web client sends it next to the system message.
        #expect(body[path: "params.system"]?.stringValue == "Call me Ada.\n\nBe concise.")
    }

    @Test func aStyleAloneIsTheSystemPrompt() throws {
        let body = try json(CompletionSession.sseBody(request(instructions: nil, style: "Be formal.")))
        #expect(body[path: "messages"]?.arrayValue?.first?[path: "content"]?.stringValue == "Be formal.")
        #expect(body[path: "params.system"]?.stringValue == "Be formal.")
    }

    @Test func withoutAStyleNothingChanges() throws {
        let body = try json(CompletionSession.socketBody(request(instructions: "Call me Ada.", style: "  "), sessionID: "sid"))
        #expect(body[path: "messages"]?.arrayValue?.first?[path: "content"]?.stringValue == "Call me Ada.")
        #expect(body[path: "params.system"] == nil, "Instructions alone go out as before")
    }

    @Test func stylesDecodeFromTheTheseusNamespace() {
        let settings = UserSettings(raw: [
            "theseus": .object([
                "styles": .object([
                    "selected": .string("custom-1"),
                    "custom": .array([.object(["id": .string("custom-1"), "name": .string("Pirate"), "instructions": .string("Talk like a pirate.")])]),
                ]),
            ]),
        ])
        #expect(settings.stylePreferences.selected == "custom-1")
        #expect(settings.stylePreferences.custom == [CustomStyle(id: "custom-1", name: "Pirate", instructions: "Talk like a pirate.")])
    }

    @Test func missingOrPartialStylesDecodeToDefaults() {
        #expect(UserSettings(raw: [:]).stylePreferences == StylePreferences())
        let partial = UserSettings(raw: ["theseus": .object(["styles": .object(["selected": .string("concise")])])])
        #expect(partial.stylePreferences == StylePreferences(selected: "concise", custom: []))
    }

    @Test func stylesRoundTripThroughJSON() throws {
        let preferences = StylePreferences(selected: "x", custom: [CustomStyle(id: "x", name: "Haiku", instructions: "Answer in haiku.")])
        let settings = UserSettings(raw: ["theseus": .object([StylePreferences.namespaceKey: try preferences.jsonValue()])])
        #expect(settings.stylePreferences == preferences)
    }
}
