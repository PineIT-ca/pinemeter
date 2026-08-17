//
//  BrokerMCPServer.swift
//  Pinemeter
//
//  MCP server core: tool schemas, handlers, and the stateless streamable-HTTP
//  transport the loopback listener feeds.
//

import Foundation
import MCP
import os

actor BrokerMCPServer {
    static let serverName = "Pinemeter Broker"
    /// The single MCP endpoint path. POST-only by design; GET answers 405,
    /// which is spec-compliant for a server without an SSE stream.
    static let endpointPath = "/mcp"

    private static let logger = os.Logger(subsystem: "com.pinemeter", category: "BrokerMCPServer")

    private let broker: any BrokerServiceProtocol
    private let server: MCP.Server
    private let transport: StatelessHTTPServerTransport
    private var isStarted = false

    /// - Parameters:
    ///   - broker: The tool implementation.
    ///   - port: The bound loopback port. Origin/Host validation is pinned to it,
    ///     which is the spec's DNS-rebinding defence.
    ///   - version: Server version reported during `initialize`.
    init(broker: any BrokerServiceProtocol, port: UInt16, version: String = BrokerMCPServer.appVersion) {
        self.broker = broker
        self.server = MCP.Server(
            name: BrokerMCPServer.serverName,
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        // The SDK's default pipeline, with Origin/Host pinned to the real port.
        // Deliberately not stricter: OriginValidator checks Host always and
        // Origin only when present, because non-browser MCP clients send none.
        self.transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: Int(port)),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func start() async throws {
        guard !isStarted else { return }
        let broker = self.broker

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                BrokerMCPServer.pickTool,
                BrokerMCPServer.statusTool,
                BrokerMCPServer.downTool,
                BrokerMCPServer.upTool,
                BrokerMCPServer.refreshTool,
                BrokerMCPServer.reportTool,
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case BrokerMCPServer.pickToolName:
                return try await BrokerMCPServer.handlePick(params, broker: broker)
            case BrokerMCPServer.statusToolName:
                return try await BrokerMCPServer.handleStatus(broker: broker)
            case BrokerMCPServer.downToolName:
                return try await BrokerMCPServer.handleDown(params, broker: broker)
            case BrokerMCPServer.upToolName:
                return try await BrokerMCPServer.handleUp(params, broker: broker)
            case BrokerMCPServer.refreshToolName:
                return try await BrokerMCPServer.handleRefresh(broker: broker)
            case BrokerMCPServer.reportToolName:
                return try await BrokerMCPServer.handleReport(params, broker: broker)
            default:
                throw MCPError.invalidParams("Unknown tool '\(params.name)'")
            }
        }

        try await server.start(transport: transport)
        isStarted = true
    }

    func stop() async {
        await server.stop()
        isStarted = false
    }

    /// Bridges a parsed HTTP request into the MCP transport.
    func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        await transport.handleRequest(request)
    }

    // MARK: - Tools

    static let pickToolName = "pick"

    static var pickTool: Tool {
        Tool(
            name: pickToolName,
            description: """
            Pick a model/route for a unit of work, given a task role. \
            The decision may carry an optional `effort` recommendation \
            (low|medium|high|xhigh), at top level and inside `invocation`; \
            an omitted `effort` means the provider default/adaptive setting.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("Task role, e.g. planning or execution"),
                    ]),
                    "caller": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Invoking harness id; defaults to \(BrokerPolicy.defaultCaller). Echoed back in the decision."
                        ),
                    ]),
                ]),
                "required": .array([.string("role")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func handlePick(
        _ params: CallTool.Parameters,
        broker: any BrokerServiceProtocol
    ) async throws -> CallTool.Result {
        guard let role = params.arguments?["role"]?.stringValue,
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPError.invalidParams("'role' is required and must be a non-empty string")
        }
        let caller = params.arguments?["caller"]?.stringValue

        do {
            let decision = try await broker.pick(role: role, caller: caller)
            return CallTool.Result(
                content: [.text(text: try decision.jsonString(), annotations: nil, _meta: nil)],
                isError: false
            )
        } catch let error as BrokerError {
            // Policy-level failures are tool errors, not protocol errors: the
            // client gets a readable message and can pick a different role.
            return CallTool.Result(
                content: [
                    .text(
                        text: error.errorDescription ?? "Broker error",
                        annotations: nil,
                        _meta: nil
                    )
                ],
                isError: true
            )
        }
    }

    // MARK: - status

    static let statusToolName = "status"

    static var statusTool: Tool {
        Tool(
            name: statusToolName,
            description: "Server, oracle freshness, cooldowns, T3 reachability and recent-picks summary.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func handleStatus(broker: any BrokerServiceProtocol) async throws -> CallTool.Result {
        let status = await broker.status()
        return CallTool.Result(
            content: [.text(text: try status.jsonString(), annotations: nil, _meta: nil)],
            isError: false
        )
    }

    // MARK: - down

    static let downToolName = "down"

    static var downTool: Tool {
        Tool(
            name: downToolName,
            description: """
            Mark a route/candidate/instance unavailable for future picks. \
            `target` is a cooldown key: a full candidate id (e.g. t3:claude_autimo/claude-fable-5), \
            an instance-resolved id, or a bare route (e.g. t3). `minutes` clamps to 1...10080 and \
            defaults to 60; use \(Int(BrokerCooldownStore.defaultT3ExhaustionSeconds / 60)) minutes \
            to match the trixie-box CLI's own T3 credit-wall exhaustion cooldown.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Cooldown key: candidate id, resolved instance id, or bare route."),
                    ]),
                    "minutes": .object([
                        "type": .string("number"),
                        "description": .string("Cooldown length in minutes, clamped 1...10080. Defaults to 60."),
                    ]),
                ]),
                "required": .array([.string("target")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func handleDown(
        _ params: CallTool.Parameters,
        broker: any BrokerServiceProtocol
    ) async throws -> CallTool.Result {
        guard let target = params.arguments?["target"]?.stringValue,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPError.invalidParams("'target' is required and must be a non-empty string")
        }
        let minutes: Int?
        if let value = params.arguments?["minutes"] {
            if let integer = value.intValue {
                minutes = integer
            } else if let number = value.doubleValue,
                      number.isFinite,
                      let integer = Int(exactly: number) {
                minutes = integer
            } else {
                throw MCPError.invalidParams("'minutes' must be a finite whole number")
            }
        } else {
            minutes = nil
        }
        do {
            try await broker.down(target: target, minutes: minutes)
        } catch BrokerCooldownError.invalidTarget {
            throw MCPError.invalidParams("Invalid cooldown target")
        } catch BrokerCooldownError.capacityExceeded {
            throw MCPError.invalidParams("Cooldown entry limit reached")
        } catch {
            throw MCPError.internalError("Failed to update cooldown")
        }
        return CallTool.Result(
            content: [.text(text: "\(target) marked down", annotations: nil, _meta: nil)],
            isError: false
        )
    }

    // MARK: - up

    static let upToolName = "up"

    static var upTool: Tool {
        Tool(
            name: upToolName,
            description: "Restore a route/candidate/instance to immediate availability.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("The same cooldown key passed to `down`."),
                    ]),
                ]),
                "required": .array([.string("target")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func handleUp(
        _ params: CallTool.Parameters,
        broker: any BrokerServiceProtocol
    ) async throws -> CallTool.Result {
        guard let target = params.arguments?["target"]?.stringValue,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPError.invalidParams("'target' is required and must be a non-empty string")
        }
        do {
            try await broker.up(target: target)
        } catch BrokerCooldownError.invalidTarget {
            throw MCPError.invalidParams("Invalid cooldown target")
        } catch BrokerCooldownError.capacityExceeded {
            throw MCPError.invalidParams("Cooldown entry limit reached")
        } catch {
            throw MCPError.internalError("Failed to update cooldown")
        }
        return CallTool.Result(
            content: [.text(text: "\(target) marked up", annotations: nil, _meta: nil)],
            isError: false
        )
    }

    // MARK: - refresh

    static let refreshToolName = "refresh"

    static var refreshTool: Tool {
        Tool(
            name: refreshToolName,
            description: "Re-poll quota and T3 reachability. Explicit slow path — `pick` never triggers this.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func handleRefresh(broker: any BrokerServiceProtocol) async throws -> CallTool.Result {
        do {
            try await broker.refresh()
            return CallTool.Result(
                content: [.text(text: "refreshed", annotations: nil, _meta: nil)],
                isError: false
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - report

    static let reportToolName = "report"

    static var reportTool: Tool {
        Tool(
            name: reportToolName,
            description: "Attach a bounded started or terminal outcome to a broker decision.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "decision_id": .object(["type": .string("string"), "maxLength": .int(128)]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(BrokerLifecycleStatus.allCases.map { .string($0.rawValue) }),
                    ]),
                    "thread_id": .object(["type": .string("string"), "maxLength": .int(128)]),
                    "session_id": .object(["type": .string("string"), "maxLength": .int(128)]),
                    "duration_ms": integerSchema(maximum: 604_800_000),
                    "actual_input_tokens": integerSchema(maximum: 2_147_483_647),
                    "actual_cached_input_tokens": integerSchema(maximum: 2_147_483_647),
                    "actual_cache_creation_input_tokens": integerSchema(maximum: 2_147_483_647),
                    "actual_output_tokens": integerSchema(maximum: 2_147_483_647),
                    "actual_reasoning_tokens": integerSchema(maximum: 2_147_483_647),
                    "failure_reason": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("decision_id"), .string("status")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private static func integerSchema(maximum: Int) -> Value {
        .object([
            "type": .string("integer"),
            "minimum": .int(0),
            "maximum": .int(maximum),
        ])
    }

    private static func handleReport(
        _ params: CallTool.Parameters,
        broker: any BrokerServiceProtocol
    ) async throws -> CallTool.Result {
        let allowedFields: Set<String> = [
            "decision_id", "status", "thread_id", "session_id", "duration_ms",
            "actual_input_tokens", "actual_cached_input_tokens",
            "actual_cache_creation_input_tokens", "actual_output_tokens",
            "actual_reasoning_tokens", "failure_reason",
        ]
        guard let arguments = params.arguments,
              Set(arguments.keys).isSubset(of: allowedFields),
              let rawDecisionID = arguments["decision_id"]?.stringValue,
              let decisionID = normalizedIdentifier(rawDecisionID),
              let statusValue = arguments["status"]?.stringValue,
              let status = BrokerLifecycleStatus(rawValue: statusValue) else {
            throw invalidReportParams()
        }
        let threadID = try normalizedOptionalIdentifier(arguments["thread_id"])
        let sessionID = try normalizedOptionalIdentifier(arguments["session_id"])
        let durationMS = try boundedInteger(arguments["duration_ms"], maximum: 604_800_000)
        let actualInputTokens = try boundedInteger(
            arguments["actual_input_tokens"], maximum: 2_147_483_647
        )
        let actualCachedInputTokens = try boundedInteger(
            arguments["actual_cached_input_tokens"], maximum: 2_147_483_647
        )
        let actualCacheCreationInputTokens = try boundedInteger(
            arguments["actual_cache_creation_input_tokens"], maximum: 2_147_483_647
        )
        let actualOutputTokens = try boundedInteger(
            arguments["actual_output_tokens"], maximum: 2_147_483_647
        )
        let actualReasoningTokens = try boundedInteger(
            arguments["actual_reasoning_tokens"], maximum: 2_147_483_647
        )
        if let actualReasoningTokens {
            guard let actualOutputTokens, actualReasoningTokens <= actualOutputTokens else {
                throw invalidReportParams()
            }
        }

        let hasOutcome = durationMS != nil || actualInputTokens != nil
            || actualCachedInputTokens != nil || actualCacheCreationInputTokens != nil
            || actualOutputTokens != nil || actualReasoningTokens != nil
        let failureReason: String?
        if let value = arguments["failure_reason"] {
            guard let raw = value.stringValue,
                  status == .failed || status == .exhausted,
                  let sanitized = sanitizedFailureReason(raw) else {
                throw invalidReportParams()
            }
            failureReason = sanitized
        } else {
            failureReason = nil
        }
        guard status != .started || (!hasOutcome && failureReason == nil),
              status != .completed || failureReason == nil else {
            throw invalidReportParams()
        }

        let report = BrokerLifecycleReport(
            decisionID: decisionID,
            status: status,
            threadID: threadID,
            sessionID: sessionID,
            durationMS: durationMS,
            actualInputTokens: actualInputTokens,
            actualCachedInputTokens: actualCachedInputTokens,
            actualCacheCreationInputTokens: actualCacheCreationInputTokens,
            actualOutputTokens: actualOutputTokens,
            actualReasoningTokens: actualReasoningTokens,
            failureReason: failureReason
        )

        do {
            let result = try await broker.reportLifecycle(report)
            return CallTool.Result(
                content: [.text(text: result.rawValue, annotations: nil, _meta: nil)],
                isError: false
            )
        } catch {
            throw MCPError.internalError("Failed to record lifecycle report")
        }
    }

    private static func invalidReportParams() -> MCPError {
        .invalidParams("Invalid lifecycle report parameters")
    }

    private static func normalizedOptionalIdentifier(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        guard let raw = value.stringValue, let normalized = normalizedIdentifier(raw) else {
            throw invalidReportParams()
        }
        return normalized
    }

    private static func normalizedIdentifier(_ value: String) -> String? {
        BrokerLifecycleText.normalizedIdentifier(value)
    }

    private static func boundedInteger(_ value: Value?, maximum: Int) throws -> Int? {
        guard let value else { return nil }
        let integer: Int?
        if let int = value.intValue {
            integer = int
        } else if let double = value.doubleValue, double.isFinite {
            integer = Int(exactly: double)
        } else {
            integer = nil
        }
        guard let integer, 0...maximum ~= integer else { throw invalidReportParams() }
        return integer
    }

    private static func sanitizedFailureReason(_ value: String) -> String? {
        BrokerLifecycleText.sanitizedFailureReason(value)
    }
}

extension BrokerMCPServer {
    /// Assembles the whole loopback stack: a listener bound to 127.0.0.1 whose
    /// MCP server is configured for the port the listener actually got.
    static func makeLoopbackServer(
        broker: any BrokerServiceProtocol,
        port: UInt16,
        version: String = BrokerMCPServer.appVersion
    ) -> LoopbackHTTPServer {
        LoopbackHTTPServer(port: port, path: endpointPath) { resolvedPort in
            LoopbackRequestHandler { request in
                let mcpServer = BrokerMCPServer(broker: broker, port: resolvedPort, version: version)
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
    }
}
