import XCTest
@testable import Pinemeter

final class InstructionAuditServiceTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:43117/mcp"

    private var completeContract: String {
        """
        Register one MCP server named `pinemeter-broker` at `\(endpoint)`.
        Call `pick(role, caller)` and require that the returned caller exactly matches the caller sent.
        Accept only `native` with `agent`, `t3` with `t3-dispatch`, and `codex` with `codex-exec`.
        Stop without dispatching if the endpoint or result is unavailable, stale, or malformed.
        Pinemeter is the only model-routing authority. Never add another broker or fallback.
        Every task and every nested subtask that selects a model or route must call Pinemeter first and use `pick(role, caller)`.
        """
    }

    func test_completeInstructionRootPassesEveryDirective() {
        let report = InstructionAuditService.analyze(
            sources: [root("~/.claude/CLAUDE.md", completeContract)],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.sources.first?.status, .pass)
        XCTAssertEqual(report.sources.first?.findings, [])
    }

    func test_missingDirectiveNamesTheExactRequirement() {
        let source = completeContract.replacingOccurrences(
            of: "`codex` with `codex-exec`",
            with: "the Codex route"
        )

        let report = InstructionAuditService.analyze(
            sources: [root("~/.codex/AGENTS.md", source)],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .warning)
        XCTAssertEqual(
            report.sources.first?.findings,
            [InstructionAuditFinding(
                kind: .missingDirective,
                message: "Missing directive: codex / codex-exec route pair."
            )]
        )
    }

    func test_spawningAgentRequiresNestedBrokerPickGuidance() {
        let report = InstructionAuditService.analyze(
            sources: [agent("~/.codex/agents/worker.toml", "This agent can spawn subagents for bounded work.")],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.status, .warning)
        XCTAssertEqual(
            report.sources.first?.findings.first?.message,
            "Missing directive: nested-subtask broker selection."
        )
    }

    func test_nonSpawningAgentDoesNotRequireFullRootContract() {
        let report = InstructionAuditService.analyze(
            sources: [agent(
                "~/.codex/agents/reviewer.toml",
                "A review subagent. Spawned by the main workflow. Review the supplied files and report findings."
            )],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.status, .pass)
        XCTAssertEqual(report.sources.first?.findings, [])
    }

    func test_safeRetirementAndNoBypassRulesAreNotConflicts() {
        let report = InstructionAuditService.analyze(
            sources: [agent(
                "~/.codex/agents/reviewer.toml",
                "llmproxy is retired. Never run model-broker pick. Do not bypass Pinemeter."
            )],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.sources.first?.findings, [])
    }

    func test_conflictsReportEveryExplicitConflictInStableOrder() {
        let report = InstructionAuditService.analyze(
            sources: [agent(
                "~/.codex/agents/worker.toml",
                "Internal subagents do not go through the broker. Run scripts/model-broker pick, use llmproxy, or fall back to native."
            )],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .conflict)
        XCTAssertEqual(report.sources.first?.findings.map(\.message), [
            "Conflict: explicit Pinemeter broker bypass.",
            "Conflict: retired model-broker CLI guidance.",
            "Conflict: llmproxy route guidance.",
            "Conflict: native fallback guidance.",
        ])
    }

    func test_laterConflictOverridesEarlierCompleteContract() {
        let report = InstructionAuditService.analyze(
            sources: [
                root("~/.claude/CLAUDE.model-policy.md", completeContract),
                agent("~/.claude/agents/worker.md", "Delegate with a fallback to native."),
            ],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .conflict)
        XCTAssertEqual(report.sources.last?.path, "~/.claude/agents/worker.md")
        XCTAssertTrue(report.sources.last?.findings.contains {
            $0.message == "Conflict: native fallback guidance."
        } == true)
    }

    func test_missingFixedFilesAreUnavailableWithoutStoppingScan() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await InstructionAuditService(homeDirectory: home).audit(endpoint: endpoint)

        XCTAssertEqual(report.sources.count, 5)
        XCTAssertTrue(report.sources.allSatisfy { $0.status == .unavailable })
    }

    func test_symlinkedFixedFileIsUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("target.md")
        try completeContract.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("CLAUDE.md"),
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await InstructionAuditService(homeDirectory: home).audit(endpoint: endpoint)

        let source = try XCTUnwrap(report.sources.first { $0.path == "~/.claude/CLAUDE.md" })
        XCTAssertEqual(source.status, .unavailable)
    }

    func test_symlinkedAgentFileIsReportedUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agents = home.appendingPathComponent(".codex/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("target.toml")
        try "Agent(prompt:)".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: agents.appendingPathComponent("worker.toml"),
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await InstructionAuditService(homeDirectory: home).audit(endpoint: endpoint)

        let source = try XCTUnwrap(report.sources.first { $0.path == "~/.codex/agents/worker.toml" })
        XCTAssertEqual(source.status, .unavailable)
    }

    func test_sourceAndFindingOrderIsDeterministic() {
        let sources = [
            agent("z.toml", "Use llmproxy and fall back to native."),
            agent("a.md", "This agent can delegate work."),
        ]

        XCTAssertEqual(
            InstructionAuditService.analyze(sources: sources, endpoint: endpoint),
            InstructionAuditService.analyze(sources: sources.reversed(), endpoint: endpoint)
        )
    }

    private func root(_ path: String, _ content: String) -> InstructionAuditSource {
        InstructionAuditSource(path: path, kind: .instructionRoot, content: content)
    }

    private func agent(_ path: String, _ content: String) -> InstructionAuditSource {
        InstructionAuditSource(path: path, kind: .agentDefinition, content: content)
    }
}
