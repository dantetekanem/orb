import Foundation

// One response owned by one question; callers use the same main queue as playback.
public final class PendingQuestion {
    public let id: UUID
    public let question: Question
    private var completion: ((Reply) -> Void)?

    public init(id: UUID, question: Question, completion: @escaping (Reply) -> Void) {
        self.id = id; self.question = question; self.completion = completion
    }

    public func canAnswer(_ answerID: String, during playback: Playback) -> Bool {
        completion != nil && playback.id == id && playback.phase == .choosing
            && question.answers.contains(where: { $0.id == answerID })
    }

    @discardableResult public func answer(_ answerID: String, during playback: Playback) -> Bool {
        guard canAnswer(answerID, during: playback) else { return false }
        resolve(Reply(200, ["id": id.uuidString, "state": "answered", "answer_id": answerID]))
        return true
    }

    @discardableResult public func expire(during playback: Playback) -> Bool {
        guard completion != nil, playback.id == id,
              [.preparing, .speaking, .choosing].contains(playback.phase) else { return false }
        resolve(Reply(200, ["id": id.uuidString, "state": "answered",
                            "answer_id": question.defaultAnswerID, "reason": "timeout"]))
        return true
    }

    public func cancel(reason: String) {
        resolve(Reply(409, ["id": id.uuidString, "state": "cancelled", "reason": reason]))
    }

    public func fail(_ reason: String) {
        resolve(Reply(503, ["id": id.uuidString, "state": "failed", "error": reason]))
    }

    public func abandon() { completion = nil }

    private func resolve(_ reply: Reply) {
        let callback = completion
        completion = nil
        callback?(reply)
    }
}
