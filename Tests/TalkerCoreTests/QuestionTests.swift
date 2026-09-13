import XCTest
@testable import TalkerCore

final class QuestionTests: XCTestCase {
    private var answers: [[String: String]] {
        ["first", "second"].map { ["id": $0, "label": "Option \($0)", "summary": "Short reason", "detail": "The complete explanation."] }
    }
    private func request(question: Any = " Qual opção? ", answers: Any? = nil,
                         defaultAnswer: Any? = "first", timeout: Any? = nil,
                         headers: String = "", host: String = "127.0.0.1:45821") throws -> Data {
        var payload: [String: Any] = ["question": question, "source": " Pi ", "answers": answers ?? self.answers]
        payload["default_answer_id"] = defaultAnswer
        payload["timeout_seconds"] = timeout
        let body = try JSONSerialization.data(withJSONObject: payload)
        return Data("POST /ask HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\(headers)\r\n".utf8) + body
    }
    private func question() throws -> Question {
        guard case .ask(let question)? = try Command.parse(request()) else { throw APIError(500, "Expected question") }
        return question
    }
    private func ready(_ question: Question) -> Playback {
        var playback = Playback()
        let id = playback.begin(question.message)
        playback.started(id)
        playback.finished(id, awaitingAnswer: true)
        return playback
    }

    func testAskDecodesQuestionOnlySpeechAndFragmentedUTF8() throws {
        let bytes = try request()
        for length in 0..<bytes.count { XCTAssertNil(try Command.parse(bytes.prefix(length))) }
        let question = try question()
        XCTAssertEqual(question.message, Message(text: "Qual opção?", source: "Pi"))
        XCTAssertEqual(question.answers.map(\.id), ["first", "second"])
        XCTAssertEqual(question.answers[1].summary, "Short reason")
        XCTAssertEqual(question.answers[1].detail, "The complete explanation.")
    }

    func testAskRejectsInvalidChoiceCountsIDsAndText() throws {
        var invalid = [Array(answers.prefix(1)), Array(repeating: answers[0], count: 7), [answers[0], answers[0]]]
        for (field, value) in [("id", " first "), ("id", "bad\nid"), ("id", String(repeating: "x", count: 65)),
                               ("label", " "), ("label", String(repeating: "x", count: 81)),
                               ("summary", String(repeating: "x", count: 201)),
                               ("detail", "bad\0text"), ("detail", String(repeating: "x", count: 2001))] {
            var changed = answers
            changed[1][field] = value
            invalid.append(changed)
        }
        for choices in invalid {
            XCTAssertThrowsError(try Command.parse(request(answers: choices))) {
                XCTAssertEqual(($0 as? APIError)?.status, 422)
            }
        }
        for value in [" ", String(repeating: "q", count: 2001)] {
            XCTAssertThrowsError(try Command.parse(request(question: value))) {
                XCTAssertEqual(($0 as? APIError)?.status, 422)
            }
        }
        XCTAssertThrowsError(try Command.parse(request(question: 3))) { XCTAssertEqual(($0 as? APIError)?.status, 400) }
        XCTAssertThrowsError(try Command.parse(request(answers: "not choices"))) { XCTAssertEqual(($0 as? APIError)?.status, 400) }
    }

    func testShortChoicesUseCompactPresentationAndOptionalHoverText() throws {
        let plain = [["id": "first", "label": "Yes"], ["id": "second", "label": "No"]]
        guard case .ask(let compact)? = try Command.parse(request(answers: plain)) else {
            return XCTFail("Expected plain choices")
        }
        XCTAssertTrue(compact.isCompact)
        XCTAssertEqual(compact.answers.map(\.label), ["Yes", "No"])
        var explained = plain
        explained[0]["summary"] = " Short reason "
        explained[0]["detail"] = " Full detail "
        guard case .ask(let hover)? = try Command.parse(request(answers: explained)) else {
            return XCTFail("Expected hover details")
        }
        XCTAssertTrue(hover.isCompact)
        XCTAssertEqual(hover.answers[0].summary, "Short reason")
        XCTAssertEqual(hover.answers[0].detail, "Full detail")
        var long = plain
        long[0]["label"] = String(repeating: "x", count: 21)
        for bytes in [try request(answers: long), try request(question: String(repeating: "q", count: 161), answers: plain),
                      try request(answers: plain + [["id": "third", "label": "Later"]])] {
            guard case .ask(let list)? = try Command.parse(bytes) else { return XCTFail("Expected list") }
            XCTAssertFalse(list.isCompact)
        }
    }

    func testAskRequiresAKnownDefaultAndBoundsItsAPIDeadline() throws {
        XCTAssertEqual(try question().defaultAnswerID, "first")
        XCTAssertEqual(try question().timeoutSeconds, 30)
        for timeout in [10, 20, 30, 60] {
            guard case .ask(let question)? = try Command.parse(request(defaultAnswer: " second ", timeout: timeout)) else {
                return XCTFail("Expected a valid bounded question")
            }
            XCTAssertEqual(question.defaultAnswerID, "second")
            XCTAssertEqual(question.timeoutSeconds, timeout)
        }
        for value: Any? in [nil, "", "unknown", 42] {
            XCTAssertThrowsError(try Command.parse(request(defaultAnswer: value)))
        }
        for value: Any in [9, 61, 10.5, "30", true] {
            XCTAssertThrowsError(try Command.parse(request(timeout: value)))
        }
    }

