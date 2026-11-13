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
        An explicit request for a Fable review passes `auto/claude-fable-5-2` as `override_candidate` and must not substitute another model.
        """
    }

    func test_t3DelegateRequiresConsumerParentValidation() {
        let report = InstructionAuditService.analyze(
            sources: [root("contract", completeContract + "\nAccept t3 with t3-delegate.")],
            endpoint: endpoint
        )
        XCTAssertEqual(report.status, .warning)
        XCTAssertEqual(report.sources.first?.findings.map(\.message), [
            "Missing directive: conditional T3 delegation.",
            "Missing directive: T3 delegated task lifecycle.",
        ])
    }

    func test_setupPromptSatisfiesT3DelegatedLifecycleDirective() {
        for origin in [BrokerSetupPromptOrigin.pasteboard, .mcpPrompt] {
            let report = InstructionAuditService.analyze(
                sources: [root("setup-prompt", BrokerSetupPrompt.text(port: 43117, origin: origin))],
                endpoint: endpoint
            )
            XCTAssertFalse(report.sources.first?.findings.contains {
                $0.message == "Missing directive: T3 delegated task lifecycle."
            } ?? true)
        }
    }

    func test_t3DelegatedLifecycleRequiresEveryToken() {
        let tokens = [
            "t3role", "result_available", "haspendingchildruns", "haspendingquestion",
            "usage_limit", "usagelimitresetat", "failure_class",
        ]
        let contract = completeContract + "\nAccept t3 with t3-delegate for execution_context: t3-child after a nonempty parentThreadId check. "
            + "This is not parent authentication; delegate_task uses invocation.instanceId and invocation.model.\n"
            + tokens.joined(separator: " ").uppercased()
        let report = InstructionAuditService.analyze(
            sources: [root("contract", contract)], endpoint: endpoint
        )
        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.sources.first?.findings, [])
        for token in tokens {
            let source = contract.replacingOccurrences(of: token.uppercased(), with: "")
            let report = InstructionAuditService.analyze(
                sources: [root("contract", source)], endpoint: endpoint
            )
            XCTAssertEqual(report.sources.first?.findings.map(\.message), [
                "Missing directive: T3 delegated task lifecycle.",
            ], token)
        }
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
            of: "An explicit request for a Fable review passes `auto/claude-fable-5-2` as `override_candidate` and must not substitute another model.",
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
        An explicit request for a Fable review passes `auto/claude-fable-5-2`
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

    /// Same table, same order, as TestGradeLLMProxyConflictIgnoresWorkloadIdentity in Go.
    func test_llmproxyConflictIgnoresWorkloadIdentity() {
        let cases: [(text: String, flagged: Bool)] = [
            // Routing guidance and every other mention: flagged.
            ("Use the llmproxy secret for model calls.", true),
            ("Set OPENAI_API_KEY to the llmproxy secret.", true),
            ("Authenticate with the llmproxy secret, then send all model calls there.", true),
            ("Use the llmproxy certificate for mTLS and send model calls there.", true),
            ("PROVIDER=\"llmproxy\" SECRET=abc codex exec", true),
            ("model_provider = \"llmproxy\" secret = \"x\"", true),
            ("cannot authorize model routing through llmproxy.", true),
            ("Pinemeter does not authorize model routing through the llmproxy endpoint, use it.", true),
            ("Pinemeter does not authorize model routing to llmproxy/v1.", true),
            ("Internal subagents do not go through the broker. Run scripts/model-broker pick, use llmproxy, or fall back to native.", true),
            ("Use llmproxy and fall back to native.", true),
            ("Use llmproxy for model calls.", true),
            ("Route review work through llmproxy.", true),
            ("Dispatch via llmproxy when the broker is down.", true),
            ("Fallback route: the llmproxy endpoint at http://127.0.0.1:9000.", true),
            ("Use the llmproxy for model calls.", true),
            ("Use `llmproxy` for model calls.", true),
            ("Route review work through the llmproxy.", true),
            ("Route review work through `llmproxy`.", true),
            ("Dispatch via **llmproxy**.", true),
            ("Send picks to the llmproxy.", true),
            ("The `llmproxy` lane handles review work.", true),
            ("Set ANTHROPIC_BASE_URL=http://llmproxy:4000/v1 for all subagents.", true),
            ("base_url = \"http://llmproxy.llm.svc:4000\"", true),
            ("Fallback: llmproxy", true),
            ("Prefer llmproxy over the broker.", true),
            ("Call llmproxy directly for review.", true),
            ("Point codex at llmproxy.", true),
            ("Route review work through\nllmproxy.", true),
            ("model: llmproxy/claude-sonnet", true),
            ("If Pinemeter does not respond, fall back to llmproxy.", true),
            ("When the broker does not answer, use llmproxy.", true),
            ("Do not wait for the broker, use llmproxy.", true),
            ("Never call the provider directly, route through llmproxy.", true),
            ("Pinemeter is no longer required, use llmproxy.", true),
            ("You must not stop on a failed pick, dispatch via llmproxy instead.", true),
            ("VİA LLMPROXY", true),
            ("USE LLMPROXY", true),
            ("The old CLI was removed\nUse llmproxy for all model calls", true),
            ("description = \"Legacy broker retired\"\ninstructions = \"Use llmproxy for model calls\"", true),
            ("## Retired tools\nUse llmproxy for model calls.", true),
            ("Status: retired CLI\nFallback: llmproxy", true),
            ("Set OPENAI_API_BASE=http://llmproxy:4000 and OPENAI_API_KEY=dummy", true),
            ("Point your client at llmproxy with the shared API key.", true),
            ("All model calls go through llmproxy with the shared key.", true),
            ("Use our llmproxy with the team key.", true),
            ("Model work goes via llmproxy; get a key first.", true),
            ("The broker does not authorize this route, so use llmproxy instead.", true),
            ("Pinemeter does not authorize Opus, use llmproxy for it.", true),
            ("Route model calls through llm/llmproxy.", true),
            ("Send model requests to http://localhost:4000/llmproxy/v1/messages", true),
            ("base_url: https://gateway.example.test/llmproxy", true),
            ("Use http://llmproxy.llm.svc:4000 for model calls with the mounted key.", true),
            ("Use llmproxy.\r\n\r\nThe CLI was retired\r\n\r\nUse llmproxy for reviews\r\n", true),
            ("Heading about removed tools\r\n\r\nUse llmproxy for reviews.\r\n", true),
            ("Heading about removed tools\n\nUse llmproxy for reviews.\n", true),
            ("- old cli retired\n- use llmproxy for reviews", true),
            ("1. old cli retired\n2. use llmproxy for reviews", true),
            ("a) old cli retired\nb) use llmproxy for reviews", true),
            ("old cli retired\n  * use llmproxy for reviews", true),
            ("The CLI was retired:\n```\nexport X=llmproxy\n```", true),
            ("Authenticate to llmproxy with your key, then run all model work there.", true),
            ("llmproxy handles all model calls; ask ops for a key.", true),
            ("llmproxy handles all model calls, ask ops for a key.", true),
            ("usé llmproxy key", true),
            ("llmproxy ⓐkey", true),
            ("agents use llmproxy with the key", true),
            ("agents used llmproxy with the key", true),
            ("Our default gateway is llmproxy; workloads authenticate with a token.", true),
            ("Fall back on llmproxy with key", true),
            ("falls back to llmproxy with key", true),
            ("Switch to llmproxy with the shared key.", true),
            ("Default model provider: llmproxy (api key in SSM)", true),
            ("model_provider = \"llmproxy\"", true),
            ("The agent uses llmproxy with the shared key.", true),
            ("Agents are using llmproxy with the shared key.", true),
            ("The worker sends model calls to llmproxy with the team key.", true),
            ("Reviews are dispatched via llmproxy with the team key.", true),
            ("Calling llmproxy with the shared key is the default.", true),
            ("Routes model work through llmproxy using the mounted secret.", true),
            ("Routing goes to llmproxy; the credential is in SSM.", true),
            ("model_provider = \"llmproxy\"\nsecret = \"x\"", true),
            ("Fallback: llmproxy\nSecret custody is described below.", true),
            ("Use the llmproxy key for model calls.", true),
            ("Use the llmproxy token for model calls.", true),
            ("Use the llmproxy credentials for model calls.", true),
            ("Use llmproxy, its certificate is mounted.", true),
            ("The identity does not authorize model routing through the broker, so use llmproxy.", true),
            ("It does not authorize model routing through llmproxy, so use llmproxy directly.", true),
            ("Send work to https://gw.example.test/ns/llm/sa/llmproxy/v1/messages", true),
            ("Send work to http://sa/llmproxy", true),
            ("Use myllmproxy secret store", true),
            ("Route calls to https://gw.example.test/llmproxy secret header required", true),
            ("Use llmproxy secretly", true),
            ("Use llmproxy (identity is mounted) for reviews.", true),
            ("llmproxy: secret route for reviews", true),
            // Unchanged from main.
            ("The old CLI was removed, use llmproxy now.", false),
            // Workload-identity and custody mentions: not flagged.
            ("\u{0600}not authorize model routing to llmproxy.", false),
            ("llmproxy is retired. Never run model-broker pick. Do not bypass Pinemeter.", false),
            ("Approved secret-storage exceptions: the interim `llm/llmproxy` Roles Anywhere leaf key in one Kubernetes Secret.", false),
            ("The `llm/llmproxy` interim exception names the SAN `spiffe://example.test/ns/llm/sa/llmproxy` and its custody rules.", false),
            ("The llmproxy identity does not authorize model routing through llmproxy.", false),
            ("Other workloads must reuse llmproxy custody rules.", false),
            ("Access to the leaf key is limited to llmproxy's service account.", false),
            ("The `llm/llmproxy` exception does not\nauthorize model routing through llmproxy.", false),
            ("The SAN is spiffe://example.test/ns/llm/sa/llmproxy; rotate it yearly.", false),
            ("Its llmproxy lane is retired.", false),
            ("llmproxy retired", false),
            ("llmproxy is retired.", false),
            ("The scripts/model-broker CLI and its llmproxy lane were removed.", false),
            ("The preferred store for the llmproxy leaf key is one Kubernetes Secret.", false),
            ("Never copy the llmproxy leaf key to a laptop.", false),
            ("- **`llm/llmproxy` interim exception.** The Roles Anywhere SAN is\n  `spiffe://k3s.example/ns/llm/sa/llmproxy`. Its key stays in one Secret.", false),
            ("The llmproxy sender certificate rotates monthly.", false),
            ("`llm/llmproxy` identifies a Kubernetes workload in these secret-custody rules. It does not authorize model routing, another broker client, endpoint, fallback, or routing authority.", false),
            // Accepted false positives: identical to main.
            ("The control plane issues the llmproxy certificate.", true),
            ("The llmproxy Secret must not be replicated to another lane.", true),
            ("The leaf key is issued to llmproxy only.", true),
            ("The Secret is mounted into llmproxy and nowhere else.", true),
            ("The cluster runs llmproxy as a Kubernetes workload with one leaf key.", true),
            ("See https://example.test/docs/llmproxy/custody for the llmproxy key.", true),
            ("The llmproxy credential lives in the cluster only.", true),
            ("The llmproxy token must never leave the namespace.", true),
            ("The key lets llmproxy call Bedrock for inference.", true),
            // Accepted gaps: main flagged these, the new rule does not.
            ("Dispatch through the llmproxy service account.", false),
            ("Route review work via the llmproxy identity.", false),
            ("Pinemeter does not authorize model routing through llmproxy yet, so call it directly.", false),
        ]
        let message = "Conflict: llmproxy route guidance."
        for (text, flagged) in cases {
            let report = InstructionAuditService.analyze(
                sources: [agent("~/.codex/agents/worker.toml", text)], endpoint: endpoint)
            XCTAssertEqual(
                report.sources.first?.findings.map(\.message).contains(message), flagged, text)
        }
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
