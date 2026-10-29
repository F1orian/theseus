import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Voice (VOICE-01, VOICE-06, ADR 0080): Server transcription, the TTS voices and the STT engine.
@Suite("Audio endpoints")
struct AudioEndpointTests {
    private func request<Response>(_ endpoint: Endpoint<Response>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    @Test func transcriptionUploadsTheRecordingWithTheLanguage() throws {
        let audio = Data("RIFF....WAVE".utf8)
        let request = request(.transcription(audio: audio, filename: "speech.wav", contentType: "audio/wav", language: "en"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/audio/transcriptions")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=theseus-"))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF....WAVE\r\n"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")

        let withoutLanguage = String(decoding: try #require(self.request(.transcription(audio: audio, filename: "a\"b.wav", contentType: "audio/wav", language: nil)).httpBody), as: UTF8.self)
        #expect(!withoutLanguage.contains("name=\"language\""))
        #expect(withoutLanguage.contains("filename=\"ab.wav\""))
    }

    @Test func transcriptionDecodesTrimmedText() throws {
        let text = try Endpoint<Transcription>.transcription(audio: Data(), filename: "a.wav", contentType: "audio/wav", language: nil)
            .decode(Fixture.data("synthetic/audio.transcription.json"))
        #expect(text == Transcription(text: "Tell me how a mouse solves a maze."))
        #expect(try Endpoint<Transcription>.transcription(audio: Data(), filename: "a.wav", contentType: "audio/wav", language: nil).decode(Data("{}".utf8)).text.isEmpty)
    }

    @Test func voicesDecodeWithNamesFallingBackToIDs() throws {
        #expect(request(.audioVoices).url?.path() == "/api/v1/audio/voices")
        #expect(try Endpoint<[ServerVoice]>.audioVoices.decode(Fixture.data("audio.voices.json")).isEmpty)
        let voices = try Endpoint<[ServerVoice]>.audioVoices.decode(Fixture.data("synthetic/audio.voices.json"))
        #expect(voices == [ServerVoice(id: "alloy", name: "Alloy"), ServerVoice(id: "echo", name: "Echo"), ServerVoice(id: "nova", name: "nova")])
    }

    @Test func audioConfigKnowsTheSpeechToTextEngine() throws {
        let recorded = try Endpoint<AudioConfig>.audioConfig.decode(Fixture.data("config.json"))
        #expect(recorded.sttEngine == nil)
        #expect(!recorded.hasServerTranscription)
        let configured = try Endpoint<AudioConfig>.audioConfig.decode(Fixture.data("synthetic/config.audio-engines.json"))
        #expect(configured.hasServerTranscription)
        #expect(configured.sttEngine == "openai")
        let browser = try Endpoint<AudioConfig>.audioConfig.decode(Data(#"{"audio":{"stt":{"engine":"web"}}}"#.utf8))
        #expect(!browser.hasServerTranscription, "`web` is the web client's browser recogniser")
    }
}
