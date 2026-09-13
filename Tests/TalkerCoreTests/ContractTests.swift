import XCTest
@testable import TalkerCore

final class ContractTests: XCTestCase {
    func request(_ body: String = "{\"text\":\"Hello\"}", method: String = "POST", path: String = "/speak",
                 headers: String = "", host: String = "127.0.0.1:45821") -> Data {
        Data("\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
    }

    func testMessageContractAndUTF8Framing() throws {
        XCTAssertEqual(try Command.parse(request()), .speak(Message(text: "Hello")))
        XCTAssertEqual(try Command.parse(request("{\"text\":\"Olá, 世界\",\"source\":\"Pi\"}")),
                       .speak(Message(text: "Olá, 世界", source: "Pi")))
        XCTAssertEqual(try Command.parse(request("", path: "/stop")), .stop)
        XCTAssertEqual(try Command.parse(request("", method: "GET", path: "/status")), .status)
    }

    func testFragmentedRequestWaitsForCompleteBody() throws {
        let bytes = request()
        for length in 0..<bytes.count {
            XCTAssertNil(try Command.parse(bytes.prefix(length)))
        }
        XCTAssertNotNil(try Command.parse(bytes))
    }

    func testBrowserAndRebindingRequestsAreRejected() {
        for headers in ["Origin: https://example.com\r\n", "Origin: null\r\n",
                        "Transfer-Encoding: chunked\r\n", "Content-Length: 0\r\n"] {
            XCTAssertThrowsError(try Command.parse(request(headers: headers)))
        }
        XCTAssertThrowsError(try Command.parse(request(host: "example.com:45821")))
        let form = String(decoding: request(), as: UTF8.self).replacingOccurrences(of: "application/json", with: "text/plain")
        XCTAssertThrowsError(try Command.parse(Data(form.utf8)))
    }

    func testInvalidPayloadsAndOversizedMessagesAreRejected() {
        for body in ["{}", "not json", "{\"text\":\"  \\n\"}", "{\"text\":5}",
                     "{\"text\":\"Hi\",\"source\":\"\"}",
                     "{\"text\":\"\(String(repeating: "x", count: 2001))\"}"] {
            XCTAssertThrowsError(try Command.parse(request(body)))
        }
        XCTAssertThrowsError(try Command.parse(Data(repeating: 65, count: 4097)))
        XCTAssertThrowsError(try Command.parse(request(headers: "X-Large: \(String(repeating: "x", count: 4100))\r\n")))
        XCTAssertThrowsError(try Command.parse(request() + request()))
        XCTAssertThrowsError(try Command.parse(request(path: "/missing")))
        XCTAssertThrowsError(try Command.parse(request(method: "GET")))
    }

    func testLifecycleReplacementAndStaleCompletion() {
        var state = Playback()
        let old = state.begin(Message(text: "First"))
        XCTAssertEqual(state.phase, .preparing)
        state.started(old)
        XCTAssertEqual(state.phase, .speaking)
        let current = state.begin(Message(text: "Second"))
        state.finished(old)
        state.fail(old)
        state.dismiss(old)
        XCTAssertEqual(state.id, current)
        XCTAssertEqual(state.phase, .preparing)
        state.started(current)
        state.finished(current)
        XCTAssertEqual(state.phase, .settling)
        state.dismiss(current)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.message)
    }

    func testStopAndFailureRejectLateCallbacks() {
        var state = Playback()
        let id = state.begin(Message(text: "Hello"))
        state.stop()
        state.started(id)
        state.finished(id)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.id)
        let next = state.begin(Message(text: "Again"))
        state.fail(next)
        state.started(next)
        XCTAssertEqual(state.phase, .failed)
        state.dismiss(next)
        XCTAssertEqual(state.phase, .idle)
    }
}
