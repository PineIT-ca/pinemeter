//
//  GoldenWireFixtureTests.swift
//  PinemeterTests
//
//  Records the DAEMON-01 half of the wire contract: what the real Mac stack
//  (`LoopbackHTTPServer` + `BrokerMCPServer` + swift-sdk) puts on the socket
//  for a fixed list of requests. The Go daemon replays these fixtures in
//  `pinemeterd/internal/mcpd/wire_golden_test.go` (Plan 12-08); the Mac app
//  cannot run in CI, so its side of the contract is a committed recording.
//
//  Everything here goes over a raw TCP socket rather than `URLSession`: the
//  corpus has to carry requests URLSession would refuse to send (a
//  `Content-Length` that lies about the body, `Transfer-Encoding: chunked`,
//  a missing `Accept`), and it has to record the response bytes as they
//  arrive rather than as a cooked `HTTPURLResponse`.
//
//  Determinism (see `golden/README.md` § `wire/`):
//  - fixed clock (`Self.clock`), so cooldown deadlines, oracle age and audit
//    timestamps never read the wall clock;
//  - counting id generator (`wire-0001`, `wire-0002`, ...), so `decision_id`
//    is stable and `report` can name a decision by literal;
//  - the bundled policy and empty hermetic stores;
//  - the ephemeral port is replaced by the `<PORT>` token everywhere it
//    appears, so the Go side can substitute the port it actually bound.
//
//  Ownership (see `golden/README.md` § Ownership): this class owns
//  `golden/wire/` and wipes only that directory.
//
//  Recording is opt-in. Without an export directory both tests skip and the
//  working tree is untouched (T-12-24).
//

import Foundation
import MCP
import Network
import XCTest
@testable import Pinemeter

final class GoldenWireFixtureTests: XCTestCase {

    // MARK: - Fixture constants

    /// The single instant every wire fixture is recorded at, shared with the
    /// Phase 11 corpus so one Go clock serves both.
    private static let clock = Date(timeIntervalSince1970: 1_700_000_000)

    /// Obviously-fake key literal (T-12-25). It is not a credential, has
    /// never been a credential, and exists so the keyed fixture set can carry
    /// a realistic `Authorization` header without carrying a real one.
    static let fixtureAPIKey = "pm_FIXTUREKEY_000000000000000000000000000000"

    /// The wrong-key case needs a second literal of the same obvious shape.
    static let fixtureWrongAPIKey = "pm_NOTTHEKEY_0000000000000000000000000000000"

    /// The token every occurrence of the bound port is rewritten to.
    private static let portToken = "<PORT>"

    /// Latest protocol version the Swift SDK negotiates.
    private static let protocolVersion = "2025-11-25"

    /// `initialize` reports it, so the recorder pins it and the Go side masks
    /// `serverInfo.version` anyway.
    private static let serverVersion = "test"

    // MARK: - Per-set recording state

    private var server: LoopbackHTTPServer!
    private var port: UInt16 = 0
    private var tempDirectory: URL!
    private var setName = ""
    private var recordedCases: [String] = []
    private var nextRequestID = 1

    // MARK: - Manifest accumulation
    //
    // XCTest runs each method on its own instance, so the ordered case list
    // per set is collected in class state and the manifest is rewritten at
    // the end of each test. `manifestSetOrder` fixes the emission order so
    // the file does not depend on which method XCTest ran first.

    private static let manifestSetOrder = ["loopback", "keyed"]
    nonisolated(unsafe) private static var recordedSets: [String: [String]] = [:]
    nonisolated(unsafe) private static var wiped = false

    private static var wireDirectory: URL {
        GoldenFixture.goldenDirectory.appendingPathComponent("wire")
    }

    /// Wiped once per process so a deleted case drops its two files. Scoped
    /// to `golden/wire` only: every other family under `golden/` belongs to
    /// another exporter.
    private static func wipeOnce() throws {
        guard !wiped else { return }
        wiped = true
        recordedSets = [:]
        try GoldenFixture.wipe(wireDirectory)
    }

    // MARK: - Tests

