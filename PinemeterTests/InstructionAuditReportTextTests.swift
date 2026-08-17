import XCTest
@testable import Pinemeter

final class InstructionAuditReportTextTests: XCTestCase {
    private let endpoint = "http://127.0.0.1:43117/mcp"

    private var report: InstructionAuditReport {
        InstructionAuditReport(sources: [
            InstructionAuditSourceReport(
                path: "~/.claude/CLAUDE.md",
                status: .conflict,
                findings: [InstructionAuditFinding(
                    kind: .conflict,
                    message: "Conflict: llmproxy route guidance."
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
            InstructionAuditSourceReport(path: "~/.codex/AGENTS.md", status: .pass, findings: []),
        ])
    }

    private var issues: [InstructionAuditSourceReport] {
        report.sources.filter { $0.status != .pass }
    }

    func test_copyCoversOnlyTheRowsInView() {
        let text = report.copyText(
            style: .report,
            showing: issues,
            endpoint: endpoint,
            appVersion: "Version 1.1.0-beta.4 (abc1234)"
        )

        XCTAssertTrue(text.contains("~/.claude/CLAUDE.md (Conflict)"))
        XCTAssertTrue(text.contains("~/.claude/agents/worker.md (Warning)"))
        // The path still appears in the contract section; what a filtered copy
        // must drop is its findings row.
        XCTAssertFalse(text.contains("~/.codex/AGENTS.md (Pass)"))
        XCTAssertTrue(text.contains("- Included below: 2 of 3 sources (the rows filtered into view)"))
    }

    func test_headerKeepsWholeReportTalliesAndBuildContext() {
        let text = report.copyText(
            style: .report,
            showing: issues,
            endpoint: endpoint,
            appVersion: "Version 1.1.0-beta.4 (abc1234)"
        )

        XCTAssertTrue(text.contains("- Pinemeter: Version 1.1.0-beta.4 (abc1234)"))
        XCTAssertTrue(text.contains("- Broker endpoint: \(endpoint)"))
        XCTAssertTrue(text.contains("- Overall status: Conflict"))
        XCTAssertTrue(text.contains("- Sources checked: 3 (1 conflict, 1 warning, 0 unavailable, 1 pass)"))
    }

    func test_unfilteredCopySaysSoAndKeepsPassingRows() {
        let text = report.copyText(
            style: .report,
            showing: report.sources,
            endpoint: endpoint,
            appVersion: nil
        )

        XCTAssertTrue(text.contains("- Included below: every source"))
        XCTAssertTrue(text.contains("~/.codex/AGENTS.md (Pass)"))
        XCTAssertFalse(text.contains("- Pinemeter:"))
    }

    func test_commentaryCoversOnlyTheKindsInView() {
        let conflictOnly = report.copyText(
            style: .report,
            showing: [report.sources[0]],
            endpoint: endpoint,
            appVersion: nil
        )

        XCTAssertTrue(conflictOnly.contains("**Conflict**"))
        XCTAssertFalse(conflictOnly.contains("**Missing directive**"))
        XCTAssertFalse(conflictOnly.contains("**Unavailable**"))
    }

    func test_everyStyleCarriesTheContractDerivedFromTheAudit() {
        for style in InstructionAuditCopyStyle.allCases {
            let text = report.copyText(
                style: style,
                showing: issues,
                endpoint: endpoint,
                appVersion: nil
            )

            for line in InstructionAuditService.contractChecklist(endpoint: endpoint) {
                XCTAssertTrue(text.contains(line), "\(style.rawValue) dropped contract line: \(line)")
            }
            XCTAssertTrue(text.contains(InstructionAuditService.nestedContractLine))
        }
    }

    func test_discussPromptForbidsEditsAndFixPromptRequiresApproval() {
        let discuss = report.copyText(style: .discuss, showing: issues, endpoint: endpoint, appVersion: nil)
        let fix = report.copyText(style: .fix, showing: issues, endpoint: endpoint, appVersion: nil)

        XCTAssertTrue(discuss.contains("Change nothing yet"))
        XCTAssertFalse(discuss.contains("Close every finding"))

        XCTAssertTrue(fix.contains("wait for my approval before writing any of them"))
        XCTAssertTrue(fix.contains("no second broker client, policy layer, endpoint, or fallback"))
    }

    func test_emptyViewStillProducesAnActionableDocument() {
        let clean = InstructionAuditReport(sources: [
            InstructionAuditSourceReport(path: "~/.codex/AGENTS.md", status: .pass, findings: []),
        ])

        let text = clean.copyText(style: .fix, showing: [], endpoint: endpoint, appVersion: nil)

        XCTAssertTrue(text.contains("None. Every audited source passes."))
        XCTAssertTrue(text.contains("## What the audit requires"))
    }

    func test_filterSelectsTheRowsACopyCovers() {
        XCTAssertEqual(
            InstructionsSettingsTab.visibleSources(of: report, filter: .issues).map(\.path),
            ["~/.claude/CLAUDE.md", "~/.claude/agents/worker.md"]
        )
        XCTAssertEqual(
            InstructionsSettingsTab.visibleSources(of: report, filter: .all).count,
            report.sources.count
        )
    }
}
