//
//  BrokerSetupPromptTests.swift
//  PinemeterTests
//
//  The setup prompt reaches an agent two ways, and the risk of two ways is
//  that they stop saying the same thing. These tests pin the contract to the
//  shared body and pin each origin to the one thing it alone can assume.
//

import XCTest
@testable import Pinemeter

final class BrokerSetupPromptTests: XCTestCase {
    private let port = 54321

    private func prompt(_ origin: BrokerSetupPromptOrigin) -> String {
        BrokerSetupPrompt.text(port: port, origin: origin)
    }

    func test_bothOriginsCarryTheSameContract() {
        let clauses = [
            "Derive caller only from the active harness",
            "non-empty `role`, `caller`, `route`, `model`, and `invocation`",
            "exactly matches the caller sent",
            "`native` with `agent`",
            "`t3` with `t3-dispatch`",
            "`codex` with `codex-exec`",
            "every task and every nested subtask",
            "child-agent definition that can spawn or delegate",
            "fresh, explicit operator instruction",
            "`override_candidate`",
            "Never infer an override",
            "model-only request",
            "choose the healthy account",
            "Never persist or reuse it",
            "source: human-override",
            "overrides bypass quota caps and pacing gates",
            "Degraded picks require user confirmation",
            "Refresh and re-pick now",
            "degraded_reason",
            "dispatch to the listed `backups` in rank order",
            "using its `decision_id`",
            "Stop without dispatching",
            "Never add a second broker client",
            "final effective instruction order",
            "Do not grade the instruction files by eye",
            "`path`, `kind`, and `content` triples",
            "harness id as `caller`",
            "re-run it once the approved edits have landed",
            "keeps none of it; it never writes a file",
            "Wait for explicit approval before changing user files",
        ]

        for clause in clauses {
            XCTAssertTrue(
                prompt(.pasteboard).contains(clause),
                "the pasteboard prompt dropped: \(clause)"
            )
            XCTAssertTrue(
                prompt(.mcpPrompt).contains(clause),
                "the served prompt dropped: \(clause)"
            )
        }

        for origin in [BrokerSetupPromptOrigin.pasteboard, .mcpPrompt] {
            XCTAssertTrue(prompt(origin).contains("http://127.0.0.1:54321/mcp"))
            XCTAssertTrue(prompt(origin).contains("pinemeter-broker"))
        }
    }

    func test_pasteboardPromptAsksForRegistrationThenRunsTheFirstCheck() {
        let text = prompt(.pasteboard)

        XCTAssertTrue(text.contains("Register one MCP server named `pinemeter-broker`"))
        XCTAssertTrue(text.contains("in both Claude Code and Codex"))
        XCTAssertFalse(
            text.contains("already registered"),
            "a pasted prompt cannot assume any registration exists yet"
        )
        XCTAssertTrue(
            text.contains("Once registration lands, run the first check"),
            "a pasted prompt must sequence the audit after registration, not assume it is callable"
        )
        XCTAssertTrue(
            text.contains("JSON-RPC `tools/call`"),
            "a pasted prompt must offer the direct-endpoint path for a session "
                + "that cannot attach the fresh registration without a restart"
        )
    }

    func test_servedPromptAssumesItsOwnHarnessAndCallsAuditDirectly() {
        let text = prompt(.mcpPrompt)

        XCTAssertTrue(text.contains("came from the running Pinemeter instance"))
        XCTAssertTrue(text.contains("already registered against it"))
        XCTAssertTrue(text.contains("every other installed harness"))
        XCTAssertTrue(text.contains("change nothing in a harness that is already registered correctly"))
        XCTAssertFalse(
            text.contains("JSON-RPC `tools/call`"),
            "a served prompt travelled over a working registration and never needs the raw endpoint path"
        )
    }

    func test_pasteboardOriginIsWhatTheInstructionsTabCopies() {
        XCTAssertEqual(BrokerSettingsTab.setupPrompt(port: port), prompt(.pasteboard))
    }
}
