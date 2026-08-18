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
            "Stop without dispatching",
            "Never add a second broker client",
            "final effective instruction order",
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

    func test_pasteboardPromptAsksForRegistrationInBothHarnesses() {
        let text = prompt(.pasteboard)

        XCTAssertTrue(text.contains("Register one MCP server named `pinemeter-broker`"))
        XCTAssertTrue(text.contains("in both Claude Code and Codex"))
        XCTAssertFalse(
            text.contains("already registered"),
            "a pasted prompt cannot assume any registration exists yet"
        )
        XCTAssertFalse(
            text.contains("`audit` tool"),
            "a pasted prompt reaches a session that cannot call broker tools yet"
        )
    }

    func test_servedPromptAssumesItsOwnHarnessAndDefersGradingToTheAuditTool() {
        let text = prompt(.mcpPrompt)

        XCTAssertTrue(text.contains("came from the running Pinemeter instance"))
        XCTAssertTrue(text.contains("already registered against it"))
        XCTAssertTrue(text.contains("every other installed harness"))
        XCTAssertTrue(text.contains("change nothing in a harness that is already registered correctly"))

        XCTAssertTrue(text.contains("Do not grade the instruction files by eye"))
        XCTAssertTrue(text.contains("`path`, `kind`, and `content` triples"))
        XCTAssertTrue(text.contains("re-run it once the approved edits have landed"))
        XCTAssertTrue(
            text.contains("keeps none of it; it never writes a file"),
            "the served prompt must state both boundaries: no retention, no writes"
        )
    }

    func test_pasteboardOriginIsWhatTheInstructionsTabCopies() {
        XCTAssertEqual(BrokerSettingsTab.setupPrompt(port: port), prompt(.pasteboard))
    }
}
