import Foundation

public struct Message: Equatable {
    public let text: String
    public let source: String
    public let title: String?
    public let sourceContext: SourceContext?
    public init(text: String, source: String = "Agent", title: String? = nil, sourceContext: SourceContext? = nil) {
        self.text = text
        self.source = source
        self.title = title
        self.sourceContext = sourceContext
    }
    static func validated(_ rawText: String, source rawSource: String?, title rawTitle: String? = nil,
                          sourceContext: SourceContext? = nil) throws -> Message {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (rawSource ?? "Agent").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count), (1...32).contains(source.count),
              !text.contains("\0"), !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APIError(422, "Text must be 1–2000 characters; source 1–32")
        }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title {
            guard (1...24).contains(title.count), !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw APIError(422, "Title must be 1–24 characters without controls")
            }
        }
        return Message(text: text, source: source, title: title, sourceContext: try sourceContext?.validated())
    }
}

public struct APIError: Error {
    public let status: Int
    public let reason: String
    public init(_ status: Int, _ reason: String) { self.status = status; self.reason = reason }
}

public enum Command: Equatable {
    case speak(Message), ask(Question), stop, status

    // One HTTP/1.1 request per connection. Deliberately no chunking or pipelining.
    public static func parse(_ data: Data) throws -> Command? {
        guard data.count <= 20_480 else { throw APIError(413, "Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 4096 else { throw APIError(431, "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 4096,
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw APIError(400, "Invalid headers")
        }
        let lines = head.components(separatedBy: "\r\n")
        let route = lines[0].components(separatedBy: " ")
        guard route.count == 3, route[2] == "HTTP/1.1" else { throw APIError(400, "Use HTTP/1.1") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw APIError(400, "Invalid header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  headers[key] == nil else { throw APIError(400, "Ambiguous header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:45821", headers["origin"] == nil else {
            throw APIError(403, "Only local non-browser clients are accepted")
        }
        guard headers["transfer-encoding"] == nil else { throw APIError(400, "Chunking is unsupported") }
        let lengthValue = headers["content-length"] ?? "0"
        guard !lengthValue.isEmpty, lengthValue.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthValue), length <= 16_384 else { throw APIError(413, "Invalid body length") }
        if route[0] == "POST", headers["content-length"] == nil { throw APIError(411, "Content-Length required") }
        let body = data[boundary.upperBound...]
        guard body.count >= length else { return nil }
        guard body.count == length else { throw APIError(400, "Extra request bytes") }
        switch (route[0], route[1]) {
        case ("GET", "/status") where length == 0: return .status
        case ("POST", "/stop") where length == 0: return .stop
        case ("POST", "/speak"), ("POST", "/ask"):
            guard headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else {
                throw APIError(415, "Use application/json")
            }
            if route[1] == "/ask" { return .ask(try Question.decode(Data(body))) }
            struct Payload: Decodable {
                let text: String
                let source: String?, title: String?
                let sourceContext: SourceContext?
                enum CodingKeys: String, CodingKey { case text, source, title, sourceContext = "source_context" }
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
                throw APIError(400, "Expected text and optional source, title and source_context")
            }
            return .speak(try Message.validated(payload.text, source: payload.source, title: payload.title,
                                               sourceContext: payload.sourceContext))
        default: throw APIError(404, "Unknown method or path")
        }
    }
}

public struct Playback {
    public enum Phase: String { case idle, preparing, speaking, choosing, notifying, settling, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?
    public private(set) var message: Message?
    public init() {}
    @discardableResult public mutating func begin(_ message: Message) -> UUID {
        let next = UUID()
        id = next; self.message = message; phase = .preparing
        return next
    }
    public mutating func started(_ id: UUID) {
        if self.id == id && phase == .preparing { phase = .speaking }
    }
    public mutating func finished(_ id: UUID, awaitingAnswer: Bool = false) {
        if self.id == id && phase == .speaking { phase = awaitingAnswer ? .choosing : .settling }
    }
    public mutating func notify(_ id: UUID, awaitingAnswer: Bool) {
        if self.id == id && (phase == .preparing || phase == .speaking) { phase = awaitingAnswer ? .choosing : .notifying }
    }
    public mutating func dismiss(_ id: UUID) {
        if self.id == id && (phase == .settling || phase == .failed || phase == .notifying) { stop() }
    }
    public mutating func fail(_ id: UUID) {
        if self.id == id && (phase == .preparing || phase == .speaking) { phase = .failed }
    }
    public mutating func stop() { id = nil; message = nil; phase = .idle }
}
