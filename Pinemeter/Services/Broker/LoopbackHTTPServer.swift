//
//  LoopbackHTTPServer.swift
//  Pinemeter
//
//  Minimal HTTP/1.1 front-end for the MCP server transport.
//
//  The MCP SDK's server transports never touch sockets: they take a
//  framework-agnostic `MCP.HTTPRequest` and return an `MCP.HTTPResponse`.
//  This actor owns the socket half — an `NWListener` bound explicitly to the
//  loopback interface — parses just enough HTTP/1.1 to build that request, and
//  serializes the response back.
//

import Foundation
import MCP
import Network
import os

/// The request handler a `LoopbackHTTPServer` routes matched requests into,
/// plus the shutdown hook for the stack behind it.
struct LoopbackRequestHandler: Sendable {
    let handle: @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse
    let shutdown: @Sendable () async -> Void

    init(
        handle: @escaping @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse,
        shutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.handle = handle
        self.shutdown = shutdown
    }
}

enum LoopbackHTTPServerError: LocalizedError {
    case alreadyRunning
    case notRunning
    case portUnavailable
    case addressInUse(port: UInt16)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "The loopback server is already running."
        case .notRunning: return "The loopback server is not running."
        case .portUnavailable: return "The listener became ready without a port."
        case .addressInUse(let port): return "Port \(port) is already in use."
        case .listenerFailed(let why): return "The loopback listener failed: \(why)"
        }
    }
}

