public import Foundation

// Voice (VOICE-01…06): Server speech-to-text and the Server's TTS voices
// (docs/research/open-webui-api.md §8, ADR 0080). Text-to-speech itself is `.speech(text:voice:)`.

/// What `/api/v1/audio/transcriptions` heard.
public struct Transcription: Sendable, Equatable, Decodable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try container.decodeIfPresent(String.self, forKey: .text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One voice of the Server's TTS engine (`GET /api/v1/audio/voices`).
public struct ServerVoice: Sendable, Equatable, Hashable, Decodable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.name = name.isEmpty ? id : name
    }
}

extension Endpoint where Response == Transcription {
    /// `POST /api/v1/audio/transcriptions` (needs `chat.stt` and an STT engine) as
    /// `multipart/form-data`: the recording as `file`, plus the Speech language when known.
    public static func transcription(audio: Data, filename: String, contentType: String, language: String?) -> Self {
        let boundary = "theseus-\(UUID().uuidString)"
        let safeName = filename.filter { $0 != "\"" && !$0.isNewline }
        var body = Data()
        if let language, !language.isEmpty {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
            body.append(Data("\(language)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return Endpoint(
            method: .post,
            path: "api/v1/audio/transcriptions",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authentication: .required
        )
    }
}

extension Endpoint where Response == [ServerVoice] {
    /// `GET /api/v1/audio/voices`: the TTS engine's voices (empty without an engine).
    public static var audioVoices: Self {
        Endpoint(method: .get, path: "api/v1/audio/voices", authentication: .required) { data in
            try WireCoding.decoder.decode(ServerVoiceList.self, from: data).voices ?? []
        }
    }
}

private struct ServerVoiceList: Decodable {
    let voices: [ServerVoice]?
}