    func test_recordLoopbackWireFixtures() async throws {
        guard GoldenFixture.exportDirectory() != nil else {
            throw XCTSkip(
                "no export directory; set \(GoldenFixture.exportDirectoryEnvironmentKey) to record"
            )
        }
        try Self.wipeOnce()
        try await startLoopbackSet()
        try await recordLoopbackCases()
        try finishSet()
    }

    func test_recordKeyedWireFixtures() async throws {
        guard GoldenFixture.exportDirectory() != nil else {
            throw XCTSkip(
                "no export directory; set \(GoldenFixture.exportDirectoryEnvironmentKey) to record"
            )
        }
        try Self.wipeOnce()
        try await startKeyedSet()
        try await recordKeyedCases()
        try finishSet()
    }

    // MARK: - Server construction

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenWireFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Every store points at a hermetic temp directory: the real Application
    /// Support, `~/.model-broker` and `~/.t3` paths must never reach a
    /// committed fixture (T-12-25).
    private func makeBroker(directory: URL) -> BrokerService {
        let ids = WireIDCounter()
        let clock = Self.clock
        return BrokerService(
            policy: .default,
            // The cooldown store keeps its own clock; leaving it on the wall
            // clock would make every `down` deadline in `status` churn on
            // each export.
            cooldownStore: BrokerCooldownStore(
                storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("cli-cooldowns.json"),
                now: { clock }
            ),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: T3LivenessChecker(
                pointerFileURL: directory.appendingPathComponent("server-runtime.json")
            ),
            now: { clock },
            idGenerator: { ids.next() }
        )
    }

    private func startLoopbackSet() async throws {
        setName = "loopback"
        tempDirectory = try makeTempDirectory()
        let broker = makeBroker(directory: tempDirectory)
        server = BrokerMCPServer.makeLoopbackServer(
            broker: broker,
            port: 0,
            version: Self.serverVersion
        )
        port = try await server.start()
        // The daemon reports `running: true, port: <bound>`; the Mac only
        // does once AppModel pushes the listener's state. Push it here or
        // every recorded `status` would say `running: false` with no port,
        // and the Go side could never match it (DAEMON-04).
        await broker.updateServerState(.running(port: port))
        addTeardownBlock { [server] in await server?.stop() }
    }

    /// The keyed set needs `NetworkHostValidator` (so the LAN-shaped Host and
    /// public Host cases mean something) but must not bind `0.0.0.0`: an
    /// all-interfaces bind from a test binary raises the macOS firewall
    /// prompt, which would hang an unattended export. This reproduces
    /// `BrokerMCPServer.makeLoopbackServer` with the bind host pinned to
    /// loopback and the validator selected as if the listener were on the
    /// network, which is exactly the combination the fixtures describe.
    private func startKeyedSet() async throws {
        setName = "keyed"
        tempDirectory = try makeTempDirectory()
        let broker = makeBroker(directory: tempDirectory)
        let accessPolicy = BrokerAccessPolicy(
            networkAccess: .network,
            apiKeyMode: .all,
            apiKey: Self.fixtureAPIKey
        )
        let version = Self.serverVersion
        server = LoopbackHTTPServer(
            port: 0,
            bindHost: LoopbackHTTPServer.loopbackHost,
            path: BrokerMCPServer.endpointPath,
            authorize: { headers, isLoopbackPeer in
                accessPolicy.authorizes(headers: headers, isLoopbackPeer: isLoopbackPeer)
            }
        ) { resolvedPort in
            LoopbackRequestHandler { request in
                let mcpServer = BrokerMCPServer(
                    broker: broker,
                    port: resolvedPort,
                    version: version,
                    networkAccess: .network
                )
                do {
                    try await mcpServer.start()
                } catch {
                    await mcpServer.stop()
                    return .error(
                        statusCode: 500,
                        .internalError("Failed to start broker MCP server")
                    )
                }
                let response = await mcpServer.handle(request)
                await mcpServer.stop()
                return response
            }
        }
        port = try await server.start()
        await broker.updateServerState(.running(port: port))
        addTeardownBlock { [server] in await server?.stop() }
    }