    func testExpiryReturnsDefaultOnceIncludingBeforeChoicesAppear() throws {
        let question = try question()
        for phase in [Playback.Phase.preparing, .speaking, .choosing] {
            var playback = Playback()
            let id = playback.begin(question.message)
            if phase != .preparing { playback.started(id) }
            if phase == .choosing { playback.finished(id, awaitingAnswer: true) }
            var replies: [Reply] = []
            var pending: PendingQuestion!
            pending = PendingQuestion(id: id, question: question) { reply in
                replies.append(reply)
                XCTAssertFalse(pending.expire(during: playback))
                XCTAssertFalse(pending.answer("second", during: playback))
            }
            XCTAssertTrue(pending.expire(during: playback))
            XCTAssertFalse(pending.expire(during: playback))
            XCTAssertEqual(replies.count, 1)
            XCTAssertEqual(replies[0].status, 200)
            XCTAssertEqual(replies[0].body, ["id": id.uuidString, "state": "answered",
                                            "answer_id": "first", "reason": "timeout"])
        }
    }

    func testExpiryRejectsAnUnownedOrStoppedPlayback() throws {
        let question = try question()
        var playback = ready(question)
        let pending = PendingQuestion(id: playback.id!, question: question) { _ in XCTFail("Stale expiry replied") }
        playback.stop()
        XCTAssertFalse(pending.expire(during: playback))
        _ = playback.begin(question.message)
        XCTAssertFalse(pending.expire(during: playback))
    }

    func testAskPreservesBrowserAndBodyBoundaries() throws {
        XCTAssertThrowsError(try Command.parse(request(headers: "Origin: https://example.com\r\n"))) {
            XCTAssertEqual(($0 as? APIError)?.status, 403)
        }
        XCTAssertThrowsError(try Command.parse(request(host: "example.com:45821"))) {
            XCTAssertEqual(($0 as? APIError)?.status, 403)
        }
        XCTAssertThrowsError(try Command.parse(request(question: String(repeating: "x", count: 17_000)))) {
            XCTAssertEqual(($0 as? APIError)?.status, 413)
        }
    }

    func testSuccessfulQuestionSpeechWaitsForAnAnswerAndRejectsStaleFinish() throws {
        var playback = Playback()
        let old = playback.begin(Message(text: "Old"))
        let current = playback.begin(try question().message)
        playback.finished(old, awaitingAnswer: true)
        XCTAssertEqual(playback.phase, .preparing)
        playback.started(current)
        playback.finished(current, awaitingAnswer: true)
        playback.dismiss(current)
        XCTAssertEqual(playback.phase, .choosing)
        XCTAssertEqual(playback.id, current)
    }

    func testSelectionRequiresCurrentReadyQuestionAndKnownChoice() throws {
        let question = try question()
        var playback = Playback()
        let id = playback.begin(question.message)
        var replies: [Reply] = []
        let pending = PendingQuestion(id: id, question: question) { replies.append($0) }
        XCTAssertFalse(pending.answer("first", during: playback))
        playback.started(id)
        playback.finished(id, awaitingAnswer: true)
        XCTAssertFalse(pending.answer("unknown", during: playback))
        _ = playback.begin(question.message)
        XCTAssertFalse(pending.answer("first", during: playback))
        XCTAssertTrue(replies.isEmpty)
        pending.abandon()
    }

    func testAnswerResolvesOnceEvenWhenCompletionReenters() throws {
        let question = try question(), playback = ready(question)
        var replies: [Reply] = []
        var pending: PendingQuestion!
        pending = PendingQuestion(id: playback.id!, question: question) { reply in
            replies.append(reply)
            XCTAssertFalse(pending.answer("first", during: playback))
            pending.cancel(reason: "stopped")
        }
        XCTAssertTrue(pending.answer("second", during: playback))
        XCTAssertFalse(pending.answer("first", during: playback))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].status, 200)
        XCTAssertEqual(replies[0].body, ["id": playback.id!.uuidString, "state": "answered", "answer_id": "second"])
    }

    func testCancellationAndFailureResolveWaitingCallers() throws {
        let question = try question(), playback = ready(question)
        for reason in ["stopped", "replaced"] {
            var replies: [Reply] = []
            let pending = PendingQuestion(id: playback.id!, question: question) { replies.append($0) }
            pending.cancel(reason: reason)
            pending.cancel(reason: reason)
            XCTAssertFalse(pending.expire(during: playback))
            XCTAssertFalse(pending.answer("first", during: playback))
            XCTAssertEqual(replies.count, 1)
            XCTAssertEqual(replies[0].status, 409)
            XCTAssertEqual(replies[0].body, ["id": playback.id!.uuidString, "state": "cancelled", "reason": reason])
        }
        var replies: [Reply] = []
        let pending = PendingQuestion(id: playback.id!, question: question) { replies.append($0) }
        pending.fail("Voice unavailable")
        XCTAssertFalse(pending.expire(during: playback))
        pending.cancel(reason: "stopped")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].status, 503)
        XCTAssertEqual(replies[0].body["state"], "failed")
    }

    func testAbandonDiscardsOldReplyAndLeavesNewReplyIndependent() throws {
        let question = try question(), oldPlayback = ready(question), newPlayback = ready(question)
        var replies: [Reply] = []
        let old = PendingQuestion(id: oldPlayback.id!, question: question) { replies.append($0) }
        let current = PendingQuestion(id: newPlayback.id!, question: question) { replies.append($0) }
        old.abandon()
        XCTAssertFalse(old.expire(during: oldPlayback))
        old.cancel(reason: "stopped")
        XCTAssertFalse(old.answer("first", during: oldPlayback))
        XCTAssertTrue(current.answer("second", during: newPlayback))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].body["id"], newPlayback.id!.uuidString)
    }
}
