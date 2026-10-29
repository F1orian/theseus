public import Foundation

/// Structured questions the model asks before it continues (the server's `ask_user` builtin
/// tool). Shown as the clarifying-question card above the composer (CHAT-09).
public struct ClarifyingQuestions: Sendable, Hashable {
    public struct Option: Sendable, Hashable {
        public var label: String
        public var description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Sendable, Hashable, Identifiable {
        public var id: String
        /// A short chip such as "Budget".
        public var header: String
        public var text: String
        /// The first option is the model's recommendation.
        public var options: [Option]
        /// Whether a free-text answer ("Type your answer") is allowed.
        public var allowsOther: Bool

        public init(id: String, header: String, text: String, options: [Option], allowsOther: Bool = true) {
            self.id = id
            self.header = header
            self.text = text
            self.options = options
            self.allowsOther = allowsOther
        }
    }

    public enum Answer: Sendable, Hashable {
        case option(index: Int, Option)
        case other(String)

        public var displayText: String {
            switch self {
            case .option(_, let option): option.label
            case .other(let text): text
            }
        }
    }

    /// The tool call to resolve (`call_id`).
    public var callID: String
    public var questions: [Question]
    /// How long the server keeps the question open.
    public var timeout: TimeInterval?

    public init(callID: String, questions: [Question], timeout: TimeInterval? = nil) {
        self.callID = callID
        self.questions = questions
        self.timeout = timeout
    }

    /// Parses the JSON `arguments` of an `ask_user` tool call. Returns `nil` for malformed input.
    public init?(callID: String, arguments: String) {
        guard let data = arguments.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.questions.isEmpty
        else { return nil }
        let allowOther = wire.allowOther ?? true
        self.callID = callID
        self.timeout = wire.timeoutMilliseconds.map { $0 / 1000 }
        self.questions = wire.questions.enumerated().map { index, question in
            Question(
                id: question.id,
                header: question.header?.isEmpty == false ? question.header ?? "" : "Question \(index + 1)",
                text: question.question,
                options: question.options.map { Option(label: $0.label, description: $0.description ?? "") },
                allowsOther: question.allowOther ?? allowOther
            )
        }
    }

    /// The `answers` object for `POST …/resolve {action: "answer"}`, keyed by question id.
    /// Unanswered questions are omitted.
    public func wireAnswers(_ answers: [String: Answer]) -> [String: [String: WireValue]] {
        var result: [String: [String: WireValue]] = [:]
        for question in questions {
            switch answers[question.id] {
            case .option(let index, let option):
                result[question.id] = [
                    "type": .string("option"),
                    "option_index": .int(index),
                    "label": .string(option.label),
                    "description": .string(option.description),
                ]
            case .other(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result[question.id] = ["type": .string("other"), "text": .string(trimmed)]
            case nil:
                continue
            }
        }
        return result
    }

    /// Whether every question has a usable answer.
    public func isComplete(_ answers: [String: Answer]) -> Bool {
        questions.allSatisfy { question in
            switch answers[question.id] {
            case .option: true
            case .other(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case nil: false
            }
        }
    }

    /// A scalar for the answers payload.
    public enum WireValue: Sendable, Hashable, Encodable {
        case string(String)
        case int(Int)

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            }
        }
    }

    /// The server's `ask_user` arguments (`normalize_ask_user_request`).
    private struct Wire: Decodable {
        struct Question: Decodable {
            let id: String
            let header: String?
            let question: String
            let options: [Option]
            let allowOther: Bool?

            enum CodingKeys: String, CodingKey {
                case id, header, question, options
                case allowOther = "allow_other"
            }
        }

        struct Option: Decodable {
            let label: String
            let description: String?
        }

        let questions: [Question]
        let allowOther: Bool?
        let timeoutMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case questions
            case allowOther = "allow_other"
            case timeoutMilliseconds = "timeout_ms"
        }
    }
}

/// The answers recorded in a resolved `ask_user` result, for the Q/A card in the transcript.
public struct ClarifyingAnswers: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    public var entries: [Entry]
    public var wasCancelled: Bool

    /// Pairs the questions with the answers in the tool result JSON (`{status, answers}`).
    public init?(questions: ClarifyingQuestions, resultText: String) {
        guard let data = resultText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let answers = object["answers"] as? [String: Any] ?? [:]
        wasCancelled = (object["status"] as? String) != "answered"
        entries = questions.questions.compactMap { question in
            guard let answer = answers[question.id] as? [String: Any] else { return nil }
            let text = (answer["label"] as? String) ?? (answer["text"] as? String) ?? ""
            return Entry(question: question.text, answer: text)
        }
    }
}
