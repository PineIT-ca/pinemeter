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
            description: "Pick a model/route for a unit of work, given a task role.",
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
        await broker.down(target: target, minutes: minutes)
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
        await broker.up(target: target)
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
