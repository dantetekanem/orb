import XCTest
@testable import TalkerCore

final class SourceContextTests: XCTestCase {
    private let context = ["kind": "herdr", "workspace_id": "w1", "tab_id": "w1:t1", "pane_id": "w1:p3"]
    private func message(title: Any? = nil, context: Any? = nil, asking: Bool = false) throws -> Message {
        var payload: [String: Any] = [asking ? "question" : "text": "Hello", "source": "Pi"]
        payload["title"] = title; payload["source_context"] = context
        if asking {
            payload["answers"] = [["id": "yes", "label": "Yes"], ["id": "no", "label": "No"]]
            payload["default_answer_id"] = "no"
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = Data("POST /\(asking ? "ask" : "speak") HTTP/1.1\r\nHost: 127.0.0.1:45821\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        switch try Command.parse(request) {
        case .speak(let value): return value
        case .ask(let value): return value.message
        default: throw APIError(500, "Expected a message")
        }
    }

    func testSpeechAndQuestionsCarryBoundedTitleAndSenderWithoutChangingSpokenText() throws {
        for asking in [false, true] {
            let value = try message(title: " Herdr 1:3 ", context: context, asking: asking)
            XCTAssertEqual(value.text, "Hello")
            XCTAssertEqual(value.source, "Pi")
            XCTAssertEqual(value.title, "Herdr 1:3")
            XCTAssertEqual(value.sourceContext?.workspaceID, "w1")
            XCTAssertEqual(value.sourceContext?.tabID, "w1:t1")
            XCTAssertEqual(value.sourceContext?.paneID, "w1:p3")
            XCTAssertEqual(try message(asking: asking), Message(text: "Hello", source: "Pi"))
        }
        XCTAssertEqual(try message(title: String(repeating: "x", count: 24)).title?.count, 24)
    }

    func testInvalidTitleOrSenderIsRejectedOnBothRoutes() {
        var contexts: [Any] = [42, ["kind": "herdr"]]
        for (key, value) in [("kind", "shell"), ("workspace_id", ""), ("workspace_id", String(repeating: "w", count: 33)),
                             ("tab_id", "w2:t1"), ("pane_id", "w2:p3"), ("pane_id", "w1:p\n3"),
                             ("pane_id", "w1:p" + String(repeating: "3", count: 61))] {
            contexts.append(context.merging([key: value]) { _, new in new })
        }
        for asking in [false, true] {
            for title: Any in [" ", "a\nb", String(repeating: "x", count: 25), 42] {
                XCTAssertThrowsError(try message(title: title, asking: asking))
            }
            for context in contexts { XCTAssertThrowsError(try message(context: context, asking: asking)) }
        }
    }
}
