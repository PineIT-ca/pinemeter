import XCTest
@testable import Pinemeter

final class InstructionAuditServiceTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:43117/mcp"

    private var completeContract: String {
        """
        Register one MCP server named `pinemeter-broker` at `\(endpoint)`.
        Call `pick(role, caller)` and require that the returned caller exactly matches the caller sent.
        Choose role names from the broker status tool, including explore and verification.
        Accept `native` with `agent` and `t3` with `t3-dispatch`. When caller is codex, accept codex with agent; use codex with codex-exec for every other caller.
        In Codex, use the harness-native subagent tool with the returned model and optional effort. Give the child a self-contained prompt that preserves the nested Pinemeter `pick(role, caller)` requirement.
        Stop without dispatching if the endpoint or result is unavailable, stale, or malformed.
        Pinemeter is the only model-routing authority. Never add another broker or fallback.
        Every task and every nested subtask that selects a model or route must call Pinemeter first and use `pick(role, caller)`.
        A fresh explicit operator instruction may pass one `override_candidate`. Require `source: human-override`. It bypasses quota caps and pacing gates. Never infer, persist, or reuse it. Never bypass Pinemeter for an override.
        An explicit request for a Fable review passes `auto/claude-fable-5-1` as `override_candidate` and must not substitute another model.
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

    func test_missingRoleNamesDirectiveFailsOnlyThatDirective() {
        let source = completeContract.replacingOccurrences(
            of: "Choose role names from the broker status tool, including explore and verification.\n",
            with: ""
        )

        let report = InstructionAuditService.analyze(
            sources: [root("~/.codex/AGENTS.md", source)],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.findings, [InstructionAuditFinding(
            kind: .missingDirective,
            message: "Missing directive: role names from status."
        )])
    }

    func test_explicitFableReviewOverrideIsRequired() {
        let source = completeContract.replacingOccurrences(
            of: "An explicit request for a Fable review passes `auto/claude-fable-5-1` as `override_candidate` and must not substitute another model.",
            with: ""
        )

        let report = InstructionAuditService.analyze(
            sources: [root("~/.codex/AGENTS.md", source)],
            endpoint: endpoint
        )

        XCTAssertEqual(report.sources.first?.findings, [InstructionAuditFinding(
            kind: .missingDirective,
            message: "Missing directive: explicit Fable review override."
        )])
    }

    func test_setupPromptSatisfiesRoleNamesDirective() {
        let report = InstructionAuditService.analyze(
            sources: [root(
                "setup-prompt",
                BrokerSetupPrompt.text(port: 43117, origin: .pasteboard)
            )],
            endpoint: endpoint
        )

        XCTAssertFalse(report.sources.first?.findings.contains {
            $0.message == "Missing directive: role names from status."
        } ?? true)
    }

    /// The setup prompt is the text Pinemeter tells an operator to paste into
    /// their instruction root, and the audit is what later grades that root.
    /// If the two drift, Pinemeter ships a prompt its own audit rejects.
    func test_setupPromptSatisfiesExplicitFableReviewDirective() {
        let report = InstructionAuditService.analyze(
            sources: [root(
                "setup-prompt",
                BrokerSetupPrompt.text(port: 43117, origin: .pasteboard)
            )],
            endpoint: endpoint
        )

        XCTAssertFalse(report.sources.first?.findings.contains {
            $0.message == "Missing directive: explicit Fable review override."
        } ?? true)
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
        Choose role names from the broker status tool, including explore and
        verification.
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
        An explicit request for a Fable review passes `auto/claude-fable-5-1`
        as `override_candidate` and must not substitute another model.
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

    // MARK: - Reference crediting

    /// A pointer file that names a canonical policy path instead of repeating
    /// the contract is credited, not flagged, when that canonical file is
    /// submitted in the same call and passes.
    func test_pointerToAPassingCanonicalFileIsCredited() {
        let report = InstructionAuditService.analyze(
            sources: [
                root("~/.claude/CLAUDE.md", "Follow the broker contract at `~/.claude/universal/subagent-execution-policy.md`."),
                root("~/.claude/universal/subagent-execution-policy.md", completeContract),
            ],
            endpoint: endpoint
        )

        let pointer = try? XCTUnwrap(report.sources.first { $0.path == "~/.claude/CLAUDE.md" })
        XCTAssertEqual(pointer?.status, .credited)
        XCTAssertEqual(pointer?.findings, [InstructionAuditFinding(
            kind: .creditedReference,
            message: "Credited through reference to ~/.claude/universal/subagent-execution-policy.md, which passes."
        )])
        XCTAssertEqual(report.status, .pass, "a fully credited pointer does not demote the overall verdict")

        let canonical = try? XCTUnwrap(report.sources.first { $0.path == "~/.claude/universal/subagent-execution-policy.md" })
        XCTAssertEqual(canonical?.status, .pass)
    }

    /// The same pointer wording, but the file it names either was not
    /// submitted or itself fails: the missing-directive finding still stands.
    func test_pointerToAFailingOrUnsubmittedFileStillFlags() {
        let unsubmitted = InstructionAuditService.analyze(
            sources: [
                root("~/.claude/CLAUDE.md", "Follow the broker contract at `~/.claude/universal/subagent-execution-policy.md`."),
            ],
            endpoint: endpoint
        )
        XCTAssertEqual(unsubmitted.sources.first?.status, .warning)
        XCTAssertFalse(unsubmitted.sources.first?.findings.contains { $0.kind == .creditedReference } ?? true)

        let failingReferent = InstructionAuditService.analyze(
            sources: [
                root("~/.claude/CLAUDE.md", "Follow the broker contract at `~/.claude/universal/subagent-execution-policy.md`."),
                root("~/.claude/universal/subagent-execution-policy.md", "Pinemeter is the only model-routing authority."),
            ],
            endpoint: endpoint
        )
        let pointer = try? XCTUnwrap(failingReferent.sources.first { $0.path == "~/.claude/CLAUDE.md" })
        XCTAssertEqual(pointer?.status, .warning)
        XCTAssertFalse(pointer?.findings.contains { $0.kind == .creditedReference } ?? true)
    }

    /// A conflict is never washed out by a reference, even alongside a
    /// pointer to a passing canonical file in the same source.
    func test_conflictAlongsideAPointerStillConflicts() {
        let report = InstructionAuditService.analyze(
            sources: [
                agent(
                    "~/.codex/agents/worker.toml",
                    "See `~/.claude/universal/subagent-execution-policy.md`. Internal subagents do not go through the broker."
                ),
                root("~/.claude/universal/subagent-execution-policy.md", completeContract),
            ],
            endpoint: endpoint
        )

        let worker = try? XCTUnwrap(report.sources.first { $0.path == "~/.codex/agents/worker.toml" })
        XCTAssertEqual(worker?.status, .conflict)
        XCTAssertEqual(worker?.findings, [InstructionAuditFinding(
            kind: .conflict,
            message: "Conflict: explicit Pinemeter broker bypass."
        )])
        XCTAssertEqual(report.status, .conflict)
    }

    /// A path mentioned inside a longer path is not a reference to it.
    func test_referenceMustNameTheWholePath() {
        let report = InstructionAuditService.analyze(
            sources: [
                root("AGENTS.md", "See `~/.codex/AGENTS.md` for the routing rules."),
                root("agents.md", completeContract),
            ],
            endpoint: endpoint
        )

        let pointer = try? XCTUnwrap(report.sources.first { $0.path == "AGENTS.md" })
        XCTAssertEqual(pointer?.status, .warning)
        XCTAssertFalse(pointer?.findings.contains { $0.kind == .creditedReference } ?? true)
    }

    /// Dot-directory paths, `@` imports, fragments and line suffixes still
    /// name the file.
    func test_referenceFormsThatStillNameTheFileAreCredited() {
        for (pointerPath, referentPath, pointerText) in [
            ("CLAUDE.md", ".claude/agents/worker.md", "Subagents follow .claude/agents/worker.md."),
            ("CLAUDE.md", "~/.claude/RTK.md", "@~/.claude/RTK.md"),
            ("CLAUDE.md", "policy.md", "See [routing](policy.md#routing)."),
            ("CLAUDE.md", "agents.md", "The contract starts at agents.md:12."),
            ("CLAUDE.md", "routing.md", "See routing.md:12:5 for the rule."),
        ] {
            let report = InstructionAuditService.analyze(
                sources: [root(pointerPath, pointerText), root(referentPath, completeContract)],
                endpoint: endpoint
            )
            let pointer = report.sources.first { $0.path == pointerPath }
            XCTAssertEqual(pointer?.status, .credited, pointerText)
        }
    }

    /// A non-ASCII numeric suffix is not a line number, so it stays part of
    /// the token and does not name the file.
    func test_nonASCIINumericSuffixIsNotALineNumber() {
        let report = InstructionAuditService.analyze(
            sources: [root("CLAUDE.md", "See agents.md:五."), root("agents.md", completeContract)],
            endpoint: endpoint
        )
        XCTAssertEqual(report.sources.first { $0.path == "CLAUDE.md" }?.status, .warning)
    }

    /// Markdown links and trailing punctuation still count as naming the path.
    func test_referenceInsideALinkOrBeforePunctuationIsCredited() {
        for pointerText in [
            "Read [the policy](~/.claude/universal/subagent-execution-policy.md) first.",
            "The contract lives in ~/.claude/universal/subagent-execution-policy.md.",
        ] {
            let report = InstructionAuditService.analyze(
                sources: [
                    root("~/.claude/CLAUDE.md", pointerText),
                    root("~/.claude/universal/subagent-execution-policy.md", completeContract),
                ],
                endpoint: endpoint
            )
            let pointer = report.sources.first { $0.path == "~/.claude/CLAUDE.md" }
            XCTAssertEqual(pointer?.status, .credited, pointerText)
        }
    }

    /// A passing source lends only the directives it covers itself.
    func test_partialCoverageCreditsOnlyWhatTheReferentCovers() {
        let report = InstructionAuditService.analyze(
            sources: [
                root("~/.claude/CLAUDE.md", "Subagents follow `~/.claude/agents/worker.md`."),
                agent(
                    "~/.claude/agents/worker.md",
                    "Call Pinemeter with pick(role, caller) before every nested subtask."
                ),
            ],
            endpoint: endpoint
        )

        let pointer = try? XCTUnwrap(report.sources.first { $0.path == "~/.claude/CLAUDE.md" })
        XCTAssertEqual(pointer?.status, .warning)
        let credited = pointer?.findings.filter { $0.kind == .creditedReference } ?? []
        let missing = pointer?.findings.filter { $0.kind == .missingDirective } ?? []
        XCTAssertEqual(credited.count, 1)
        XCTAssertEqual(missing.count, 12, "the referent lends only the nested-subtask directive")
        XCTAssertFalse(missing.contains { $0.message.contains("nested-subtask broker selection") })
    }

    /// Caller-chosen long paths against maximum-size sources must stay cheap:
    /// the reference scan is linear, not a substring search per path.
    func test_adversarialPathsAndSourcesGradeQuickly() {
        let longPath = { (i: Int) in String(repeating: "a", count: 500) + "b\(i)" }
        var sources = (0..<8).map { root(longPath($0), completeContract) }
        let filler = String(repeating: "a", count: BrokerMCPServer.maxAuditSourceBytes)
        sources += (0..<8).map { root("filler-\($0).md", filler) }

        let start = Date()
        let report = InstructionAuditService.analyze(sources: sources, endpoint: endpoint)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(report.sources.count, 16)
        XCTAssertLessThan(elapsed, 10, "the reference scan must not be quadratic in path and source size")
    }

    private func root(_ path: String, _ content: String) -> InstructionAuditSource {
        InstructionAuditSource(path: path, kind: .instructionRoot, content: content)
    }

    private func agent(_ path: String, _ content: String) -> InstructionAuditSource {
        InstructionAuditSource(path: path, kind: .agentDefinition, content: content)
    }
}