actor LoopbackHTTPServer {
    /// Builds the request handler once the listener's real port is known.
    /// The port is needed up front because Origin/Host validation is bound to it.
    typealias HandlerFactory = @Sendable (UInt16) async throws -> LoopbackRequestHandler

    /// The only interface this server is ever bound to. Never 0.0.0.0.
    static let loopbackHost = "127.0.0.1"

    /// Largest request head (request line + headers) accepted.
    private static let maximumHeaderBytes = 64 * 1024
    /// Largest request body accepted.
    private static let maximumBodyBytes = 1024 * 1024
    /// Default per-connection budget to deliver a complete request. A peer
    /// that opens a socket and never finishes a request is force-closed
    /// instead of leaking a `Task` for the life of the process.
    static let defaultReadTimeout: TimeInterval = 10

    private static let logger = os.Logger(subsystem: "com.pinemeter", category: "LoopbackHTTPServer")
    private static let queue = DispatchQueue(label: "com.pinemeter.broker.loopback")

    private let requestedPort: UInt16
    private let path: String
    private let readTimeout: TimeInterval
    private let listenerQueue: DispatchQueue
    private let onListenerStart: @Sendable () -> Void
    private let handlerFactory: HandlerFactory
    private let lifecycleGate: LifecycleGate

    private var listener: NWListener?
    private var handler: LoopbackRequestHandler?
    private(set) var resolvedPort: UInt16?

    /// - Parameters:
    ///   - port: Port to bind. `0` requests an ephemeral port (used by tests).
    ///   - path: The single routed path; anything else answers 404.
    ///   - readTimeout: Per-connection budget to deliver a complete request
    ///     before the socket is force-closed. Injectable so tests exercise the
    ///     behavior quickly; production uses `defaultReadTimeout`.
    ///   - handlerFactory: Builds the handler once the bound port is known.
    init(
        port: UInt16,
        path: String = "/mcp",
        readTimeout: TimeInterval = LoopbackHTTPServer.defaultReadTimeout,
        listenerQueue: DispatchQueue = LoopbackHTTPServer.queue,
        onListenerStart: @escaping @Sendable () -> Void = {},
        onLifecycleWait: @escaping @Sendable () -> Void = {},
        handlerFactory: @escaping HandlerFactory
    ) {
        self.requestedPort = port
        self.path = path
        self.readTimeout = readTimeout
        self.listenerQueue = listenerQueue
        self.onListenerStart = onListenerStart
        self.handlerFactory = handlerFactory
        self.lifecycleGate = LifecycleGate(onWait: onLifecycleWait)
    }

    /// Binds the listener, builds the handler for the resolved port and starts
    /// accepting connections.
    /// - Returns: The port actually bound.
    @discardableResult
    func start() async throws -> UInt16 {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        try Task.checkCancellation()
        guard listener == nil else { throw LoopbackHTTPServerError.alreadyRunning }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Self.loopbackHost),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        do {
            let port = try await Self.waitUntilReady(
                listener,
                requestedPort: requestedPort,
                queue: listenerQueue,
                onStart: onListenerStart
            )
            resolvedPort = port
            handler = try await handlerFactory(port)
            Self.logger.info("Broker loopback listener ready on 127.0.0.1:\(port, privacy: .public)")
            return port
        } catch {
            await Self.awaitCancelled(listener)
            self.listener = nil
            resolvedPort = nil
            throw error
        }
    }

    /// Cancels the listener and tears down the handler stack behind it.
    ///
    /// Awaits the listener's `.cancelled` state before returning (Pitfall 5):
    /// a follow-up `start()` on the same port must never race a not-yet-fully
    /// torn-down bind, which is exactly how a restart hits a leaked
    /// EADDRINUSE that clears itself a moment later.
    func stop() async {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        guard let listener else {
            resolvedPort = nil
            let handler = self.handler
            self.handler = nil
            await handler?.shutdown()
            return
        }
        await Self.awaitCancelled(listener)
        self.listener = nil
        resolvedPort = nil
        let handler = self.handler
        self.handler = nil
        await handler?.shutdown()
    }

    // MARK: - Listener lifecycle

    private static func waitUntilReady(
        _ listener: NWListener,
        requestedPort: UInt16,
        queue: DispatchQueue,
        onStart: @Sendable () -> Void
    ) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        once.resume(returning: port)
                    } else {
                        once.resume(throwing: LoopbackHTTPServerError.portUnavailable)
                    }
                case .failed(let error):
                    once.resume(throwing: Self.mapListenerFailure(error, requestedPort: requestedPort))
                case .waiting(let error):
                    // Most commonly EADDRINUSE. Network.framework would retry
                    // forever; surface it instead so the UI can report it.
                    once.resume(throwing: Self.mapListenerFailure(error, requestedPort: requestedPort))
                case .cancelled:
                    once.resume(throwing: LoopbackHTTPServerError.notRunning)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            onStart()
        }
    }

    /// Distinguishes a bind-time EADDRINUSE from any other listener failure,
    /// naming the port that was already in use so a caller (07-05's UI) can
    /// surface a `BrokerUIState.serverState.failed(message:)` without having
    /// to re-derive it from a generic error string.
    private static func mapListenerFailure(_ error: NWError, requestedPort: UInt16) -> LoopbackHTTPServerError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return .addressInUse(port: requestedPort)
        }
        return .listenerFailed(error.localizedDescription)
    }

    private static func awaitCancelled(_ listener: NWListener) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    once.resume(returning: ())
                default:
                    break
                }
            }
            switch listener.state {
            case .cancelled, .failed:
                once.resume(returning: ())
            default:
                listener.cancel()
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) async {
        await Self.serve(connection, path: path, handler: handler, readTimeout: readTimeout)
    }

    private static func serve(
        _ connection: NWConnection,
        path: String,
        handler: LoopbackRequestHandler?,
        readTimeout: TimeInterval
    ) async {
        connection.start(queue: Self.queue)
        defer { connection.cancel() }

        // A peer that opens the socket and never finishes a request must not
        // leak this Task for the life of the process: force-close after the
        // read budget expires. Cancelling the watchdog once the read
        // completes (success or failure) makes this a no-op on the fast path.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(readTimeout, 0) * 1_000_000_000))
            connection.cancel()
        }
        defer { watchdog.cancel() }

        let parsed: ParsedRequest?
        do {
            parsed = try await readRequest(from: connection)
        } catch let error as ParseFailure {
            await send(status: error.status, body: error.message, on: connection)
            return
        } catch {
            Self.logger.debug("Broker connection read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let request = parsed else { return }

        guard request.path == path else {
            await send(status: 404, body: "Not Found", on: connection)
            return
        }

        guard let handler else {
            await send(status: 503, body: "Broker not ready", on: connection)
            return
        }

        let response = await handler.handle(
            MCP.HTTPRequest(
                method: request.method,
                headers: request.headers,
                body: request.body,
                path: request.path
            )
        )
        await send(response, on: connection)
    }

    // MARK: - Request parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    private struct ParseFailure: Error {
        let status: Int
        let message: String
    }

    private static func readRequest(from connection: NWConnection) async throws -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headEnd: Range<Data.Index>?

        while headEnd == nil {
            guard let chunk = try await receive(on: connection) else {
                // Peer closed before a complete request head arrived.
                return nil
            }
            buffer.append(chunk)
            if buffer.count > maximumHeaderBytes {
                throw ParseFailure(status: 431, message: "Request header fields too large")
            }
            headEnd = buffer.range(of: separator)
        }

        guard let headEnd else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw ParseFailure(status: 400, message: "Malformed request line")
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard requestParts.count >= 2 else {
            throw ParseFailure(status: 400, message: "Malformed request line")
        }
        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        if header("Transfer-Encoding", in: headers) != nil {
            throw ParseFailure(status: 411, message: "Transfer-Encoding is not supported; use Content-Length")
        }

        var body = Data(buffer[headEnd.upperBound...])
        let contentLength: Int
        if let rawContentLength = header("Content-Length", in: headers) {
            guard let parsedContentLength = Int(rawContentLength), parsedContentLength >= 0 else {
                throw ParseFailure(status: 400, message: "Invalid Content-Length")
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }
        if contentLength > maximumBodyBytes {
            throw ParseFailure(status: 413, message: "Request body too large")
        }
        while body.count < contentLength {
            guard let chunk = try await receive(on: connection) else { break }
            body.append(chunk)
            if body.count > maximumBodyBytes {
                throw ParseFailure(status: 413, message: "Request body too large")
            }
        }
        if body.count > contentLength {
            // contentLength is validated non-negative above, so prefix's count
            // can never go negative (Data.prefix traps on a negative count).
            body = body.prefix(contentLength)
        }

        return ParsedRequest(
            method: method,
            path: path,
            headers: headers,
            body: body.isEmpty ? nil : body
        )
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    once.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    once.resume(returning: data)
                } else if isComplete {
                    once.resume(returning: nil)
                } else {
                    once.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Response serialization

    private static func send(_ response: MCP.HTTPResponse, on connection: NWConnection) async {
        await send(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            on: connection
        )
    }

    private static func send(status: Int, body: String, on connection: NWConnection) async {
        await send(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(body.utf8),
            on: connection
        )
    }

    private static func send(
        status: Int,
        headers: [String: String],
        body: Data,
        on connection: NWConnection
    ) async {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key })
        where name.lowercased() != "content-length" && name.lowercased() != "connection" {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            connection.send(
                content: payload,
                completion: .contentProcessed { _ in once.resume(returning: ()) }
            )
        }
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

/// Serializes actor methods across suspension points in listener lifecycle work.
private final class LifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private let onWait: @Sendable () -> Void
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(onWait: @escaping @Sendable () -> Void) {
        self.onWait = onWait
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock {
                guard !isLocked else {
                    waiters.append(continuation)
                    return false
                }
                isLocked = true
                return true
            }
            if acquired {
                continuation.resume()
            } else {
                onWait()
            }
        }
    }

    func release() {
        let next = lock.withLock {
            guard !waiters.isEmpty else {
                isLocked = false
                return nil as CheckedContinuation<Void, Never>?
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// Wraps a continuation so callback-based Network.framework APIs (which can
/// fire more than once) can only resume it a single time.
private final class ResumeOnce<T, E: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, E>?

    init(_ continuation: CheckedContinuation<T, E>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: E) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, E>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
