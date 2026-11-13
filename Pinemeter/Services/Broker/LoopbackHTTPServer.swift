//
//  LoopbackHTTPServer.swift
//  Pinemeter
//
//  Minimal HTTP/1.1 front-end for the MCP server transport.
//
//  The MCP SDK's server transports never touch sockets: they take a
//  framework-agnostic `MCP.HTTPRequest` and return an `MCP.HTTPResponse`.
//  This actor owns the socket half — an `NWListener` bound explicitly to one
//  interface — parses just enough HTTP/1.1 to build that request, and
//  serializes the response back. The bind host defaults to loopback; binding
//  the whole machine is an explicit opt-in the caller has to ask for.
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

    /// The default (and historical) bind interface: this Mac only.
    static let loopbackHost = "127.0.0.1"

    /// Binds every interface. Only ever passed by an explicit user opt-in
    /// (`BrokerNetworkAccess.network`), never as a default.
    static let allInterfacesHost = "0.0.0.0"

    /// Largest request head (request line + headers) accepted.
    private static let maximumHeaderBytes = 64 * 1024
    /// Largest request body accepted.
    private static let maximumBodyBytes = 1024 * 1024
    /// Maximum accepted connections allowed to occupy tasks at once.
    private static let maximumConnections = 32
    /// Default per-connection budget to deliver a complete request. A peer
    /// that opens a socket and never finishes a request is force-closed
    /// instead of leaking a `Task` for the life of the process.
    static let defaultReadTimeout: TimeInterval = 10

    private static let logger = os.Logger(subsystem: "com.pinemeter", category: "LoopbackHTTPServer")
    private static let queue = DispatchQueue(label: "com.pinemeter.broker.loopback")

    private let requestedPort: UInt16
    private let bindHost: String
    private let path: String
    private let authorize: @Sendable (_ headers: [String: String], _ isLoopbackPeer: Bool) -> Bool
    private let readTimeout: TimeInterval
    private let listenerQueue: DispatchQueue
    private let onListenerStart: @Sendable () -> Void
    // Internal test seam for deterministic watchdog ordering; production leaves it idle.
    enum ReadCheckpoint { case beforeHandler, beforeEarlyReply, finished }
    private let onReadCheckpoint: @Sendable (ReadCheckpoint, @Sendable () -> Void) -> Void
    private let handlerFactory: HandlerFactory
    private let lifecycleGate: LifecycleGate

    private var listener: NWListener?
    private var handler: LoopbackRequestHandler?
    private var activeConnections = 0
    private(set) var resolvedPort: UInt16?

    /// - Parameters:
    ///   - port: Port to bind. `0` requests an ephemeral port (used by tests).
    ///   - bindHost: Interface to bind. Defaults to loopback; pass
    ///     ``allInterfacesHost`` to accept connections from other machines.
    ///   - path: The single routed path; anything else answers 404.
    ///   - authorize: Called with every matched request's headers and whether
    ///     the peer is on loopback. Returning `false` answers 401 without the
    ///     request ever reaching the handler. Defaults to allowing everything,
    ///     which is the loopback-only behaviour this server shipped with.
    ///   - readTimeout: Per-connection budget to deliver a complete request
    ///     before the socket is force-closed. Injectable so tests exercise the
    ///     behavior quickly; production uses `defaultReadTimeout`.
    ///   - onReadCheckpoint: Test hook receiving the watchdog expiry action at
    ///     fixed points in request serving. Defaults to doing nothing.
    ///   - handlerFactory: Builds the handler once the bound port is known.
    init(
        port: UInt16,
        bindHost: String = LoopbackHTTPServer.loopbackHost,
        path: String = "/mcp",
        readTimeout: TimeInterval = LoopbackHTTPServer.defaultReadTimeout,
        listenerQueue: DispatchQueue = LoopbackHTTPServer.queue,
        onListenerStart: @escaping @Sendable () -> Void = {},
        onLifecycleWait: @escaping @Sendable () -> Void = {},
        onReadCheckpoint: @escaping @Sendable (ReadCheckpoint, @Sendable () -> Void) -> Void = { _, _ in },
        authorize: @escaping @Sendable (_ headers: [String: String], _ isLoopbackPeer: Bool) -> Bool = { _, _ in true },
        handlerFactory: @escaping HandlerFactory
    ) {
        self.requestedPort = port
        self.bindHost = bindHost
        self.path = path
        self.authorize = authorize
        self.readTimeout = readTimeout
        self.listenerQueue = listenerQueue
        self.onListenerStart = onListenerStart
        self.onReadCheckpoint = onReadCheckpoint
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
            host: NWEndpoint.Host(bindHost),
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
            Self.logger.info(
                "Broker listener ready on \(self.bindHost, privacy: .public):\(port, privacy: .public)"
            )
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
        guard activeConnections < Self.maximumConnections else {
            Self.logger.info("Closing broker connection: connection limit reached")
            connection.cancel()
            return
        }
        activeConnections += 1
        defer { activeConnections -= 1 }

        await Self.serve(
            connection,
            path: path,
            handler: handler,
            readTimeout: readTimeout,
            onReadCheckpoint: onReadCheckpoint,
            authorize: authorize
        )
    }

    private static func serve(
        _ connection: NWConnection,
        path: String,
        handler: LoopbackRequestHandler?,
        readTimeout: TimeInterval,
        onReadCheckpoint: @Sendable (ReadCheckpoint, @Sendable () -> Void) -> Void,
        authorize: @Sendable (_ headers: [String: String], _ isLoopbackPeer: Bool) -> Bool
    ) async {
        connection.start(queue: Self.queue)
        defer { connection.cancel() }

        // A peer that opens the socket and never finishes a request must not
        // leak this Task for the life of the process: force-close after the
        // read budget expires. Reading and the watchdog atomically claim the
        // same state: only a timeout that wins while still reading may cancel
        // the connection, so a slow handler is never cut off by the watchdog.
        let readState = RequestReadState()
        let expire: @Sendable () -> Void = {
            guard readState.timeOut() else { return }
            Self.logger.info("Closing broker connection: request not fully received within the read timeout")
            connection.cancel()
        }
        let watchdog = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(readTimeout, 0) * 1_000_000_000))
            } catch {
                return
            }
            expire()
        }
        defer {
            watchdog.cancel()
            onReadCheckpoint(.finished, expire)
        }

        let parsed: ParsedRequest?
        do {
            parsed = try await readRequestHead(from: connection)
        } catch let error as ParseFailure {
            guard readState.finishReading() else { return }
            watchdog.cancel()
            await send(status: error.status, body: error.message, on: connection)
            return
        } catch {
            Self.logger.debug("Broker connection read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let request = parsed else { return }

        guard request.path == path else {
            guard readState.finishReading() else { return }
            watchdog.cancel()
            onReadCheckpoint(.beforeEarlyReply, expire)
            await send(status: 404, body: "Not Found", on: connection)
            return
        }

        guard authorize(request.headers, isLoopbackPeer(of: connection)) else {
            guard readState.finishReading() else { return }
            watchdog.cancel()
            onReadCheckpoint(.beforeEarlyReply, expire)
            // Deliberately says nothing about which header was wrong, and
            // never logs the presented value: the response and the log line
            // must not become an oracle for key material.
            Self.logger.info("Rejected an unauthorized broker request")
            await send(
                status: 401,
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "WWW-Authenticate": "Bearer",
                ],
                body: Data("Unauthorized".utf8),
                on: connection
            )
            return
        }

        guard let handler else {
            guard readState.finishReading() else { return }
            watchdog.cancel()
            onReadCheckpoint(.beforeEarlyReply, expire)
            await send(status: 503, body: "Broker not ready", on: connection)
            return
        }

        let body: Data?
        do {
            body = try await readBody(for: request, from: connection)
        } catch let error as ParseFailure {
            guard readState.finishReading() else { return }
            watchdog.cancel()
            await send(status: error.status, body: error.message, on: connection)
            return
        } catch {
            Self.logger.debug("Broker connection read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        onReadCheckpoint(.beforeHandler, expire)
        // Claim completion before the handler; a timeout winner forbids it.
        guard readState.finishReading() else { return }
        watchdog.cancel()

        let response = await handler.handle(
            MCP.HTTPRequest(
                method: request.method,
                headers: request.headers,
                body: body,
                path: request.path
            )
        )
        await send(response, on: connection)
    }

    /// Exactly one side can claim the end of the request's read budget.
    final class RequestReadState: @unchecked Sendable {
        private enum State { case reading, done, timedOut }
        private let lock = NSLock()
        private var state: State = .reading

        func finishReading() -> Bool { transition(to: .done) }
        func timeOut() -> Bool { transition(to: .timedOut) }

        private func transition(to next: State) -> Bool {
            lock.withLock {
                guard state == .reading else { return false }
                state = next
                return true
            }
        }
    }

    /// Whether the connection's remote peer is on the loopback interface.
    ///
    /// Fails closed: an endpoint shape this cannot read is treated as remote,
    /// so an unrecognized peer is asked for a key rather than waved through
    /// as local.
    private static func isLoopbackPeer(of connection: NWConnection) -> Bool {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return address.isLoopback
            case .ipv6(let address):
                if address.isLoopback { return true }
                // An IPv4 client reaching an IPv6 listener arrives as
                // ::ffff:127.0.0.1, which is loopback in every sense that
                // matters here.
                if let mapped = address.asIPv4 { return mapped.isLoopback }
                return false
            case .name(let name, _):
                return name.lowercased() == "localhost"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Request parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int
        let bufferedBody: Data
        /// The peer half-closed while the head was read, so no more body bytes can arrive.
        let peerClosed: Bool
    }

    private struct ParseFailure: Error {
        let status: Int
        let message: String
    }

    private static func readRequestHead(from connection: NWConnection) async throws -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        var peerClosed = false

        while headEnd == nil {
            guard !peerClosed, let chunk = try await receive(on: connection) else {
                // Peer closed before a complete request head arrived.
                return nil
            }
            buffer.append(chunk.data)
            peerClosed = chunk.isComplete
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
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if name == "content-length", headers[name] != nil {
                throw ParseFailure(status: 400, message: "Duplicate Content-Length")
            }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            throw ParseFailure(status: 411, message: "Transfer-Encoding is not supported; use Content-Length")
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
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

        return ParsedRequest(
            method: method,
            path: path,
            headers: headers,
            contentLength: contentLength,
            bufferedBody: Data(buffer[headEnd.upperBound...]),
            peerClosed: peerClosed
        )
    }

    private static func readBody(for request: ParsedRequest, from connection: NWConnection) async throws -> Data? {
        var body = request.bufferedBody
        let contentLength = request.contentLength
        var peerClosed = request.peerClosed
        while body.count < contentLength {
            // A half-closed peer can send nothing more; receiving again would
            // fail with an error instead of reporting the end of the stream.
            guard !peerClosed, let chunk = try await receive(on: connection) else {
                throw ParseFailure(status: 400, message: "Incomplete request body")
            }
            body.append(chunk.data)
            peerClosed = chunk.isComplete
            if body.count > maximumBodyBytes {
                throw ParseFailure(status: 413, message: "Request body too large")
            }
        }
        if body.count > contentLength {
            // contentLength is validated non-negative above, so prefix's count
            // can never go negative (Data.prefix traps on a negative count).
            body = body.prefix(contentLength)
        }

        return body.isEmpty ? nil : body
    }

    /// One receive. `nil` means the peer closed with no data; otherwise
    /// `isComplete` reports a half-close that arrived together with the data.
    private static func receive(on connection: NWConnection) async throws -> (data: Data, isComplete: Bool)? {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    once.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    once.resume(returning: (data, isComplete))
                } else if isComplete {
                    once.resume(returning: nil)
                } else {
                    once.resume(returning: (Data(), false))
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
        case 401: return "Unauthorized"
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
