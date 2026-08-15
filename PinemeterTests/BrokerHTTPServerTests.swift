//
//  BrokerHTTPServerTests.swift
//  PinemeterTests
//
//  End-to-end integration test for the broker's loopback MCP endpoint:
//  a real URLSession client against a real NWListener on an ephemeral port.
//

import Network
import XCTest
@testable import Pinemeter

final class BrokerHTTPServerTests: XCTestCase {
    private var server: LoopbackHTTPServer!
    private var port: UInt16 = 0
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Every store here is pointed at a hermetic temp directory: the real
        // Application Support / ~/.model-broker / ~/.t3 paths must never be
        // touched by tests, whether or not this machine happens to have a
        // real trixie-box cooldown or T3 pointer file on disk.
        let cooldownStore = BrokerCooldownStore(
            storeDirectory: tempDirectory,
            cliCooldownsURL: tempDirectory.appendingPathComponent("cli-cooldowns.json")
        )
        let livenessChecker = T3LivenessChecker(
            pointerFileURL: tempDirectory.appendingPathComponent("server-runtime.json")
        )
        server = BrokerMCPServer.makeLoopbackServer(
            broker: BrokerService(policy: .default, cooldownStore: cooldownStore, livenessChecker: livenessChecker),
            port: 0,
            version: "test"
        )
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_initializeListToolsAndPick_completesOverLoopback() async throws {
        let initialize = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "PinemeterTests", "version": "1.0"],
            ],
        ])
        XCTAssertEqual(initialize.status, 200)
        let serverInfo = try XCTUnwrap(
            (initialize.json?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        )
        XCTAssertEqual(serverInfo["name"] as? String, BrokerMCPServer.serverName)

        let initialized = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ])
        XCTAssertEqual(initialized.status, 202)

        let listTools = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:],
        ])
        XCTAssertEqual(listTools.status, 200)
        let tools = try XCTUnwrap(
            (listTools.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        XCTAssertTrue(tools.contains { $0["name"] as? String == "pick" },
                      "tools/list must advertise the pick tool, got \(tools)")

        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(toolNames, ["pick", "status", "down", "up", "refresh"],
                       "tools/list must advertise exactly the five D-08 tools (Test 6)")

        let pick = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "pick",
                "arguments": ["role": "planning", "caller": "claude-code"],
            ],
        ])
        XCTAssertEqual(pick.status, 200)

        let decision = try decodeDecision(from: pick)
        XCTAssertEqual(decision["caller"] as? String, "claude-code",
                       "the decision must echo the caller it filtered for (D-01)")
        XCTAssertEqual(decision["role"] as? String, "planning")
        XCTAssertEqual(decision["route"] as? String, "native")
        XCTAssertEqual(decision["model"] as? String, "native/claude-fable-5")
        XCTAssertEqual(decision["agentModel"] as? String, "fable")
        let invocation = try XCTUnwrap(decision["invocation"] as? [String: Any])
        XCTAssertEqual(invocation["kind"] as? String, "agent")
        XCTAssertEqual(invocation["model"] as? String, "fable")
    }

    func test_twoIndependentClientsCanInitializeConsecutively() async throws {
        for (id, clientName) in [(101, "FirstClient"), (102, "SecondClient")] {
            let response = try await send(jsonRPC: [
                "jsonrpc": "2.0",
                "id": id,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": clientName, "version": "1.0"],
                ],
            ])

            XCTAssertEqual(response.status, 200)
            XCTAssertNil(response.json?["error"], "\(clientName) initialize failed: \(String(describing: response.json))")
            let result = try XCTUnwrap(response.json?["result"] as? [String: Any])
            let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
            XCTAssertEqual(serverInfo["name"] as? String, BrokerMCPServer.serverName)
        }
    }

    func test_pickWithoutCallerArgument_echoesTheDefaultCaller() async throws {
        let pick = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "pick", "arguments": ["role": "execution"]],
        ])
        XCTAssertEqual(pick.status, 200)

        let decision = try decodeDecision(from: pick)
        XCTAssertEqual(decision["caller"] as? String, BrokerPolicy.defaultCaller)
        // No T3 liveness has been pushed into the service, so the top-ranked
        // `t3/gpt-5.6-sol` lane fails CLOSED and execution falls to codex.
        XCTAssertEqual(decision["route"] as? String, "codex")
    }

    func test_pickWithUnknownRole_returnsToolErrorListingKnownRoles() async throws {
        let pick = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "pick", "arguments": ["role": "nonsense"]],
        ])
        XCTAssertEqual(pick.status, 200)

        let result = try XCTUnwrap(pick.json?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("nonsense"), "error should name the unknown role, got: \(text)")
        XCTAssertTrue(text.contains("planning"), "error should list known roles, got: \(text)")
    }

    func test_downPickUpSequence_changesThenRestoresPickAvailability() async throws {
        let pickPlanning: () async throws -> [String: Any] = {
            let response = try await self.send(jsonRPC: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "pick", "arguments": ["role": "planning"]],
            ])
            return try self.decodeDecision(from: response)
        }

        let before = try await pickPlanning()
        XCTAssertEqual(before["model"] as? String, "native/claude-fable-5")

        let down = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "down", "arguments": ["target": "native/claude-fable-5", "minutes": 30]],
        ])
        XCTAssertEqual(down.status, 200)

        let cooled = try await pickPlanning()
        XCTAssertNotEqual(cooled["model"] as? String, "native/claude-fable-5",
                          "the cooled candidate must be skipped")

        let up = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "up", "arguments": ["target": "native/claude-fable-5"]],
        ])
        XCTAssertEqual(up.status, 200)

        let after = try await pickPlanning()
        XCTAssertEqual(after["model"] as? String, "native/claude-fable-5",
                       "up must restore the candidate's availability")
    }

    func test_statusAndRefresh_areCallableOverMCP() async throws {
        let status = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "status", "arguments": [:]],
        ])
        let statusResult = try XCTUnwrap(status.json?["result"] as? [String: Any])
        XCTAssertEqual(statusResult["isError"] as? Bool, false)
        let statusContent = try XCTUnwrap(statusResult["content"] as? [[String: Any]])
        let statusText = try XCTUnwrap(statusContent.first?["text"] as? String)
        let statusPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(statusText.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(statusPayload["roles"])

        let refresh = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "refresh", "arguments": [:]],
        ])
        let refreshResult = try XCTUnwrap(refresh.json?["result"] as? [String: Any])
        XCTAssertEqual(refreshResult["isError"] as? Bool, false)
        let refreshContent = try XCTUnwrap(refreshResult["content"] as? [[String: Any]])
        XCTAssertEqual(refreshContent.first?["text"] as? String, "refreshed")
    }

    func test_downWithOutOfRangeMinutes_returnsInvalidParamsAndServerSurvives() async throws {
        let down = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "down",
                "arguments": ["target": "native", "minutes": 1e100],
            ],
        ])

        XCTAssertEqual(down.status, 200)
        let error = try XCTUnwrap(down.json?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        try await assertServesSuccessfully(on: port)
    }

    // MARK: - DNS-rebinding defence (D-07)

    func test_postWithNonLocalOrigin_isRejectedBeforeTheToolRuns() async throws {
        let response = try await send(
            jsonRPC: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "pick", "arguments": ["role": "planning"]],
            ],
            extraHeaders: ["Origin": "http://evil.example"]
        )

        XCTAssertGreaterThanOrEqual(response.status, 400,
                                    "a non-local Origin must be rejected, got \(response.status)")
        XCTAssertNil(response.json?["result"], "the tool handler must not have run")
    }

    func test_postWithLoopbackOrigin_isAccepted() async throws {
        let response = try await send(
            jsonRPC: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "pick", "arguments": ["role": "planning"]],
            ],
            extraHeaders: ["Origin": "http://127.0.0.1:\(port)"]
        )

        XCTAssertEqual(response.status, 200)
    }

    // MARK: - Transport shape

    func test_getOnEndpoint_returns405() async throws {
        let response = try await perform(method: "GET", path: BrokerMCPServer.endpointPath, body: nil)
        XCTAssertEqual(response.status, 405,
                       "stateless streamable HTTP is POST-only; 405 on GET is spec-compliant")
    }

    func test_postToUnknownPath_returns404() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:],
        ])
        let response = try await perform(method: "POST", path: "/not-mcp", body: body)
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - Hardening (T-07-05, T-07-06)

    /// A declared Content-Length over the 1 MB cap is rejected with 413
    /// immediately after the headers, before the (never-sent) oversized body
    /// would need to be buffered.
    func test_oversizedContentLength_returns413() async throws {
        let connection = try await openRawConnection(port: port)
        defer { connection.cancel() }

        let head = "POST \(BrokerMCPServer.endpointPath) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Accept: application/json, text/event-stream\r\n"
            + "Content-Length: 2000000\r\n\r\n"
        try await sendRaw(head, on: connection)

        let responseData = try await receiveRaw(on: connection, timeout: 5) ?? Data()
        let responseText = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(
            responseText.hasPrefix("HTTP/1.1 413"),
            "expected 413 for an oversized declared Content-Length, got: \(responseText.prefix(80))"
        )
    }

    /// A negative declared Content-Length must be rejected with 400 before it
    /// ever reaches `Data.prefix(_:)`, which traps on a negative count — this
    /// would otherwise be a one-request crash of the whole app.
    func test_negativeContentLength_returns400() async throws {
        let connection = try await openRawConnection(port: port)
        defer { connection.cancel() }

        let head = "POST \(BrokerMCPServer.endpointPath) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Accept: application/json, text/event-stream\r\n"
            + "Content-Length: -1\r\n\r\n"
        try await sendRaw(head, on: connection)

        let responseData = try await receiveRaw(on: connection, timeout: 5) ?? Data()
        let responseText = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(
            responseText.hasPrefix("HTTP/1.1 400"),
            "expected 400 for a negative declared Content-Length, got: \(responseText.prefix(80))"
        )

        // The server process itself must have survived handling the request
        // above: a fresh connection still gets served normally.
        try await assertServesSuccessfully(on: port)
    }

    /// A non-numeric declared Content-Length must be rejected with 400 rather
    /// than silently falling back to a 0-length body.
    func test_nonNumericContentLength_returns400() async throws {
        let connection = try await openRawConnection(port: port)
        defer { connection.cancel() }

        let head = "POST \(BrokerMCPServer.endpointPath) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Accept: application/json, text/event-stream\r\n"
            + "Content-Length: abc\r\n\r\n"
        try await sendRaw(head, on: connection)

        let responseData = try await receiveRaw(on: connection, timeout: 5) ?? Data()
        let responseText = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(
            responseText.hasPrefix("HTTP/1.1 400"),
            "expected 400 for a non-numeric declared Content-Length, got: \(responseText.prefix(80))"
        )
    }

    /// stop() awaits the listener's `.cancelled` state before returning
    /// (Pitfall 5), so a follow-up start() bound to the SAME port never races
    /// a not-yet-torn-down bind.
    func test_stopThenStart_twiceOnTheSamePort_bothCyclesServeSuccessfully() async throws {
        let first = BrokerMCPServer.makeLoopbackServer(
            broker: BrokerService(policy: .default), port: 0, version: "test"
        )
        let firstPort = try await first.start()
        try await assertServesSuccessfully(on: firstPort)
        await first.stop()

        let restarted = BrokerMCPServer.makeLoopbackServer(
            broker: BrokerService(policy: .default), port: firstPort, version: "test"
        )
        let secondPort = try await restarted.start()
        XCTAssertEqual(secondPort, firstPort, "the restart must rebind the exact same port")
        try await assertServesSuccessfully(on: secondPort)
        await restarted.stop()
    }

    func test_stopOverlappingRealListenerStart_completesAndAllowsRestart() async {
        let listenerQueue = DispatchQueue(label: "com.pinemeter.tests.suspended-listener")
        listenerQueue.suspend()
        let startEntered = expectation(description: "listener start entered")
        startEntered.assertForOverFulfill = false
        let stopQueued = expectation(description: "stop queued behind listener start")
        let completed = expectation(description: "overlapping start and stop completed")
        let server = LoopbackHTTPServer(
            port: 0,
            listenerQueue: listenerQueue,
            onListenerStart: { startEntered.fulfill() },
            onLifecycleWait: { stopQueued.fulfill() }
        ) { _ in
            LoopbackRequestHandler(handle: { _ in .ok() })
        }

        let startTask = Task { try await server.start() }
        let startWaitResult = await XCTWaiter().fulfillment(of: [startEntered], timeout: 1)
        guard startWaitResult == .completed else {
            listenerQueue.resume()
            startTask.cancel()
            _ = await startTask.result
            XCTFail("listener start did not enter before timeout")
            return
        }

        let stopTask = Task { await server.stop() }
        let stopWaitResult = await XCTWaiter().fulfillment(of: [stopQueued], timeout: 1)
        guard stopWaitResult == .completed else {
            listenerQueue.resume()
            startTask.cancel()
            _ = await startTask.result
            await stopTask.value
            XCTFail("stop did not queue behind listener start before timeout")
            return
        }
        listenerQueue.resume()

        Task {
            defer { completed.fulfill() }
            await stopTask.value

            do {
                _ = try await startTask.value
            } catch {
                XCTFail("the serialized start must complete before stop: \(error)")
            }

            do {
                let restartedPort = try await server.start()
                try await self.assertServesSuccessfully(on: restartedPort)
                await server.stop()
            } catch {
                XCTFail("the listener must restart after overlapping stop: \(error)")
            }
        }

        await fulfillment(of: [completed], timeout: 5)
    }

    /// A connection that opens the socket and never completes a request must
    /// be force-closed after the read budget, not leak the accepting Task.
    func test_connectionWithoutACompleteRequest_isClosedAfterTheReadTimeout() async throws {
        let readTimeout: TimeInterval = 0.3
        let server = LoopbackHTTPServer(port: 0, path: "/mcp", readTimeout: readTimeout) { _ in
            LoopbackRequestHandler(handle: { _ in .ok() })
        }
        let watchdogPort = try await server.start()
        defer { Task { await server.stop() } }

        let connection = try await openRawConnection(port: watchdogPort)
        defer { connection.cancel() }
        // A request line with no terminating blank line: never a complete head.
        try await sendRaw("GET /mcp HTTP/1.1\r\n", on: connection)

        let dataAfterTimeout = try await receiveRaw(on: connection, timeout: readTimeout + 2)
        XCTAssertNil(
            dataAfterTimeout,
            "the connection must be force-closed (EOF/no data) once the read timeout elapses"
        )
    }

    // MARK: - Helpers

    private struct Response {
        let status: Int
        let data: Data
        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func decodeDecision(from response: Response) throws -> [String: Any] {
        let result = try XCTUnwrap(response.json?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "pick returned a tool error: \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "pick content was not JSON: \(text)"
        )
    }

    private func send(
        jsonRPC message: [String: Any],
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        let body = try JSONSerialization.data(withJSONObject: message)
        return try await perform(
            method: "POST",
            path: BrokerMCPServer.endpointPath,
            body: body,
            extraHeaders: extraHeaders
        )
    }

    private func perform(
        method: String,
        path: String,
        body: Data?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        return Response(status: status, data: data)
    }

    /// A normal `tools/list` POST against `port` must succeed — used to prove
    /// a server (re)bound to a given port is actually serving traffic.
    private func assertServesSuccessfully(
        on port: UInt16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertEqual(status, 200, file: file, line: line)
    }

    // MARK: - Raw socket helpers (byte-level control the URLSession-based
    // `perform` cannot give: a declared Content-Length that lies about the
    // body, or a request that never completes its head).

    private func openRawConnection(port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "BrokerHTTPServerTests", code: 1)
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = RawConnectionResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    once.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        return connection
    }

    private func sendRaw(_ text: String, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    private enum RawReceiveOutcome: Sendable {
        case data(Data)
        case closed
        case timedOut
    }

    /// Waits up to `timeout` for at least one chunk of data, or `nil` if the
    /// peer closes/times out without sending anything.
    private func receiveRaw(on connection: NWConnection, timeout: TimeInterval) async throws -> Data? {
        try await withThrowingTaskGroup(of: RawReceiveOutcome.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RawReceiveOutcome, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                        data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: .data(data))
                        } else if isComplete {
                            continuation.resume(returning: .closed)
                        } else {
                            continuation.resume(returning: .data(Data()))
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else { return nil }
            switch outcome {
            case .data(let data): return data
            case .closed, .timedOut: return nil
            }
        }
    }
}

/// A tiny once-guard for raw `NWConnection` test helpers above, mirroring
/// `LoopbackHTTPServer`'s internal `ResumeOnce` (which is `private` to that
/// file and not visible here).
private final class RawConnectionResumeOnce<T, E: Error>: @unchecked Sendable {
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