    // MARK: - Loopback case list
    //
    // The order is part of the contract: cooldowns, audit records and
    // `recentPicksCount` accumulate, so `status_final` is only reproducible
    // if everything before it ran in this sequence.

    private func recordLoopbackCases() async throws {
        let initialize = try await recordJSONRPC("initialize", method: "initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "pinemeter-wire-fixtures", "version": "1.0"],
        ])
        XCTAssertEqual(initialize.status, 200, "initialize must succeed before anything is recorded")

        let initialized = try await recordNotification(
            "notifications_initialized",
            method: "notifications/initialized"
        )
        XCTAssertEqual(initialized.status, 202)

        let tools = try await recordJSONRPC("tools_list", method: "tools/list", params: [:])
        XCTAssertEqual(tools.status, 200)

        _ = try await recordJSONRPC("prompts_list", method: "prompts/list", params: [:])
        _ = try await recordJSONRPC("prompts_get_configure", method: "prompts/get", params: [
            "name": BrokerSetupPrompt.promptName,
        ])

        _ = try await recordTool("status_initial", tool: "status", arguments: [:])

        let pick = try await recordTool("pick_default_caller", tool: "pick", arguments: [
            "role": "planning",
        ])
        XCTAssertEqual(pick.status, 200)
        XCTAssertTrue(
            pick.body.contains("wire-0001"),
            "the first pick must carry the first generated decision id, got: \(pick.body.prefix(200))"
        )
        XCTAssertTrue(
            pick.body.contains("\"isError\":false"),
            "a successful pick must report isError false, got: \(pick.body.prefix(200))"
        )

        _ = try await recordTool("pick_caller_codex", tool: "pick", arguments: [
            "role": "execution", "caller": "codex",
        ])
        _ = try await recordTool("pick_unknown_role", tool: "pick", arguments: [
            "role": "no-such-role",
        ])
        _ = try await recordTool("pick_missing_role", tool: "pick", arguments: [:])
        _ = try await recordTool("pick_blank_role", tool: "pick", arguments: ["role": "  "])
        _ = try await recordTool("pick_override_unavailable", tool: "pick", arguments: [
            "role": "planning", "override_candidate": "t3:*/no-such-model",
        ])

        _ = try await recordTool("down_native", tool: "down", arguments: ["target": "native"])
        _ = try await recordTool("down_minutes_float", tool: "down", arguments: [
            "target": "native", "minutes": 1.5,
        ])
        _ = try await recordTool("down_invalid_target", tool: "down", arguments: ["target": "nope"])
        _ = try await recordTool("down_missing_target", tool: "down", arguments: [:])
        _ = try await recordTool("status_after_down", tool: "status", arguments: [:])
        _ = try await recordTool("up_native", tool: "up", arguments: ["target": "native"])

        _ = try await recordTool("refresh", tool: "refresh", arguments: [:])
        _ = try await recordTool("refresh_again", tool: "refresh", arguments: [:])

        _ = try await recordTool("report_started", tool: "report", arguments: [
            "decision_id": "wire-0001", "status": "started",
        ])
        _ = try await recordTool("report_started_duplicate", tool: "report", arguments: [
            "decision_id": "wire-0001", "status": "started",
        ])
        _ = try await recordTool("report_completed", tool: "report", arguments: [
            "decision_id": "wire-0001",
            "status": "completed",
            "duration_ms": 42_000,
            "actual_input_tokens": 10,
            "actual_output_tokens": 5,
        ])
        _ = try await recordTool("report_unknown_decision", tool: "report", arguments: [
            "decision_id": "nope", "status": "started",
        ])
        _ = try await recordTool("report_invalid_unknown_key", tool: "report", arguments: [
            "decision_id": "wire-0001", "status": "started", "nope": 1,
        ])
        // Reasoning tokens are a subset of output tokens; claiming more
        // reasoning than output is the canonical cross-field rejection.
        _ = try await recordTool("report_invalid_reasoning_gt_output", tool: "report", arguments: [
            "decision_id": "wire-0002",
            "status": "completed",
            "duration_ms": 1_000,
            "actual_output_tokens": 5,
            "actual_reasoning_tokens": 9,
        ])

