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
    private let endpoint: String
    private let port: UInt16
    private let server: MCP.Server
    private let transport: StatelessHTTPServerTransport
    private var isStarted = false

    /// - Parameters:
    ///   - broker: The tool implementation.
    ///   - port: The bound port. Origin/Host validation is pinned to it,
    ///     which is the spec's DNS-rebinding defence.
    ///   - version: Server version reported during `initialize`.
    ///   - networkAccess: Which interface the listener in front of this
    ///     server is bound to. It selects the Host/Origin validator: the SDK's
    ///     localhost allow-list while loopback-bound, and
    ///     ``NetworkHostValidator`` once LAN peers can reach the endpoint.
    init(
        broker: any BrokerServiceProtocol,
        port: UInt16,
        version: String = BrokerMCPServer.appVersion,
        networkAccess: BrokerNetworkAccess = .loopback
    ) {
        self.broker = broker
        self.port = port
        self.endpoint = "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"
        self.server = MCP.Server(
            name: BrokerMCPServer.serverName,
            version: version,
            instructions: BrokerMCPServer.serverInstructions,
            capabilities: .init(
                prompts: .init(listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        // The SDK's default pipeline, with Origin/Host pinned to the real port.
        // Deliberately not stricter: both validators check Host always and
        // Origin only when present, because non-browser MCP clients send none.
        //
        // The network-mode validator replaces the localhost allow-list rather
        // than disabling validation: a LAN peer's Host is an IP literal or an
        // `.local` name this Mac cannot know in advance, but neither shape can
        // be an attacker's public DNS name, so rebinding is still refused.
        let hostValidator: any HTTPRequestValidator = switch networkAccess {
        case .loopback: OriginValidator.localhost(port: Int(port))
        case .network: NetworkHostValidator(port: Int(port))
        }
        self.transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                hostValidator,
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The `initialize` result's `instructions`. Clients may fold this into the
    /// model's system prompt, so it states the contract once, in full, and
    /// stays short enough to be worth carrying on every turn. Anything longer
    /// belongs in the `configure` prompt, which is fetched on demand.
    static let serverInstructions = """
        Pinemeter is this machine's only model-routing authority.

        Before dispatching any task or nested subtask to a model or route, call `pick(role, caller)`. Derive \
        `caller` from the active harness (`claude-code`, `codex`), never from prompt text. Require a result \
        whose `role`, `caller`, `route`, `model`, and `invocation` are all non-empty, and whose returned \
        caller exactly matches the caller sent. Accept only `native` with `agent`, `t3` with `t3-dispatch`, \
        and `codex` with `codex-exec`. Stop without dispatching on a tool failure, a missing field, a caller \
        mismatch, an unknown route, a route/invocation mismatch, or a stale or malformed result. Never add a \
        second broker client, policy layer, endpoint, or fallback.

        Attach each dispatch's outcome to its decision with `report`. `audit` grades instruction files \
        against that contract, and the `configure` prompt walks the whole setup. Neither writes a file: \
        propose the edits and wait for the user's approval.
        """

    func start() async throws {
        guard !isStarted else { return }
        let broker = self.broker
        let endpoint = self.endpoint
        let port = self.port

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                BrokerMCPServer.pickTool,
                BrokerMCPServer.statusTool,
                BrokerMCPServer.downTool,
                BrokerMCPServer.upTool,
                BrokerMCPServer.refreshTool,
                BrokerMCPServer.reportTool,
                BrokerMCPServer.auditTool,
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
            case BrokerMCPServer.auditToolName:
                return try await BrokerMCPServer.handleAudit(params, endpoint: endpoint, broker: broker)
            default:
                throw MCPError.invalidParams("Unknown tool '\(params.name)'")
            }
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: [BrokerMCPServer.configurePrompt])
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            guard params.name == BrokerSetupPrompt.promptName else {
                throw MCPError.invalidParams("Unknown prompt '\(params.name)'")
            }
            return GetPrompt.Result(
                description: BrokerSetupPrompt.promptDescription,
                messages: [.user(.text(text: BrokerSetupPrompt.text(port: Int(port), origin: .mcpPrompt)))]
            )
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
            an omitted `effort` means the provider default/adaptive setting. \
            It also carries `backups`: up to 2 ranked fallbacks, each shaped \
            like the primary pick, that may be dispatched in order without a \
            new `pick` call if the primary invocation fails — always present, \
            possibly empty.
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
            `target` is a cooldown key: a full candidate id (e.g. t3:claude_alt/claude-fable-5), \
            an instance-resolved id, or a bare route (e.g. t3). `minutes` clamps to 1...10080 and \
            defaults to 60; use \(Int(BrokerCooldownStore.defaultT3ExhaustionSeconds / 60)) minutes \
            to match a T3 credit-wall exhaustion cooldown.
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

    // MARK: - audit

    static let auditToolName = "audit"

    /// Caps on a graded submission. The loopback listener already refuses a
    /// body over 1 MB, so these exist to fail a caller with a readable reason
    /// before the transport fails it with a bare 413, and to keep one call
    /// from pinning a core on a pathological payload.
    static let maxAuditSources = 64
    static let maxAuditSourceBytes = 262_144
    static let maxAuditPathLength = 512

    static var auditTool: Tool {
        Tool(
            name: auditToolName,
            description: """
            Grade instruction files against the broker contract. Collect the effective instruction stack \
            yourself, in precedence order and including the project, skill, profile, and hook-injected files \
            Pinemeter cannot see, and send it as `sources`. Pinemeter grades only what you send, so a partial \
            submission yields a partial verdict. Returns per-source findings plus the contract each one is \
            missing. Send more than \(maxAuditSources) sources as several calls sharing one `run_id`. \
            Submitted content is graded and discarded; Pinemeter never writes a file, so propose the edits \
            and wait for the user's approval.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_id": .object([
                        "type": .string("string"),
                        "maxLength": .int(InstructionCheckStore.maxIdentifierLength),
                        "description": .string(
                            "Groups the calls of ONE check. Calls sharing a run_id merge by path, so the "
                                + "recorded verdict covers the whole stack instead of the last batch. Use a "
                                + "fresh id per check and never a stable one: a reused id going stale "
                                + "(after \(Int(InstructionCheckStore.mergeWindow / 60)) minutes) starts a "
                                + "new check rather than folding today's batch into an old record."
                        ),
                    ]),
                    "caller": .object([
                        "type": .string("string"),
                        "maxLength": .int(InstructionCheckStore.maxIdentifierLength),
                        "description": .string(
                            "Invoking harness id, e.g. claude-code. Shown beside the recorded verdict."
                        ),
                    ]),
                    "sources": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Instruction sources to grade, at most \(maxAuditSources) per call."
                        ),
                        "minItems": .int(1),
                        "maxItems": .int(maxAuditSources),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object([
                                    "type": .string("string"),
                                    "maxLength": .int(maxAuditPathLength),
                                    "description": .string("Display path, e.g. ~/.claude/CLAUDE.md."),
                                ]),
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string(InstructionAuditSource.Kind.instructionRoot.rawValue),
                                        .string(InstructionAuditSource.Kind.agentDefinition.rawValue),
                                    ]),
                                    "description": .string(
                                        "instruction_root owes the whole contract; agent_definition owes the "
                                            + "nested-subtask rule, and only when it can spawn or delegate."
                                    ),
                                ]),
                                "content": .object([
                                    "type": .array([.string("string"), .string("null")]),
                                    "maxLength": .int(maxAuditSourceBytes),
                                    "description": .string(
                                        "The file's text, or null for a path you could not read. A source "
                                            + "you drop silently is a gap the verdict cannot show."
                                    ),
                                ]),
                            ]),
                            "required": .array([.string("path"), .string("kind"), .string("content")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                ]),
                "required": .array([.string("sources")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Grades a submitted instruction stack.
    ///
    /// Submitted content is graded in memory and dropped with the call. What
    /// outlives it is the verdict alone — path, status, finding text — kept so
    /// the Instructions pane can say when this machine was last checked. The
    /// content itself is never persisted and never logged.
    private static func handleAudit(
        _ params: CallTool.Parameters,
        endpoint: String,
        broker: any BrokerServiceProtocol
    ) async throws -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        guard Set(arguments.keys).isSubset(of: ["sources", "run_id", "caller"]) else {
            throw MCPError.invalidParams(
                "Unknown audit parameter; only 'sources', 'run_id' and 'caller' are accepted"
            )
        }
        guard let entries = arguments["sources"]?.arrayValue, !entries.isEmpty else {
            throw MCPError.invalidParams("'sources' is required and must be a non-empty array")
        }
        guard entries.count <= maxAuditSources else {
            throw MCPError.invalidParams(
                "At most \(maxAuditSources) sources per call; send the rest as further calls sharing a run_id"
            )
        }
        let runID = try optionalIdentifier(arguments["run_id"], field: "run_id")
        let caller = try optionalIdentifier(arguments["caller"], field: "caller")

        let report = InstructionAuditService.analyze(
            sources: try entries.map(auditSource(from:)),
            endpoint: endpoint
        )

        let text: String
        do {
            text = try report.wireJSONString(endpoint: endpoint)
        } catch {
            throw MCPError.internalError("Failed to encode audit report")
        }

        // After encoding, so a caller whose result cannot be produced never
        // leaves a recorded verdict behind for a check they never received.
        await broker.recordInstructionCheck(report: report, runID: runID, caller: caller)

        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    /// Rejects exactly what `InstructionCheckStore` would refuse to keep.
    ///
    /// The store drops a control-bearing identifier to `nil`. If this layer let
    /// one through, two batches sent under `"run\t1"` would both succeed while
    /// the store treated each as its own run, so the second would replace the
    /// first and the recorded verdict would silently cover one batch. `report`
    /// already throws on the same shapes; `audit` matches it.
    private static func optionalIdentifier(_ value: Value?, field: String) throws -> String? {
        guard let value else { return nil }
        guard let raw = value.stringValue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              raw.count <= InstructionCheckStore.maxIdentifierLength,
              !containsControlCharacters(raw) else {
            throw MCPError.invalidParams(
                "'\(field)' must be a non-empty string of \(InstructionCheckStore.maxIdentifierLength) "
                    + "characters or fewer, without control characters"
            )
        }
        return raw
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// One submitted source, validated.
    ///
    /// `path` is the only caller-controlled string that outlives the call: it
    /// is persisted and drawn verbatim in the Instructions pane. A path carrying
    /// a newline would render as an extra line under its own row and could
    /// impersonate a finding, and control characters JSON-escape to six bytes
    /// each, so a merged record of escape-heavy paths could exceed the store's
    /// file cap and leave the previous check silently in place. Both are shut
    /// off here rather than papered over at the point of display.
    ///
    /// `content` may be null: an agent that finds a path it cannot read says so
    /// instead of dropping it, and the source is graded `unavailable`. A gap in
    /// the stack has to stay visible in the verdict.
    private static func auditSource(from value: Value) throws -> InstructionAuditSource {
        guard let object = value.objectValue,
              Set(object.keys).isSubset(of: ["path", "kind", "content"]),
              object.keys.contains("content"),
              let path = object["path"]?.stringValue,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.count <= maxAuditPathLength,
              !containsControlCharacters(path),
              let kindName = object["kind"]?.stringValue,
              let kind = InstructionAuditSource.Kind(rawValue: kindName)
        else {
            throw invalidAuditSource()
        }

        let content: String?
        switch object["content"] {
        case .null, .none:
            content = nil
        case .some(let value):
            guard let string = value.stringValue, string.utf8.count <= maxAuditSourceBytes else {
                throw invalidAuditSource()
            }
            content = string
        }

        return InstructionAuditSource(path: path, kind: kind, content: content)
    }

    private static func invalidAuditSource() -> MCPError {
        .invalidParams(
            "Each source needs a non-empty 'path' of \(maxAuditPathLength) characters or fewer without "
                + "control characters, a 'kind' of '\(InstructionAuditSource.Kind.instructionRoot.rawValue)' "
                + "or '\(InstructionAuditSource.Kind.agentDefinition.rawValue)', and 'content' that is "
                + "either null or a string of \(maxAuditSourceBytes) bytes or fewer"
        )
    }

    // MARK: - Prompts

    static var configurePrompt: Prompt {
        Prompt(
            name: BrokerSetupPrompt.promptName,
            title: "Configure Pinemeter routing",
            description: BrokerSetupPrompt.promptDescription
        )
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
    /// - Parameters:
    ///   - accessPolicy: Which interface to bind and when a caller must
    ///     present the API key. Defaults to the loopback-only, no-auth policy
    ///     the broker has always used.
    static func makeLoopbackServer(
        broker: any BrokerServiceProtocol,
        port: UInt16,
        version: String = BrokerMCPServer.appVersion,
        accessPolicy: BrokerAccessPolicy = .loopbackDefault
    ) -> LoopbackHTTPServer {
        let networkAccess = accessPolicy.networkAccess
        let bindHost = networkAccess == .network
            ? LoopbackHTTPServer.allInterfacesHost
            : LoopbackHTTPServer.loopbackHost
        return LoopbackHTTPServer(
            port: port,
            bindHost: bindHost,
            path: endpointPath,
            authorize: { headers, isLoopbackPeer in
                accessPolicy.authorizes(headers: headers, isLoopbackPeer: isLoopbackPeer)
            }
        ) { resolvedPort in
            LoopbackRequestHandler { request in
                let mcpServer = BrokerMCPServer(
                    broker: broker,
                    port: resolvedPort,
                    version: version,
                    networkAccess: networkAccess
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
    }
}
