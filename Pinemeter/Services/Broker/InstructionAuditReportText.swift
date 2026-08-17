//
//  InstructionAuditReportText.swift
//  Pinemeter
//

import Foundation

/// What the Instructions tab puts on the pasteboard.
///
/// The rows on screen say which file failed and which rule it missed. A chat
/// session has none of that context, so every style carries the findings, what
/// the finding kinds mean, and the contract the audit enforces. The styles
/// differ only in what they ask the session to do with it.
enum InstructionAuditCopyStyle: String, CaseIterable, Identifiable, Sendable {
    /// Findings and commentary, with no instruction attached.
    case report
    /// Talk the gaps through first; change nothing.
    case discuss
    /// Close the gaps, with the approval rules user files need.
    case fix

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .report: "Copy Report"
        case .discuss: "Copy Prompt: Discuss the Gaps"
        case .fix: "Copy Prompt: Implement the Fixes"
        }
    }

    var copiedLabel: String {
        switch self {
        case .report: "Report Copied"
        case .discuss: "Prompt Copied"
        case .fix: "Prompt Copied"
        }
    }
}

extension InstructionAuditStatus {
    var label: String {
        switch self {
        case .pass: "Pass"
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        }
    }
}

extension InstructionAuditFindingKind {
    /// What the finding means and how it is closed. Printed once per kind
    /// present in the copied rows, not once per finding.
    var commentary: String {
        switch self {
        case .conflict:
            return "**Conflict**: the file carries routing guidance that contradicts Pinemeter: a retired CLI, a "
                + "removed route, an explicit bypass, or a fallback. Delete the guidance, or restate it as history. "
                + "A clause that calls the mechanism retired, obsolete, or removed, or that says never use it, is "
                + "accepted and still warns a reader off."
        case .missingDirective:
            return "**Missing directive**: the file never states the named rule. The audit matches wording, not "
                + "intent, so a file that implies the rule still fails. Add the rule in the file's own voice using "
                + "the contract below."
        case .unavailable:
            return "**Unavailable**: Pinemeter could not read the path. It is missing, a symlink, not a regular "
                + "file, or larger than 1 MB. Pinemeter never follows a symlink out of an instruction directory, so "
                + "a linked file has to be replaced with a real one to be audited."
        }
    }
}

extension InstructionAuditReport {
    /// Markdown for the pasteboard, covering only the rows the tab is showing.
    ///
    /// - Parameters:
    ///   - style: what the receiving session is asked to do.
    ///   - visible: the rows currently on screen, in display order.
    ///   - endpoint: the broker endpoint the audit ran against.
    ///   - appVersion: Pinemeter's version label, when the bundle carries one.
    func copyText(
        style: InstructionAuditCopyStyle,
        showing visible: [InstructionAuditSourceReport],
        endpoint: String,
        appVersion: String?
    ) -> String {
        var blocks: [String] = [
            header(visible: visible, endpoint: endpoint, appVersion: appVersion),
            findingsSection(visible: visible),
        ]

        if let commentary = commentarySection(visible: visible) {
            blocks.append(commentary)
        }
        blocks.append(Self.contractSection(endpoint: endpoint))
        blocks.append(Self.closingSection(style: style))

        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func header(
        visible: [InstructionAuditSourceReport],
        endpoint: String,
        appVersion: String?
    ) -> String {
        let tallies = [
            InstructionAuditStatus.conflict, .warning, .unavailable, .pass,
        ]
        .map { status in "\(sources.filter { $0.status == status }.count) \(status.label.lowercased())" }
        .joined(separator: ", ")

        var lines = ["# Pinemeter instruction audit", ""]
        if let appVersion {
            lines.append("- Pinemeter: \(appVersion)")
        }
        lines.append("- Broker endpoint: \(endpoint)")
        lines.append("- Overall status: \(status.label)")
        lines.append("- Sources checked: \(sources.count) (\(tallies))")
        lines.append(
            visible.count == sources.count
                ? "- Included below: every source"
                : "- Included below: \(visible.count) of \(sources.count) sources (the rows filtered into view)"
        )
        return lines.joined(separator: "\n")
    }

    private func findingsSection(visible: [InstructionAuditSourceReport]) -> String {
        guard !visible.isEmpty else {
            return "## Findings\n\nNone. Every audited source passes."
        }

        let entries = visible.map { source -> String in
            let findings = source.findings.isEmpty
                ? "- No findings."
                : source.findings.map { "- \($0.message)" }.joined(separator: "\n")
            return "### \(source.path) (\(source.status.label))\n\(findings)"
        }
        return (["## Findings"] + entries).joined(separator: "\n\n")
    }

    private func commentarySection(visible: [InstructionAuditSourceReport]) -> String? {
        let kinds: [InstructionAuditFindingKind] = [.conflict, .missingDirective, .unavailable]
        let present = kinds.filter { kind in
            visible.contains { $0.findings.contains { $0.kind == kind } }
        }
        guard !present.isEmpty else { return nil }

        return (["## What these findings mean"] + present.map { "- \($0.commentary)" })
            .joined(separator: "\n\n")
    }

    private static func contractSection(endpoint: String) -> String {
        let checklist = InstructionAuditService.contractChecklist(endpoint: endpoint)
            .enumerated()
            .map { index, line in "\(index + 1). \(line)" }
            .joined(separator: "\n")

        return """
        ## What the audit requires

        Instruction roots (`~/.claude/CLAUDE.md`, `~/.claude/CLAUDE.model-policy.md`, \
        `~/.claude/universal/subagent-execution-policy.md`, `~/.codex/AGENTS.md`, \
        `~/.codex/AGENTS.model-policy.md`) each have to state all of this:

        \(checklist)

        Agent definitions under `~/.claude/agents/` and `~/.codex/agents/` owe only the last rule, and only when \
        the definition can spawn or delegate subtasks:

        - \(InstructionAuditService.nestedContractLine)
        """
    }

    private static func closingSection(style: InstructionAuditCopyStyle) -> String {
        switch style {
        case .report:
            return """
            ## Note

            Pinemeter re-runs this audit from the Instructions tab. It reads the listed paths only, matches wording \
            rather than intent, and never stores their contents.
            """
        case .discuss:
            return """
            ## What I want from you

            Talk these gaps through with me. Change nothing yet, and propose no edits until I ask for them.

            For each finding: say what the file currently tells an agent to do, what goes wrong at dispatch time if \
            it stays, and the smallest wording that would close it. Group findings that share one root cause, and \
            say which are genuine risks versus wording the audit wants but that already holds in practice. Where a \
            file is third-party or generated, say so and flag that an edit there can be overwritten. Ask me about \
            anything ambiguous, then wait.
            """
        case .fix:
            return """
            ## What I want from you

            Close every finding above with the smallest edits that satisfy the contract.

            Rules:
            - The listed paths are my user files. Show the exact proposed edits and wait for my approval before \
            writing any of them.
            - Keep each file's existing voice, structure, and surrounding content. Do not restructure a file to \
            make a check pass.
            - Never weaken the contract to satisfy the audit: no second broker client, policy layer, endpoint, or \
            fallback, and no bypass. Retired mechanisms stay in the text as retired rather than being quietly \
            dropped where a reader might re-add them.
            - The audit matches wording, not intent, so state each rule plainly in the file.
            - If a file is third-party or generated (for example an agent definition installed by a tool), say so \
            before editing it, because a reinstall can overwrite the change.
            - When the edits are in, tell me to re-run the audit from Pinemeter's Instructions tab, and list \
            anything you expect to still fail and why.
            """
        }
    }
}