        _ = try await recordTool("audit_pass", tool: "audit", arguments: [
            "sources": [compliantInstructionSource()],
        ])
        _ = try await recordTool("audit_conflict", tool: "audit", arguments: [
            "sources": [
                compliantInstructionSource(),
                [
                    "path": "~/code/app/CLAUDE.md",
                    "kind": "instruction_root",
                    "content": "Use scripts/model-broker pick for routing.",
                ],
                [
                    "path": "~/.claude/agents/worker.md",
                    "kind": "agent_definition",
                    "content": "tools: Read, Agent\nThis agent can spawn helpers.",
                ],
            ],
        ])
        _ = try await recordTool("audit_unknown_arg", tool: "audit", arguments: [
            "sources": [compliantInstructionSource()], "nope": 1,
        ])
        _ = try await recordTool("audit_oversized", tool: "audit", arguments: [
            "sources": (0..<(BrokerMCPServer.maxAuditSources + 1)).map { index in
                [
                    "path": "~/.claude/CLAUDE-\(index).md",
                    "kind": "instruction_root",
                    "content": "x",
                ]
            },
        ])
        _ = try await recordTool("audit_null_content", tool: "audit", arguments: [
            "sources": [
                [
                    "path": "~/.claude/unreadable.md",
                    "kind": "instruction_root",
                    "content": NSNull(),
                ],
            ],
        ])
        _ = try await recordTool("audit_bad_run_id", tool: "audit", arguments: [
            "sources": [compliantInstructionSource()], "run_id": "run\tone",
        ])

        _ = try await recordTool("status_final", tool: "status", arguments: [:])
        _ = try await recordTool("unknown_tool", tool: "nope", arguments: [:])

        // Transport-level cases: everything below is shaped by its headers or
        // its raw body, not by a tool.

        let get = try await record(
            "get_mcp",
            method: "GET",
            headers: [
                ("Host", "127.0.0.1:\(port)"),
                ("Accept", "application/json"),
                ("Origin", "http://127.0.0.1:\(port)"),
            ],
            body: nil
        )
        XCTAssertEqual(get.status, 405, "stateless streamable HTTP is POST-only")
        XCTAssertEqual(get.headers["allow"], "POST")

