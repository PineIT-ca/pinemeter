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
    private var auditStore: BrokerAuditStore!
    private var broker: BrokerService!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Every store here is pointed at a hermetic temp directory: the real
        // Application Support / ~/.model-broker / ~/.t3 paths must never be
        // touched by tests, whether or not this machine happens to have a
        // real CLI cooldown or T3 pointer file on disk.
        let cooldownStore = BrokerCooldownStore(
            storeDirectory: tempDirectory,
            cliCooldownsURL: tempDirectory.appendingPathComponent("cli-cooldowns.json")
        )
        let livenessChecker = T3LivenessChecker(
            pointerFileURL: tempDirectory.appendingPathComponent("server-runtime.json")
        )
        auditStore = BrokerAuditStore(storeDirectory: tempDirectory)
        broker = BrokerService(
            policy: .default,
            cooldownStore: cooldownStore,
            auditStore: auditStore,
            instructionCheckStore: InstructionCheckStore(storeDirectory: tempDirectory),
            livenessChecker: livenessChecker
        )
        server = BrokerMCPServer.makeLoopbackServer(
            broker: broker,
            port: 0,
            version: "test"
        )
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        auditStore = nil
        broker = nil
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
        XCTAssertEqual(toolNames, ["pick", "status", "down", "up", "refresh", "report", "audit"],
                       "tools/list must advertise the original five tools plus report and audit")

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

    // MARK: - Configuration surface
    //
    // The contract used to reach a harness only by pasteboard, which meant it
    // was carried by whatever the user pasted and whenever they pasted it.
    // These three tests pin the paths that replace that: `instructions` on
    // initialize, the `configure` prompt, and the `audit` tool.

    func test_initialize_carriesTheRoutingContractAsServerInstructions() async throws {
        let initialize = try await sendInitialize()
        let result = try XCTUnwrap(initialize.json?["result"] as? [String: Any])
        let instructions = try XCTUnwrap(
            result["instructions"] as? String,
            "initialize must carry instructions; a client folds them into the model's prompt"
        )

        XCTAssertTrue(instructions.contains("pick(role, caller)"))
        XCTAssertTrue(instructions.contains("exactly matches the caller sent"))
        XCTAssertTrue(instructions.contains("`native` with `agent`"))
        XCTAssertTrue(instructions.contains("`t3` with `t3-dispatch`"))
        XCTAssertTrue(instructions.contains("`codex` with `codex-exec`"))
        XCTAssertTrue(instructions.contains("Stop without dispatching"))
        XCTAssertTrue(instructions.contains("Never add a second broker client"))
        XCTAssertTrue(
            instructions.contains("wait for the user's approval"),
            "the approval boundary belongs in the instructions, not only in the prompt"
        )

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["prompts"], "prompts capability must be advertised")
    }

    func test_promptsListAndGet_serveTheConfigurePromptForThisEndpoint() async throws {
        _ = try await sendInitialize()

        let list = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 2, "method": "prompts/list",
        ])
        let prompts = try XCTUnwrap((list.json?["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.compactMap { $0["name"] as? String }, ["configure"])

        let get = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 3, "method": "prompts/get",
            "params": ["name": "configure"],
        ])
        let messages = try XCTUnwrap((get.json?["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        let text = try XCTUnwrap(content["text"] as? String)

        XCTAssertTrue(
            text.contains("http://127.0.0.1:\(port)/mcp"),
            "the served prompt must name the port the server actually bound"
        )
        XCTAssertTrue(text.contains("already registered against it"))
        XCTAssertTrue(text.contains("`audit` tool"))
        XCTAssertTrue(text.contains("Wait for explicit approval before changing user files"))

        let unknown = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 4, "method": "prompts/get",
            "params": ["name": "not-a-prompt"],
        ])
        XCTAssertNotNil(unknown.json?["error"], "an unknown prompt name must be an error, not an empty result")
    }

    func test_auditGradesSuppliedSourcesAndReturnsTheContract() async throws {
        let complete = """
            Register one MCP server named `pinemeter-broker` at `http://127.0.0.1:\(port)/mcp`.
            Call `pick(role, caller)` and require that the returned caller exactly matches the caller sent.
            Accept only `native` with `agent`, `t3` with `t3-dispatch`, and `codex` with `codex-exec`.
            Stop without dispatching if the endpoint or result is unavailable, stale, or malformed.
            Pinemeter is the only model-routing authority. Never add another broker or fallback.
            Every task and every nested subtask that selects a model or route must call Pinemeter first \
            and use `pick(role, caller)`.
            """

        let audit = try await auditJSON(sources: [
            ["path": "~/.claude/CLAUDE.md", "kind": "instruction_root", "content": complete],
            [
                "path": "~/code/app/CLAUDE.md", "kind": "instruction_root",
                "content": "Use scripts/model-broker pick for routing.",
            ],
            [
                "path": "~/.claude/agents/worker.md", "kind": "agent_definition",
                "content": "tools: Read, Agent\nThis agent can spawn helpers.",
            ],
        ])

        XCTAssertEqual(audit["status"] as? String, "conflict", "the worst source sets the overall status")
        XCTAssertEqual(audit["endpoint"] as? String, "http://127.0.0.1:\(port)/mcp")

        let counts = try XCTUnwrap(audit["counts"] as? [String: Any])
        XCTAssertEqual(counts["pass"] as? Int, 1)
        XCTAssertEqual(counts["conflict"] as? Int, 1)
        XCTAssertEqual(counts["warning"] as? Int, 1)
        XCTAssertEqual(counts["unavailable"] as? Int, 0)

        let sources = try XCTUnwrap(audit["sources"] as? [[String: Any]])
        let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0["path"] as? String ?? "", $0) })
        XCTAssertEqual(byPath["~/.claude/CLAUDE.md"]?["status"] as? String, "pass")

        let project = try XCTUnwrap(byPath["~/code/app/CLAUDE.md"])
        XCTAssertEqual(project["status"] as? String, "conflict")
        let projectFindings = try XCTUnwrap(project["findings"] as? [[String: Any]])
        XCTAssertEqual(projectFindings.first?["kind"] as? String, "conflict")

        let agent = try XCTUnwrap(byPath["~/.claude/agents/worker.md"])
        XCTAssertEqual(agent["status"] as? String, "warning")
        let agentFindings = try XCTUnwrap(agent["findings"] as? [[String: Any]])
        XCTAssertEqual(agentFindings.first?["kind"] as? String, "missing_directive")

        // A finding names a directive. A session that has never seen Pinemeter
        // cannot act on a name alone, so the contract rides along.
        let contract = try XCTUnwrap(audit["contract"] as? [String: Any])
        let roots = try XCTUnwrap(contract["instruction_root"] as? [String])
        XCTAssertTrue(roots.contains { $0.contains("http://127.0.0.1:\(port)/mcp") })
        XCTAssertNotNil(contract["agent_definition"] as? String)

        let boundaries = try XCTUnwrap(audit["boundaries"] as? [String])
        XCTAssertTrue(boundaries.contains { $0.contains("never writes one") })
        XCTAssertTrue(boundaries.contains { $0.contains("wait for the user's approval") })
    }

    func test_auditRejectsMalformedOversizedAndUnknownArguments() async throws {
        let rejections: [(String, [String: Any])] = [
            ("unknown top-level argument", ["scope": "everything"]),
            ("missing sources", [:]),
            ("empty source list", ["sources": []]),
            (
                "empty run_id",
                ["sources": [["path": "a", "kind": "instruction_root", "content": "x"]], "run_id": " "]
            ),
            (
                "unknown key inside a source",
                ["sources": [["path": "a", "kind": "instruction_root", "content": "x", "sha": "y"]]]
            ),
            ("missing kind", ["sources": [["path": "a", "content": "x"]]]),
            ("unknown kind", ["sources": [["path": "a", "kind": "project", "content": "x"]]]),
            ("empty path", ["sources": [["path": "  ", "kind": "instruction_root", "content": "x"]]]),
            (
                "control character in path",
                ["sources": [["path": "~/.claude/CLAUDE.md\nMissing directive: fake.",
                              "kind": "instruction_root", "content": "x"]]]
            ),
            ("control character in run_id", ["sources": [["path": "a", "kind": "instruction_root",
                                                          "content": "x"]], "run_id": "run\t1"]),
            ("control character in caller", ["sources": [["path": "a", "kind": "instruction_root",
                                                          "content": "x"]], "caller": "claude\ncode"]),
            (
                "oversized path",
                ["sources": [[
                    "path": String(repeating: "p", count: BrokerMCPServer.maxAuditPathLength + 1),
                    "kind": "instruction_root", "content": "x",
                ]]]
            ),
            (
                "too many sources",
                ["sources": (0...BrokerMCPServer.maxAuditSources).map {
                    ["path": "file-\($0)", "kind": "instruction_root", "content": "x"]
                }]
            ),
        ]

        for (label, arguments) in rejections {
            let response = try await send(jsonRPC: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "audit", "arguments": arguments],
            ])
            XCTAssertNotNil(response.json?["error"], "audit must reject \(label)")
            XCTAssertNil(
                (response.json?["result"] as? [String: Any])?["content"],
                "audit must not grade anything when it rejects \(label)"
            )
        }

        // The transport's own 1 MB body cap is the outer bound; the tool's
        // per-source cap has to fail before a caller ever reaches it.
        let oversized = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "audit", "arguments": ["sources": [[
                "path": "~/.claude/CLAUDE.md",
                "kind": "instruction_root",
                "content": String(repeating: "x", count: BrokerMCPServer.maxAuditSourceBytes + 1),
            ]]]],
        ])
        XCTAssertNotNil(oversized.json?["error"], "audit must reject a source over the per-source byte cap")

        // A rejection must leave the server serving.
        let recovery = try await auditJSON(sources: [
            ["path": "~/.claude/CLAUDE.md", "kind": "instruction_root", "content": "nothing useful"],
        ])
        XCTAssertEqual(recovery["status"] as? String, "warning")
    }

    func test_auditRecordsTheGradedVerdictAndMergesBatchesSharingARunID() async throws {
        let conflicted = ["path": "~/.claude/CLAUDE.md", "kind": "instruction_root",
                          "content": "Use scripts/model-broker pick for routing."]
        let agent = ["path": "~/.claude/agents/worker.md", "kind": "agent_definition",
                     "content": "tools: Read, Agent\nThis agent can spawn helpers."]

        _ = try await auditJSON(sources: [conflicted], runID: "run-1", caller: "claude-code")
        let recordedFirst = await broker.latestInstructionCheck()
        let first = try XCTUnwrap(recordedFirst)
        XCTAssertEqual(first.caller, "claude-code")
        XCTAssertEqual(first.runID, "run-1")
        XCTAssertEqual(first.sources.map(\.path), ["~/.claude/CLAUDE.md"])
        XCTAssertEqual(first.status, .conflict)
        XCTAssertFalse(
            first.sources.contains { $0.findings.contains { $0.contains("model-broker pick for routing") } },
            "the record keeps findings, never the graded file content"
        )

        // A second batch under the same run must extend the check, not replace
        // it: an agent whose stack exceeds one call would otherwise record
        // only whichever batch happened to land last.
        _ = try await auditJSON(sources: [agent], runID: "run-1", caller: "claude-code")
        let recordedMerged = await broker.latestInstructionCheck()
        let merged = try XCTUnwrap(recordedMerged)
        XCTAssertEqual(merged.sources.map(\.path), ["~/.claude/CLAUDE.md", "~/.claude/agents/worker.md"])
        XCTAssertEqual(merged.count(of: .conflict), 1)
        XCTAssertEqual(merged.count(of: .warning), 1)

        // A different run replaces it outright.
        _ = try await auditJSON(sources: [agent], runID: "run-2")
        let recordedReplaced = await broker.latestInstructionCheck()
        let replaced = try XCTUnwrap(recordedReplaced)
        XCTAssertEqual(replaced.runID, "run-2")
        XCTAssertNil(replaced.caller)
        XCTAssertEqual(replaced.sources.map(\.path), ["~/.claude/agents/worker.md"])
    }

    func test_auditRejection_leavesTheRecordedCheckUntouched() async throws {
        _ = try await auditJSON(
            sources: [["path": "~/.claude/CLAUDE.md", "kind": "instruction_root", "content": "nothing"]],
            runID: "keeper"
        )

        let rejected = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "audit", "arguments": ["sources": []]],
        ])
        XCTAssertNotNil(rejected.json?["error"])

        let recorded = await broker.latestInstructionCheck()
        let check = try XCTUnwrap(recorded)
        XCTAssertEqual(check.runID, "keeper")
    }

    /// An identifier the store would silently drop has to be refused here, or
    /// two batches sent under it both succeed while each is treated as its own
    /// run and the recorded verdict quietly covers only the last one.
    func test_auditRefusesIdentifiersTheStoreWouldSilentlyDrop() async throws {
        for value in ["run\t1", "run\u{0}1"] {
            let response = try await send(jsonRPC: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "audit", "arguments": [
                    "sources": [["path": "a.md", "kind": "instruction_root", "content": "x"]],
                    "run_id": value,
                ]],
            ])
            XCTAssertNotNil(response.json?["error"], "audit must refuse run_id \(value.debugDescription)")
        }

        let recorded = await broker.latestInstructionCheck()
        XCTAssertNil(recorded, "a refused call must record nothing")
    }

    /// An agent that cannot read a path says so rather than dropping it, and
    /// the gap stays visible in the verdict.
    func test_auditAcceptsNullContentAndGradesItUnavailable() async throws {
        let audit = try await auditJSON(sources: [
            ["path": "~/.claude/CLAUDE.md", "kind": "instruction_root", "content": NSNull()],
        ])

        XCTAssertEqual(audit["status"] as? String, "unavailable")
        let sources = try XCTUnwrap(audit["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["status"] as? String, "unavailable")
        let findings = try XCTUnwrap(sources.first?["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.first?["kind"] as? String, "unavailable")

        // Omitting the key entirely is still an error: a caller that forgot to
        // send content must not be read as "this file is unreadable".
        let omitted = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "audit", "arguments": [
                "sources": [["path": "a.md", "kind": "instruction_root"]],
            ]],
        ])
        XCTAssertNotNil(omitted.json?["error"])
    }

    private func sendInitialize(id: Int = 1) async throws -> Response {
        let response = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "PinemeterTests", "version": "1.0"],
            ],
        ])
        XCTAssertEqual(response.status, 200)
        return response
    }

    private func auditJSON(
        sources: [[String: Any]],
        runID: String? = nil,
        caller: String? = nil
    ) async throws -> [String: Any] {
        var arguments: [String: Any] = ["sources": sources]
        if let runID { arguments["run_id"] = runID }
        if let caller { arguments["caller"] = caller }
        let response = try await send(jsonRPC: [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "audit", "arguments": arguments],
        ])
        let result = try XCTUnwrap(response.json?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "audit returned a tool error: \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "audit content was not JSON: \(text)"
        )
    }

    func testPickStartedCompletedLifecycleOverLoopback() async throws {
        let pick = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "pick", "arguments": ["role": "planning"]],
        ])
        let decisionID = try XCTUnwrap(try decodeDecision(from: pick)["decision_id"] as? String)

        let startedResult = try await callReport([
            "decision_id": decisionID,
            "status": "started",
            "thread_id": "thread-1",
            "session_id": "session-1",
        ])
        XCTAssertEqual(startedResult, "recorded")
        let completed: [String: Any] = [
            "decision_id": decisionID,
            "status": "completed",
            "duration_ms": 604_800_000,
            "actual_input_tokens": 11,
            "actual_cached_input_tokens": 12,
            "actual_cache_creation_input_tokens": 13,
            "actual_output_tokens": 15,
            "actual_reasoning_tokens": 14,
        ]
        let completedResult = try await callReport(completed)
        XCTAssertEqual(completedResult, "recorded")
        let duplicateResult = try await callReport(completed)
        XCTAssertEqual(duplicateResult, "duplicate")
        let unknownResult = try await callReport([
            "decision_id": "unknown", "status": "started",
        ])
        XCTAssertEqual(unknownResult, "unknown_decision")

        let records = await auditStore.recordsSnapshot
        XCTAssertEqual(records.first?.decisionID, decisionID)
        XCTAssertEqual(
            records.first?.started?.threadID,
            BrokerLifecycleText.persistedIdentifier("thread-1")
        )
        XCTAssertEqual(records.first?.terminal?.actualReasoningTokens, 14)
    }

    func testReportPersistenceFailureReturnsNoRecordedResult() async throws {
        let writer = FailAfterFirstAuditWrite()
        let failingStore = BrokerAuditStore(storeDirectory: tempDirectory, writer: writer.write)
        try await replaceServer(
            broker: BrokerService(
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: tempDirectory,
                    cliCooldownsURL: tempDirectory.appendingPathComponent("failing-cli-cooldowns.json")
                ),
                auditStore: failingStore,
                livenessChecker: T3LivenessChecker(
                    pointerFileURL: tempDirectory.appendingPathComponent("failing-runtime.json")
                )
            )
        )

        let pick = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "pick", "arguments": ["role": "planning"]],
        ])
        let decisionID = try XCTUnwrap(try decodeDecision(from: pick)["decision_id"] as? String)
        let response = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "report",
                "arguments": ["decision_id": decisionID, "status": "started"],
            ],
        ])

        let error = try XCTUnwrap(response.json?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32603)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertLessThanOrEqual(message.unicodeScalars.count, 128)
        XCTAssertFalse(message.contains("synthetic-sensitive-writer-detail"))
        XCTAssertNil(response.json?["result"])
        let failedRecords = await failingStore.recordsSnapshot
        XCTAssertNil(failedRecords.first?.started)
    }

    func testReportRejectsInvalidWireValuesBeforeMutation() async throws {
        let spy = ReportBrokerSpy(directory: tempDirectory)
        try await replaceServer(broker: spy)
        let longID = String(repeating: "x", count: 129)
        let invalid: [[String: Any]] = [
            ["status": "started"],
            ["decision_id": "", "status": "started"],
            ["decision_id": "   ", "status": "started"],
            ["decision_id": "d"],
            ["decision_id": "d", "status": "pending"],
            ["decision_id": "d", "status": "started", "unknown": true],
            ["decision_id": longID, "status": "started"],
            ["decision_id": "d", "status": "completed", "duration_ms": 1.5],
            ["decision_id": "d", "status": "completed", "duration_ms": -1],
            ["decision_id": "d", "status": "completed", "duration_ms": 604_800_001],
            ["decision_id": "d", "status": "completed", "actual_input_tokens": -1],
            ["decision_id": "d", "status": "completed", "actual_input_tokens": 2_147_483_648],
            ["decision_id": "d", "status": "completed", "actual_output_tokens": 1,
             "actual_reasoning_tokens": 2],
            ["decision_id": "d", "status": "started", "duration_ms": 0],
            ["decision_id": "d", "status": "completed", "failure_reason": "no"],
            ["decision_id": "d", "status": "failed", "failure_reason": " \u{0000}\u{000A} "],
            ["decision_id": "d", "status": "completed", "duration_ms": ["raw": "request"]],
            ["decision_id": "d", "status": "failed", "raw_request": ["prompt": "secret"]],
            ["decision_id": "d", "status": "failed", "raw_error": ["message": "secret"]],
        ]

        for (index, arguments) in invalid.enumerated() {
            let response = try await reportResponse(arguments, id: index + 1)
            let error = try XCTUnwrap(
                response.json?["error"] as? [String: Any],
                "case \(index) unexpectedly succeeded: \(String(describing: response.json))"
            )
            XCTAssertEqual(error["code"] as? Int, -32602, "case \(index)")
        }

        let nonfinite = Data("""
        {"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"report","arguments":{"decision_id":"d","status":"completed","duration_ms":1e309}}}
        """.utf8)
        let nonfiniteResponse = try await perform(
            method: "POST",
            path: BrokerMCPServer.endpointPath,
            body: nonfinite
        )
        // Nonfinite JSON is rejected by the SDK parser before tool dispatch.
        XCTAssertEqual(
            (nonfiniteResponse.json?["error"] as? [String: Any])?["code"] as? Int,
            -32700
        )
        let reportCount = await spy.reportCount
        XCTAssertEqual(reportCount, 0)
    }

    func testReportDoesNotPersistSecretBearingStrings() async throws {
        let auditURL = tempDirectory.appendingPathComponent("broker-audit.json")
        let sentinels = [
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturePart1234",
            "AKIAIOSFODNN7EXAMPLE",
            "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            "AIzaSyDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY",
            TestConstants.githubShapedSentinel,
            TestConstants.slackShapedSentinel,
            "opaque-r4Nd0m-7Qv2Lm9Xc5Pk8Ws3Ha6Tf1Zy",
        ]

        for (index, sentinel) in sentinels.enumerated() {
            let pick = try await send(jsonRPC: [
                "jsonrpc": "2.0",
                "id": 100 + index,
                "method": "tools/call",
                "params": ["name": "pick", "arguments": ["role": "planning"]],
            ])
            let decisionID = try XCTUnwrap(try decodeDecision(from: pick)["decision_id"] as? String)
            let started = try await callReport([
                "decision_id": decisionID,
                "status": "started",
                "thread_id": sentinel,
                "session_id": sentinel,
            ])
            XCTAssertEqual(started, "recorded")
            let failed = try await callReport([
                "decision_id": decisionID,
                "status": "failed",
                "failure_reason": "provider rejected \(sentinel)",
            ])
            XCTAssertEqual(failed, "recorded")
        }

        let text = String(decoding: try Data(contentsOf: auditURL), as: UTF8.self)
        for sentinel in sentinels {
            XCTAssertFalse(text.contains(sentinel))
            XCTAssertFalse(text.contains(String(sentinel.prefix(16))))
            XCTAssertFalse(text.contains(String(sentinel.suffix(16))))
        }
        XCTAssertTrue(text.contains("sha256:"))

        let restarted = BrokerAuditStore(storeDirectory: tempDirectory)
        let persistedReasons = await restarted.recordsSnapshot.compactMap(\.terminal?.failureReason)
        XCTAssertEqual(persistedReasons.count, sentinels.count)
        XCTAssertEqual(Set(persistedReasons), ["reported_failure"])
    }

    func testReportAcceptsBoundedScalarsAndSanitizesFailureReason() async throws {
        let spy = ReportBrokerSpy(directory: tempDirectory)
        try await replaceServer(broker: spy)
        let maxID = String(repeating: "x", count: 128)
        let maxTokens = 2_147_483_647

        let started = try await reportText([
            "decision_id": maxID,
            "status": "started",
            "thread_id": maxID,
            "session_id": "s",
        ])
        XCTAssertEqual(started, "recorded")
        for status in ["completed", "failed", "exhausted"] {
            var arguments: [String: Any] = [
                "decision_id": status == "completed" ? "d" : maxID,
                "status": status,
                "duration_ms": 604_800_000,
                "actual_input_tokens": maxTokens,
                "actual_cached_input_tokens": maxTokens,
                "actual_cache_creation_input_tokens": maxTokens,
                "actual_output_tokens": maxTokens,
                "actual_reasoning_tokens": maxTokens,
            ]
            if status != "completed" {
                arguments["failure_reason"] = " \u{0000}" + String(repeating: "x", count: 300) + "\u{000A} "
            }
            let result = try await reportText(arguments)
            XCTAssertEqual(result, "recorded")
        }

        let reports = await spy.reportsSnapshot
        XCTAssertEqual(reports.count, 4)
        XCTAssertEqual(reports[0].decisionID, maxID)
        XCTAssertEqual(reports[0].threadID, maxID)
        XCTAssertEqual(reports[0].sessionID, "s")
        XCTAssertEqual(reports[1].durationMS, 604_800_000)
        XCTAssertEqual(reports[1].actualReasoningTokens, maxTokens)
        XCTAssertEqual(reports[2].failureReason, "reported_failure")
        XCTAssertEqual(reports[3].failureReason, "reported_failure")
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
        //
        // No oracle has been pushed either, and that is deliberately NOT enough
        // to demote the codex lane: an absent snapshot is ignorance, not
        // evidence that this machine has no ChatGPT. Demotion needs a snapshot
        // that positively reports no source — see
        // `BrokerEngineTests.test_codexLaneWithNoChatGPTAccount_...`.
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

    func testDownRejectsInvalidOversizedAndExcessTargetsWithoutPersistingThem() async throws {
        let candidates = (0...BrokerCooldownStore.maxEntries).map {
            BrokerCandidate(route: .native, model: "capacity-\($0)")
        }
        let oversizedTarget = "native/" + String(
            repeating: "x",
            count: BrokerCooldownStore.maxTargetScalars
        )
        let policy = BrokerPolicy(
            roles: [
                "bulk": candidates + [BrokerCandidate(
                    route: .native,
                    model: String(repeating: "x", count: BrokerCooldownStore.maxTargetScalars)
                )],
            ]
        )
        let cooldownURL = tempDirectory.appendingPathComponent("broker-cooldowns.json")
        try await replaceServer(
            broker: BrokerService(
                policy: policy,
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: tempDirectory,
                    cliCooldownsURL: tempDirectory.appendingPathComponent("bounded-cli.json")
                ),
                auditStore: BrokerAuditStore(storeDirectory: tempDirectory)
            )
        )

        let rejectedTargets = [
            "not-configured",
            "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            oversizedTarget,
        ]
        for (index, target) in rejectedTargets.enumerated() {
            let before = try? Data(contentsOf: cooldownURL)
            let response = try await send(jsonRPC: [
                "jsonrpc": "2.0",
                "id": 200 + index,
                "method": "tools/call",
                "params": ["name": "down", "arguments": ["target": target]],
            ])
            XCTAssertEqual((response.json?["error"] as? [String: Any])?["code"] as? Int, -32602)
            XCTAssertEqual(try? Data(contentsOf: cooldownURL), before)
        }

        for index in 0..<BrokerCooldownStore.maxEntries {
            let response = try await send(jsonRPC: [
                "jsonrpc": "2.0",
                "id": 300 + index,
                "method": "tools/call",
                "params": [
                    "name": "down",
                    "arguments": ["target": candidates[index].id, "minutes": 10],
                ],
            ])
            XCTAssertNil(response.json?["error"])
        }

        let beforeExcess = try Data(contentsOf: cooldownURL)
        let excessTarget = candidates[BrokerCooldownStore.maxEntries].id
        let excess = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 400,
            "method": "tools/call",
            "params": ["name": "down", "arguments": ["target": excessTarget]],
        ])
        XCTAssertEqual((excess.json?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(try Data(contentsOf: cooldownURL), beforeExcess)

        let status = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 401,
            "method": "tools/call",
            "params": ["name": "status", "arguments": [:]],
        ])
        let result = try XCTUnwrap(status.json?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        for target in rejectedTargets + [excessTarget] {
            XCTAssertFalse(text.contains(target))
        }
    }

    func testCooldownWriteFailureReturnsInternalErrorAndDoesNotSurviveRestart() async throws {
        let cooldownURL = tempDirectory.appendingPathComponent("broker-cooldowns.json")
        let cliURL = tempDirectory.appendingPathComponent("failing-cooldown-cli.json")
        try await replaceServer(
            broker: BrokerService(
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: tempDirectory,
                    cliCooldownsURL: cliURL,
                    writer: { _, _ in throw NSError(domain: "synthetic", code: 1) }
                ),
                auditStore: BrokerAuditStore(storeDirectory: tempDirectory)
            )
        )
        let before = try? Data(contentsOf: cooldownURL)

        let response = try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": 500,
            "method": "tools/call",
            "params": ["name": "down", "arguments": ["target": "t3"]],
        ])

        XCTAssertNil(response.json?["result"])
        XCTAssertEqual((response.json?["error"] as? [String: Any])?["code"] as? Int, -32603)
        XCTAssertEqual(try? Data(contentsOf: cooldownURL), before)
        let restarted = await BrokerCooldownStore(
            storeDirectory: tempDirectory,
            cliCooldownsURL: cliURL
        ).mergedSnapshot()
        XCTAssertTrue(restarted.isEmpty)
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
            broker: BrokerService(
                policy: .default,
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: tempDirectory,
                    cliCooldownsURL: tempDirectory.appendingPathComponent("cli-cooldowns.json")
                ),
                auditStore: BrokerAuditStore(storeDirectory: tempDirectory),
                instructionCheckStore: InstructionCheckStore(storeDirectory: tempDirectory),
                livenessChecker: T3LivenessChecker(
                    pointerFileURL: tempDirectory.appendingPathComponent("server-runtime.json")
                )
            ),
            port: 0,
            version: "test"
        )
        let firstPort = try await first.start()
        try await assertServesSuccessfully(on: firstPort)
        await first.stop()

        let restarted = BrokerMCPServer.makeLoopbackServer(
            broker: BrokerService(
                policy: .default,
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: tempDirectory,
                    cliCooldownsURL: tempDirectory.appendingPathComponent("cli-cooldowns.json")
                ),
                auditStore: BrokerAuditStore(storeDirectory: tempDirectory),
                instructionCheckStore: InstructionCheckStore(storeDirectory: tempDirectory),
                livenessChecker: T3LivenessChecker(
                    pointerFileURL: tempDirectory.appendingPathComponent("server-runtime.json")
                )
            ),
            port: firstPort,
            version: "test"
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

    // MARK: - API key enforcement
    //
    // These connect over loopback, so they exercise `.all` (every connection
    // presents a key) rather than the `.nonLoopback` split, which is covered
    // directly on `BrokerAccessPolicy`.

    func test_requestWithoutAPIKey_isRejectedWith401AndAChallenge() async throws {
        try await replaceServer(accessPolicy: Self.keyRequiringPolicy)

        let response = try await performRaw(jsonRPC: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])

        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.headers["Www-Authenticate"] ?? response.headers["WWW-Authenticate"], "Bearer")
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "Unauthorized")
    }

    func test_requestWithTheWrongAPIKey_isRejectedWith401() async throws {
        try await replaceServer(accessPolicy: Self.keyRequiringPolicy)

        let response = try await performRaw(
            jsonRPC: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]],
            extraHeaders: ["Authorization": "Bearer pm_wrong_key"]
        )

        XCTAssertEqual(response.status, 401)
    }

    func test_requestWithTheAPIKey_isServedNormally() async throws {
        try await replaceServer(accessPolicy: Self.keyRequiringPolicy)

        for headers in [
            ["Authorization": "Bearer \(Self.testAPIKey)"],
            ["X-API-Key": Self.testAPIKey],
        ] {
            let response = try await send(
                jsonRPC: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]],
                extraHeaders: headers
            )
            XCTAssertEqual(response.status, 200, "a correct key must be served: \(headers)")
            let tools = try XCTUnwrap((response.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            XCTAssertTrue(tools.contains { $0["name"] as? String == "pick" })
        }
    }

    func test_unauthorizedRequestOnAnUnroutedPath_still404s() async throws {
        // The path check runs first, so an unauthorized probe of an unrelated
        // path learns nothing about whether a key is configured.
        try await replaceServer(accessPolicy: Self.keyRequiringPolicy)

        let response = try await perform(method: "POST", path: "/not-mcp", body: Data("{}".utf8))

        XCTAssertEqual(response.status, 404)
    }

    private static let testAPIKey = "pm_http_server_test_key"

    private static var keyRequiringPolicy: BrokerAccessPolicy {
        BrokerAccessPolicy(networkAccess: .loopback, apiKeyMode: .all, apiKey: testAPIKey)
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

    private func callReport(_ arguments: [String: Any]) async throws -> String {
        try await reportText(arguments)
    }

    private func reportText(_ arguments: [String: Any]) async throws -> String {
        let response = try await reportResponse(arguments)
        let result = try XCTUnwrap(response.json?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func reportResponse(_ arguments: [String: Any], id: Int = 99) async throws -> Response {
        try await send(jsonRPC: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": "report", "arguments": arguments],
        ])
    }

    private func replaceServer(accessPolicy: BrokerAccessPolicy) async throws {
        await server.stop()
        server = BrokerMCPServer.makeLoopbackServer(
            broker: broker,
            port: 0,
            version: "test",
            accessPolicy: accessPolicy
        )
        port = try await server.start()
    }

    /// Like `perform`, but keeps the response headers. `URLSession` is fine
    /// for this: the 401 carries a `WWW-Authenticate: Bearer` challenge and no
    /// credentials, so there is nothing for it to retry or strip.
    private func performRaw(
        jsonRPC message: [String: Any],
        extraHeaders: [String: String] = [:]
    ) async throws -> (status: Int, headers: [String: String], data: Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return (httpResponse.statusCode, headers, data)
    }

    private func replaceServer(broker: any BrokerServiceProtocol) async throws {
        await server.stop()
        server = BrokerMCPServer.makeLoopbackServer(broker: broker, port: 0, version: "test")
        port = try await server.start()
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

private final class FailAfterFirstAuditWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        guard writes == 1 else {
            throw NSError(
                domain: "synthetic-sensitive-writer-detail",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-sensitive-writer-detail"]
            )
        }
        try data.write(to: url, options: .atomic)
    }
}

private actor ReportBrokerSpy: BrokerServiceProtocol {
    private let base: BrokerService
    private var reports: [BrokerLifecycleReport] = []

    init(directory: URL) {
        base = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("spy-cli-cooldowns.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            livenessChecker: T3LivenessChecker(
                pointerFileURL: directory.appendingPathComponent("spy-runtime.json")
            )
        )
    }

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        try await base.pick(role: role, caller: caller)
    }

    func status() async -> BrokerStatus { await base.status() }
    func down(target: String, minutes: Int?) async throws {
        try await base.down(target: target, minutes: minutes)
    }
    func up(target: String) async throws { try await base.up(target: target) }
    func refresh() async throws { try await base.refresh() }

    func reportLifecycle(_ report: BrokerLifecycleReport) async throws -> BrokerLifecycleResult {
        reports.append(report)
        return .recorded
    }

    var reportCount: Int { reports.count }
    var reportsSnapshot: [BrokerLifecycleReport] { reports }
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
