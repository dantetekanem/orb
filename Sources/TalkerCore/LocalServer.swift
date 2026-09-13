import Foundation
import Network

public struct Reply {
    public let status: Int
    public let body: [String: String]
    public init(_ status: Int = 200, _ body: [String: String]) { self.status = status; self.body = body }
    var data: Data {
        let payload = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let label = status < 400 ? "OK" : "Error"
        return Data("HTTP/1.1 \(status) \(label)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + payload
    }
}

public enum RequestEnd { case disconnected, timedOut }

// All callbacks and request handling run on the main queue; synthesis must never block it.
public final class LocalServer {
    public typealias Handler = (Command, @escaping (Reply) -> Void) -> ((RequestEnd) -> Void)?
    private var listener: NWListener?
    private var sessions: [UUID: HTTPSession] = [:]
    public var onState: ((String) -> Void)?
    public init() {}

    public func start(handle: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 45821)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("API ready · 127.0.0.1:45821")
            case .failed: self?.onState?("API unavailable · port 45821 may be in use")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.sessions.count < 8 else { connection.cancel(); return }
            let id = UUID()
            let session = HTTPSession(connection: connection, handle: handle) { [weak self] in self?.sessions[id] = nil }
            self.sessions[id] = session
            session.start()
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel(); listener = nil
        Array(sessions.values).forEach { $0.close() }
    }
}

private final class HTTPSession {
    let connection: NWConnection
    let handle: LocalServer.Handler
    let onClose: () -> Void
    var buffer = Data()
    var timeout: DispatchWorkItem?
    var finishRequest: ((RequestEnd) -> Void)?
    var dispatched = false
    var responding = false
    var closed = false

    init(connection: NWConnection, handle: @escaping LocalServer.Handler, onClose: @escaping () -> Void) {
        self.connection = connection; self.handle = handle; self.onClose = onClose
    }
    func start() {
        armTimeout(3)
        connection.start(queue: .main)
        receive()
    }
    func armTimeout(_ seconds: Double, waitingForAnswer: Bool = false) {
        timeout?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            if waitingForAnswer && !self.responding {
                self.armTimeout(3)
                self.finishHandling(.timedOut)
            } else { self.close() }
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: dispatched ? 1 : 4096) { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.responding else { return }
            if self.dispatched {
                if complete || error != nil || data?.isEmpty == false { self.close() }
                else { self.receive() }
                return
            }
            if let data { self.buffer.append(data) }
            do {
                if let command = try Command.parse(self.buffer) {
                    if case .ask(let question) = command {
                        guard !complete, error == nil else { self.close(); return }
                        self.armTimeout(Double(question.timeoutSeconds), waitingForAnswer: true)
                    }
                    self.dispatched = true
                    self.buffer.removeAll()
                    let finish = self.handle(command) { [weak self] in self?.send($0) }
                    if self.closed || self.responding { finish?(.disconnected) }
                    else { self.finishRequest = finish; self.receive() }
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            } catch let error as APIError {
                self.send(Reply(error.status, ["error": error.reason]))
            } catch { self.send(Reply(400, ["error": "Invalid request"])) }
        }
    }
    func send(_ reply: Reply) {
        guard !closed, !responding else { return }
        responding = true
        finishHandling()
        connection.send(content: reply.data, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    func finishHandling(_ reason: RequestEnd = .disconnected) {
        let finish = finishRequest
        finishRequest = nil
        finish?(reason)
    }
    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel(); timeout = nil
        finishHandling()
        connection.cancel()
        onClose()
    }
}
