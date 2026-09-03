import XCTest
@testable import Pinemeter

final class InstructionAuditServiceTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:43117/mcp"

    private var completeContract: String {
        """
        Register one MCP server named `pinemeter-broker` at `\(endpoint)`.
        Call `pick(role, caller)` and require that the returned caller exactly matches the caller sent.
        Accept `native` with `agent` and `t3` with `t3-dispatch`. When caller is codex, accept codex with agent; use codex with codex-exec for every other caller.
        In Codex, use the harness-native subagent tool with the returned model and optional effort. Give the child a self-contained prompt that preserves the nested Pinemeter `pick(role, caller)` requirement.
        Stop without dispatching if the endpoint or result is unavailable, stale, or malformed.
        Pinemeter is the only model-routing authority. Never add another broker or fallback.
        Every task and every nested subtask that selects a model or route must call Pinemeter first and use `pick(role, caller)`.
        A fresh explicit operator instruction may pass one `override_candidate`. Require `source: human-override`. It bypasses quota caps and pacing gates. Never infer, persist, or reuse it. Never bypass Pinemeter for an override.
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
            of: "When caller is codex, accept codex with agent; use codex with codex-exec for every other caller.",
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
                message: "Missing directive: caller-aware codex invocation."
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

    func test_lineWrappedDirectivesStillCountAsPresent() {
        let wrapped = """
        Register one MCP server named `pinemeter-broker` at `\(endpoint)`.
        Call `pick(role, caller)` and require that the returned caller exactly
        matches the caller sent.
        Accept `native` with `agent` and `t3` with `t3-dispatch`. When caller is
        codex, accept codex with agent; use codex with codex-exec for every other
        caller. In Codex, use the harness-native subagent tool with the returned
        model and optional effort. Give the child a self-contained prompt that
        preserves the nested Pinemeter `pick(role, caller)` requirement.
        Stop without dispatching if the endpoint or result is unavailable.
        Pinemeter is the only model-routing authority. Do not add
        another broker, endpoint, or fallback.
        Before every task and every nested subtask that selects a route, call
        Pinemeter first with `pick(role, caller)`.
        A fresh explicit operator instruction may pass `override_candidate`.
        Require `source: human-override`. It bypasses quota caps and pacing gates.
        Never infer or persist it. Never bypass Pinemeter for an override.
        """

        let report = InstructionAuditService.analyze(
            sources: [root("~/.claude/universal/subagent-execution-policy.md", wrapped)],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.findings, [])
        XCTAssertEqual(report.status, .pass)
    }

    func test_pluralTaskShorthandIsNotASpawner() {
        let report = InstructionAuditService.analyze(
            sources: [agent(
                "~/.codex/agents/plan-checker.toml",
                "For each requirement, find covering task(s) in the plan and flag gaps."
            )],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.status, .pass)
    }

    func test_passiveSpawnReferenceIsNotASpawner() {
        let report = InstructionAuditService.analyze(
            sources: [agent(
                "~/.codex/agents/advisor-researcher.toml",
                "Spawned by `discuss-phase` via `Task()`. Return structured output for the "
                    + "orchestrator, which spawns the next agent."
            )],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.status, .pass)
    }

    func test_declaredToolsDecideSpawnerStatusOverProse() {
        let report = InstructionAuditService.analyze(
            sources: [
                agent(
                    "~/.claude/agents/debugger.md",
                    "tools: Read, Write, Bash, Grep\nThe caller spawns a fresh continuation agent."
                ),
                agent(
                    "~/.codex/agents/session-manager.toml",
                    "tools = [\"Read\", \"Agent\"]\nRun the debug loop."
                ),
            ],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.path, "~/.claude/agents/debugger.md")
        XCTAssertEqual(report.sources.first?.status, .pass)
        XCTAssertEqual(report.sources.last?.status, .warning)
        XCTAssertEqual(
            report.sources.last?.findings.first?.message,
            "Missing directive: nested-subtask broker selection."
        )
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

    /// A source the caller could not read is reported, not dropped. The agent
    /// sends `content: null` for a path it could not open, and a gap in the
    /// stack has to stay visible in the verdict.
    func test_unreadableSourceIsUnavailableWithoutStoppingTheGrade() {
        let report = InstructionAuditService.analyze(
            sources: [
                InstructionAuditSource(path: "~/.claude/CLAUDE.md", kind: .instructionRoot, content: nil),
                root("~/.codex/AGENTS.md", completeContract),
            ],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.status, .unavailable)
        XCTAssertEqual(report.sources.first?.findings.first?.kind, .unavailable)
        XCTAssertEqual(report.sources.last?.status, .pass)
        XCTAssertEqual(report.status, .warning, "one unreadable source among passes is a gap, not a pass")
    }

    func test_everySourceUnreadableIsUnavailableOverall() {
        let report = InstructionAuditService.analyze(
            sources: [
                InstructionAuditSource(path: "a.md", kind: .instructionRoot, content: nil),
                InstructionAuditSource(path: "b.md", kind: .agentDefinition, content: nil),
            ],
            endpoint: endpoint
        )

        XCTAssertEqual(report.status, .unavailable)
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
