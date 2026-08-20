//
//  InstructionAuditWireTests.swift
//  PinemeterTests
//
//  The JSON an agent reads back from the `audit` tool. Covered directly
//  rather than only through the loopback tests, because the wire names are a
//  contract with other people's harnesses: renaming one silently is the
//  failure mode.
//

import XCTest
@testable import Pinemeter

final class InstructionAuditWireTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:43117/mcp"

    private var report: InstructionAuditReport {
        InstructionAuditReport(sources: [
            InstructionAuditSourceReport(path: "~/.claude/CLAUDE.md", status: .pass, findings: []),
            InstructionAuditSourceReport(
                path: "~/.codex/AGENTS.md",
                status: .conflict,
                findings: [InstructionAuditFinding(
                    kind: .conflict,
                    message: "Conflict: retired model-broker CLI guidance."
                )]
            ),
            InstructionAuditSourceReport(
                path: "~/.claude/agents/worker.md",
                status: .warning,
                findings: [InstructionAuditFinding(
                    kind: .missingDirective,
                    message: "Missing directive: nested-subtask broker selection."
                )]
            ),
            InstructionAuditSourceReport(
                path: "~/.codex/agents/reviewer.toml",
                status: .unavailable,
                findings: [InstructionAuditFinding(kind: .unavailable, message: "Source unavailable.")]
            ),
        ])
    }

    private func encoded() throws -> [String: Any] {
        let text = try report.wireJSONString(endpoint: endpoint, appVersion: "9.9.9")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func test_wireNamesAreSnakeCasedAndStable() throws {
        let json = try encoded()

        XCTAssertEqual(json["endpoint"] as? String, endpoint)
        XCTAssertEqual(json["pinemeter_version"] as? String, "9.9.9")
        XCTAssertEqual(json["status"] as? String, "conflict")

        let sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.compactMap { $0["status"] as? String },
                       ["pass", "conflict", "warning", "unavailable"])
        XCTAssertEqual(
            sources.compactMap { ($0["findings"] as? [[String: Any]])?.first?["kind"] as? String },
            ["conflict", "missing_directive", "unavailable"]
        )
    }

    func test_countsTallyEveryStatus() throws {
        let counts = try XCTUnwrap(try encoded()["counts"] as? [String: Any])

        XCTAssertEqual(counts["pass"] as? Int, 1)
        XCTAssertEqual(counts["warning"] as? Int, 1)
        XCTAssertEqual(counts["conflict"] as? Int, 1)
        XCTAssertEqual(counts["unavailable"] as? Int, 1)
    }

    func test_contractRidesAlongAndMatchesTheAuditedEndpoint() throws {
        let contract = try XCTUnwrap(try encoded()["contract"] as? [String: Any])
        let roots = try XCTUnwrap(contract["instruction_root"] as? [String])

        XCTAssertEqual(roots, InstructionAuditService.contractChecklist(endpoint: endpoint))
        XCTAssertTrue(roots.contains { $0.contains(endpoint) })
        XCTAssertEqual(contract["agent_definition"] as? String, InstructionAuditService.nestedContractLine)
    }

    func test_boundariesStateThatPinemeterNeitherWritesNorRetains() throws {
        let boundaries = try XCTUnwrap(try encoded()["boundaries"] as? [String])

        XCTAssertTrue(boundaries.contains { $0.contains("never writes one") })
        XCTAssertTrue(boundaries.contains { $0.contains("wait for the user's approval") })
        XCTAssertTrue(boundaries.contains { $0.contains("neither stores nor logs it") })
        XCTAssertTrue(boundaries.contains { $0.contains("grades only what you send") })
        XCTAssertTrue(boundaries.contains { $0.contains("matches wording, not intent") })
    }

    func test_sourceKindWireNamesRoundTrip() {
        XCTAssertEqual(InstructionAuditSource.Kind(rawValue: "instruction_root"), .instructionRoot)
        XCTAssertEqual(InstructionAuditSource.Kind(rawValue: "agent_definition"), .agentDefinition)
        XCTAssertNil(InstructionAuditSource.Kind(rawValue: "project"))
        XCTAssertNil(InstructionAuditSource.Kind(rawValue: "InstructionRoot"))
    }

    /// Slashes in endpoints and `~/` paths must stay readable, matching `pick`.
    func test_slashesAreNotEscaped() throws {
        let text = try report.wireJSONString(endpoint: endpoint, appVersion: "9.9.9")

        XCTAssertTrue(text.contains("http://127.0.0.1:43117/mcp"))
        XCTAssertFalse(text.contains("\\/"))
    }
}