        let pickBody = try Self.jsonBody(toolCall: "pick", arguments: ["role": "planning"], id: 900)
        _ = try await record(
            "bad_origin",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count, origin: "http://evil.example"),
            body: pickBody
        )
        _ = try await record(
            "bad_host",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count, host: "evil.example:\(port)"),
            body: pickBody
        )
        _ = try await record(
            "host_without_port",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count, host: "localhost"),
            body: pickBody
        )
        _ = try await record(
            "missing_accept",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count, accept: nil),
            body: pickBody
        )
        _ = try await record(
            "wrong_content_type",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count, contentType: "text/plain"),
            body: pickBody
        )
        _ = try await record(
            "unsupported_protocol_version",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count)
                + [("MCP-Protocol-Version", "1999-01-01")],
            body: pickBody
        )
        _ = try await record(
            "empty_body",
            headers: defaultHeaders(bodyLength: 0),
            body: ""
        )
        _ = try await record(
            "invalid_json",
            headers: defaultHeaders(bodyLength: "not json".utf8.count),
            body: "not json"
        )
        _ = try await record(
            "unknown_path",
            path: "/nope",
            headers: defaultHeaders(bodyLength: pickBody.utf8.count),
            body: pickBody
        )
        // The declared length is over the 1 MiB cap, so the server answers
        // straight after the head. The body is deliberately never sent.
        _ = try await record(
            "oversized_content_length",
            headers: defaultHeaders(bodyLength: 2_000_000),
            body: nil
        )
        _ = try await record(
            "transfer_encoding_chunked",
            headers: [
                ("Host", "127.0.0.1:\(port)"),
                ("Accept", "application/json"),
                ("Content-Type", "application/json"),
                ("Origin", "http://127.0.0.1:\(port)"),
                ("Transfer-Encoding", "chunked"),
            ],
            body: "2\r\n{}\r\n0\r\n\r\n"
        )
    }

    // MARK: - Keyed case list

    private func recordKeyedCases() async throws {
        let listBody = try Self.jsonBody(method: "tools/list", params: [:], id: 1)
        let length = listBody.utf8.count

        let noKey = try await record(
            "no_key",
            headers: defaultHeaders(bodyLength: length),
            body: listBody
        )
        XCTAssertEqual(noKey.status, 401)
        XCTAssertEqual(noKey.headers["www-authenticate"], "Bearer")

        let wrongKey = try await record(
            "wrong_key",
            headers: defaultHeaders(bodyLength: length)
                + [("Authorization", "Bearer \(Self.fixtureWrongAPIKey)")],
            body: listBody
        )
        XCTAssertEqual(wrongKey.status, 401)

        let bearer = try await record(
            "bearer_ok",
            headers: defaultHeaders(bodyLength: length)
                + [("Authorization", "Bearer \(Self.fixtureAPIKey)")],
            body: listBody
        )
        XCTAssertEqual(bearer.status, 200)

        let apiKeyHeader = try await record(
            "x_api_key_ok",
            headers: defaultHeaders(bodyLength: length)
                + [("X-API-Key", Self.fixtureAPIKey)],
            body: listBody
        )
        XCTAssertEqual(apiKeyHeader.status, 200)

        // `NetworkHostValidator` accepts an IP literal on the bound port, so a
        // LAN peer reaching this Mac by address is served.
        let lanHost = try await record(
            "lan_host_ok",
            headers: defaultHeaders(bodyLength: length, host: "192.168.1.10:\(port)")
                + [("Authorization", "Bearer \(Self.fixtureAPIKey)")],
            body: listBody
        )
        XCTAssertEqual(lanHost.status, 200)

        // A public DNS name is the shape a rebinding attack needs, and is the
        // one thing the validator refuses even with a valid key.
        let publicHost = try await record(
            "public_host_421",
            headers: defaultHeaders(bodyLength: length, host: "example.com:\(port)")
                + [("Authorization", "Bearer \(Self.fixtureAPIKey)")],
            body: listBody
        )
        XCTAssertEqual(publicHost.status, 421)
    }

    // MARK: - Audit inputs

    /// An instruction root that satisfies every rule the audit grades, with
    /// the endpoint interpolated so the recorded source names this server.
    private func compliantInstructionSource() -> [String: Any] {
        let text = """
            Register one MCP server named `pinemeter-broker` at `http://127.0.0.1:\(port)/mcp`.
            Call `pick(role, caller)` and require that the returned caller exactly matches the caller sent.
            Choose role names from the broker status tool, including explore and verification.
            Accept `native` with `agent` and `t3` with `t3-dispatch`. When caller is codex, accept codex with agent; \
            use codex with codex-exec for every other caller.
            In Codex, use the harness-native subagent tool with the returned model and optional effort. \
            Give the child a self-contained prompt that preserves the nested Pinemeter `pick(role, caller)` requirement.
            Stop without dispatching if the endpoint or result is unavailable, stale, or malformed.
            Pinemeter is the only model-routing authority. Never add another broker or fallback.
            Every task and every nested subtask that selects a model or route must call Pinemeter first \
            and use `pick(role, caller)`.
            A fresh explicit operator instruction may pass one `override_candidate`. Require \
            `source: human-override`. It bypasses quota caps and pacing gates. Never infer, persist, or reuse it. \
            Never bypass Pinemeter for an override.
            """
        return ["path": "~/.claude/CLAUDE.md", "kind": "instruction_root", "content": text]
    }

    // MARK: - Request construction

    private func defaultHeaders(
        bodyLength: Int,
        host: String? = nil,
        accept: String? = "application/json",
        contentType: String? = "application/json",
        origin: String? = nil
    ) -> [(String, String)] {
        var headers: [(String, String)] = [("Host", host ?? "127.0.0.1:\(port)")]
        if let accept { headers.append(("Accept", accept)) }
        if let contentType { headers.append(("Content-Type", contentType)) }
        headers.append(("Origin", origin ?? "http://127.0.0.1:\(port)"))
        headers.append(("Content-Length", String(bodyLength)))
        return headers
    }

    private static func jsonBody(
        method: String,
        params: [String: Any]?,
        id: Int?
    ) throws -> String {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { message["id"] = id }
        if let params { message["params"] = params }
        return try canonicalJSONString(message)
    }

    private static func jsonBody(
        toolCall name: String,
        arguments: [String: Any],
        id: Int
    ) throws -> String {
        try jsonBody(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            id: id
        )
    }

    /// Compact, sorted, slashes unescaped — the same byte rules the rest of
    /// the corpus uses, so a request body never churns between exports.
    private static func canonicalJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private func recordJSONRPC(
        _ name: String,
        method: String,
        params: [String: Any]?
    ) async throws -> RawResponse {
        let id = nextRequestID
        nextRequestID += 1
        let body = try Self.jsonBody(method: method, params: params, id: id)
        return try await record(
            name,
            headers: defaultHeaders(bodyLength: body.utf8.count),
            body: body
        )
    }

    @discardableResult
    private func recordNotification(
        _ name: String,
        method: String
    ) async throws -> RawResponse {
        let body = try Self.jsonBody(method: method, params: nil, id: nil)
        return try await record(
            name,
            headers: defaultHeaders(bodyLength: body.utf8.count),
            body: body
        )
    }

    @discardableResult
    private func recordTool(
        _ name: String,
        tool: String,
        arguments: [String: Any]
    ) async throws -> RawResponse {
        let id = nextRequestID
        nextRequestID += 1
        let body = try Self.jsonBody(toolCall: tool, arguments: arguments, id: id)
        return try await record(
            name,
            headers: defaultHeaders(bodyLength: body.utf8.count),
            body: body
        )
    }

    // MARK: - Recording

    /// Drives one case over a fresh TCP connection and writes its two files.
    ///
    /// Headers are sent in the order given and recorded with that order, so a
    /// replay can reproduce the request byte for byte — including the cases
    /// whose `Content-Length` deliberately disagrees with the body.
    @discardableResult
    private func record(
        _ name: String,
        method: String = "POST",
        path: String = BrokerMCPServer.endpointPath,
        headers: [(String, String)],
        body: String?
    ) async throws -> RawResponse {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (headerName, value) in headers {
            head += "\(headerName): \(value)\r\n"
        }
        head += "\r\n"
        let response = try await exchange(head + (body ?? ""))

        var recordedHeaders: [String: Any] = [:]
        for (headerName, value) in headers {
            recordedHeaders[headerName] = replacingPort(value)
        }
        let requestObject: [String: Any] = [
            "schema": 1,
            "method": method,
            "path": path,
            "headerOrder": headers.map { $0.0 },
            "headers": recordedHeaders,
            "body": Self.orNull(body.map { self.replacingPort($0) }),
        ]
        let responseObject: [String: Any] = [
            "schema": 1,
            "status": response.status,
            "headers": [
                "allow": Self.orNull(response.headers["allow"]),
                "content-type": Self.orNull(response.headers["content-type"]),
                "www-authenticate": Self.orNull(response.headers["www-authenticate"]),
            ],
            "body": replacingPort(response.body),
        ]

        let directory = Self.wireDirectory.appendingPathComponent(setName)
        try GoldenFixture.write(
            try Self.canonicalData(requestObject), to: directory, named: "\(name).request.json"
        )
        try GoldenFixture.write(
            try Self.canonicalData(responseObject), to: directory, named: "\(name).response.json"
        )
        recordedCases.append(name)
        return response
    }

    private func finishSet() throws {
        XCTAssertFalse(recordedCases.isEmpty, "a fixture set must record at least one case")
        Self.recordedSets[setName] = recordedCases
        try Self.writeManifest()
    }

    private static func writeManifest() throws {
        var sets: [String: Any] = [:]
        for name in manifestSetOrder {
            guard let cases = recordedSets[name] else { continue }
            sets[name] = ["config": configuration(for: name), "cases": cases]
        }
        let manifest: [String: Any] = [
            "schema": 1,
            "clock": ISO8601DateFormatter().string(from: clock),
            "idPrefix": "wire-",
            "portToken": portToken,
            "maskedFields": ["result.serverInfo.version", "pinemeter_version"],
            "sets": sets,
        ]
        try GoldenFixture.write(
            try canonicalData(manifest), to: wireDirectory, named: "cases.json"
        )
    }

    private static func configuration(for set: String) -> [String: Any] {
        switch set {
        case "keyed":
            return ["access": "network", "apiKeyMode": "all", "apiKey": fixtureAPIKey]
        default:
            return ["access": "loopback", "apiKeyMode": "none"]
        }
    }

    private static func canonicalData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func orNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    /// Every authority and every interpolated endpoint carries the ephemeral
    /// port, which changes on every run. Rewriting `:<port>` to `:<PORT>` is
    /// what makes the corpus committable and what lets the Go replay
    /// substitute the port it bound.
    private func replacingPort(_ value: String) -> String {
        value.replacingOccurrences(of: ":\(port)", with: ":\(Self.portToken)")
    }

    // MARK: - Raw HTTP

    struct RawResponse {
        let status: Int
        /// Lowercased header names, per RFC 9110 case-insensitivity.
        let headers: [String: String]
        let body: String
    }

    /// Opens a connection, writes `text` verbatim, and reads the response
    /// until the declared body is complete or the peer closes.
    private func exchange(_ text: String) async throws -> RawResponse {
        let connection = try await connect()
        defer { connection.cancel() }
        try await write(text, on: connection)
        let data = await readResponse(on: connection, timeout: 15)
        return try Self.parse(data)
    }

    private func connect() async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw GoldenFixture.Failure("cannot build an endpoint for port \(port)")
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = WireResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: GoldenFixture.Failure("connection cancelled before ready"))
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        return connection
    }

    private func write(_ text: String, on connection: NWConnection) async throws {
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

    private func readResponse(on connection: NWConnection, timeout: TimeInterval) async -> Data {
        var accumulated = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if Self.isComplete(accumulated) { return accumulated }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return accumulated }
            switch await receiveChunk(on: connection, timeout: remaining) {
            case .data(let chunk):
                accumulated.append(chunk)
            case .closed, .timedOut:
                return accumulated
            }
        }
    }

    private enum Chunk: Sendable {
        case data(Data)
        case closed
        case timedOut
    }

    private func receiveChunk(on connection: NWConnection, timeout: TimeInterval) async -> Chunk {
        await withCheckedContinuation { (continuation: CheckedContinuation<Chunk, Never>) in
            let once = WireResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    once.resume(returning: .data(data))
                } else if error != nil || isComplete {
                    once.resume(returning: .closed)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(returning: .timedOut)
            }
        }
    }

    /// True once the head has arrived and the declared `Content-Length` bytes
    /// of body are in hand. A response without `Content-Length` is only
    /// complete when the peer closes, which the caller detects separately.
    private static func isComplete(_ data: Data) -> Bool {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        guard let length = contentLength(in: head) else { return false }
        return data.distance(from: separator.upperBound, to: data.endIndex) >= length
    }

    private static func contentLength(in head: String) -> Int? {
        for line in head.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func parse(_ data: Data) throws -> RawResponse {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw GoldenFixture.Failure(
                "no header terminator in \(data.count) bytes: "
                    + String(decoding: data.prefix(120), as: UTF8.self)
            )
        }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw GoldenFixture.Failure("empty response head")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw GoldenFixture.Failure("unparseable status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let body = String(decoding: data[separator.upperBound...], as: UTF8.self)
        return RawResponse(status: status, headers: headers, body: body)
    }
}

/// `wire-0001`, `wire-0002`, ... in call order. A lock rather than an actor
/// because `BrokerService`'s `idGenerator` is a synchronous `@Sendable`
/// closure.
private final class WireIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return String(format: "wire-%04d", value)
    }
}

/// Once-guard for the raw `NWConnection` helpers: both the completion handler
/// and the timeout can fire, and resuming a continuation twice traps.
/// `BrokerHTTPServerTests` has an equivalent, but it is `private` to that file.
private final class WireResumeOnce<T, E: Error>: @unchecked Sendable {
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
