// Adapted from the HTTP server in brother-escl (https://github.com/grk/brother-escl), MIT.
// See THIRD-PARTY-NOTICES.md.

import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let body: Data
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)] = []
    public var body = Data()

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func status(_ code: Int) -> HTTPResponse { HTTPResponse(status: code) }

    public static func xml(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/xml")], body: Data(text.utf8))
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// A small HTTP/1.1 server, advertised over Bonjour. It is reachable from the local network,
/// so header size, body size and connection count are bounded and idle connections dropped.
/// Handlers may block for as long as a page takes to scan; each connection is served on a
/// concurrent queue.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    static let maxHeaderBytes = 16 << 10
    static let maxBodyBytes = 1 << 20
    static let maxConnections = 32
    static let idleTimeout: TimeInterval = 30

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "http", attributes: .concurrent)
    private let lock = NSLock()
    private var connectionCount = 0

    /// `port` 0 lets the system choose; clients learn the port from the Bonjour advertisement.
    public init(port: UInt16, service: NWListener.Service, handler: @escaping Handler) throws {
        listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.service = service
        self.handler = handler
    }

    public func start() {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: log("listening on port \(listener.port?.rawValue ?? 0)")
            case .failed(let error):
                log("listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add(let endpoint) = change { log("advertised as \(endpoint)") }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let allowed = connectionCount < Self.maxConnections
        if allowed { connectionCount += 1 }
        lock.unlock()
        guard allowed else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled:
                self?.lock.lock()
                self?.connectionCount -= 1
                self?.lock.unlock()
            default: break
            }
        }
        connection.start(queue: queue)
        serve(connection, buffered: Data())
    }

    private func serve(_ connection: NWConnection, buffered: Data) {
        switch Self.parse(buffered) {
        case .request(let request, let rest, let keepAlive):
            send(handler(request), on: connection, keepAlive: keepAlive) {
                self.serve(connection, buffered: rest)
            }
        case .failure(let status):
            send(.status(status), on: connection, keepAlive: false) {}
        case .incomplete:
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timeout)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, finished, error in
                timeout.cancel()
                if let data, !data.isEmpty {
                    self.serve(connection, buffered: buffered + data)
                } else if finished || error != nil {
                    connection.cancel()
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool,
                      then next: @escaping () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { error in
            if error != nil || !keepAlive { connection.cancel() } else { next() }
        })
    }

    enum Parsed {
        case request(HTTPRequest, rest: Data, keepAlive: Bool)
        case incomplete
        case failure(Int)
    }

    static func parse(_ buffer: Data) -> Parsed {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .failure(431) : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= maxHeaderBytes else { return .failure(431) }

        let lines = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .failure(400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .failure(400) }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .failure(501) }

        var length = 0
        if let declared = headers["content-length"] {
            guard let n = Int(declared), n >= 0 else { return .failure(400) }
            guard n <= maxBodyBytes else { return .failure(413) }
            length = n
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        let request = HTTPRequest(method: String(requestLine[0]), path: path,
                                  body: Data(buffer[bodyStart..<(bodyStart + length)]))
        return .request(request, rest: Data(buffer[(bodyStart + length)...]),
                        keepAlive: headers["connection"]?.lowercased() != "close")
    }
}

private let logTimestamp = ISO8601DateFormatter()
private let logLock = NSLock()

/// Timestamped line on stderr, which launchd sends to the log file.
public func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(Data("\(logTimestamp.string(from: Date())) \(message)\n".utf8))
}
