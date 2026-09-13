import Foundation

public struct Question: Equatable {
    public struct Answer: Equatable, Identifiable {
        public let id: String
        public let label: String
        public let summary: String
        public let detail: String
    }

    public let message: Message
    public let answers: [Answer]
    public let defaultAnswerID: String
    public let timeoutSeconds: Int
    public var isCompact: Bool {
        answers.count == 2 && message.text.count <= 160 && answers.allSatisfy { $0.label.count <= 20 }
    }

    static func decode(_ data: Data) throws -> Question {
        struct Payload: Decodable {
            struct Choice: Decodable {
                let id: String, label: String
                let summary: String?, detail: String?
            }
            let question: String
            let source: String?, title: String?
            let sourceContext: SourceContext?
            let answers: [Choice]
            let defaultAnswerID: String
            let timeoutSeconds: Int?
            enum CodingKeys: String, CodingKey {
                case question, source, title, answers, sourceContext = "source_context"
                case defaultAnswerID = "default_answer_id", timeoutSeconds = "timeout_seconds"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(400, "Expected question, default_answer_id, answer objects and optional integer timeout_seconds")
        }
        let message = try Message.validated(payload.question, source: payload.source, title: payload.title,
                                            sourceContext: payload.sourceContext)
        guard (2...6).contains(payload.answers.count) else { throw APIError(422, "Provide 2–6 answers") }
        let answers = try payload.answers.map { answer in
            Answer(id: try field(answer.id, name: "id", limit: 64, singleLine: true),
                   label: try field(answer.label, name: "label", limit: 80, singleLine: true),
                   summary: try field(answer.summary ?? "", name: "summary", limit: 200, minimum: 0),
                   detail: try field(answer.detail ?? "", name: "detail", limit: 2000, minimum: 0))
        }
        guard Set(answers.map(\.id)).count == answers.count else { throw APIError(422, "Answer IDs must be unique") }
        let defaultID = try field(payload.defaultAnswerID, name: "default_answer_id", limit: 64, singleLine: true)
        guard answers.contains(where: { $0.id == defaultID }) else { throw APIError(422, "Default must match an answer ID") }
        let timeout = payload.timeoutSeconds ?? 30
        guard (10...60).contains(timeout) else { throw APIError(422, "timeout_seconds must be 10–60") }
        return Question(message: message, answers: answers, defaultAnswerID: defaultID, timeoutSeconds: timeout)
    }

    private static func field(_ raw: String, name: String, limit: Int, minimum: Int = 1, singleLine: Bool = false) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minimum...limit).contains(value.count), !value.contains("\0"),
              !singleLine || !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APIError(422, "Answer \(name) must be \(minimum)–\(limit) characters without invalid controls")
        }
        return value
    }
}
