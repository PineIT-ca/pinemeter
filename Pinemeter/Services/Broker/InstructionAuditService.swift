//
//  InstructionAuditService.swift
//  Pinemeter
//
//  The instruction-audit matcher, and nothing else.
//
//  Pinemeter used to collect the files as well as grade them, from a fixed
//  list of user-level paths. That list could never be complete: it cannot see
//  project files, skills, a second harness profile, or anything a session hook
//  injects, and a green verdict drawn from a subset reads as "your setup is
//  clean" when it means "the files I knew to look for are clean". Collection
//  now belongs to the harness, which can read its own effective instruction
//  stack in precedence order, and reaches this grader through the `audit` MCP
//  tool. What is left here is pure and deterministic, which is the half a
//  model should not be doing.
//

import Foundation

enum InstructionAuditStatus: String, Codable, Equatable, Sendable {
    case pass
    case warning
    case conflict
    case unavailable

    /// Display copy. The wire form is `rawValue`, so rewording this is safe.
    var label: String {
        switch self {
        case .pass: "Pass"
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        }
    }
}

enum InstructionAuditFindingKind: String, Codable, Equatable, Sendable {
    case missingDirective = "missing_directive"
    case conflict
    case unavailable
}

struct InstructionAuditFinding: Equatable, Sendable {
    let kind: InstructionAuditFindingKind
    let message: String
}

struct InstructionAuditSource: Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case instructionRoot = "instruction_root"
        case agentDefinition = "agent_definition"
    }

    let path: String
    let kind: Kind
    let content: String?
}

struct InstructionAuditSourceReport: Equatable, Sendable {
    let path: String
    let status: InstructionAuditStatus
    let findings: [InstructionAuditFinding]
}

struct InstructionAuditReport: Equatable, Sendable {
    let sources: [InstructionAuditSourceReport]

    var status: InstructionAuditStatus {
        if sources.contains(where: { $0.status == .conflict }) { return .conflict }
        if sources.contains(where: { $0.status == .warning }) { return .warning }
        if sources.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
        if sources.contains(where: { $0.status == .unavailable }) { return .warning }
        return .pass
    }
}

enum InstructionAuditService {
    static func analyze<S: Sequence>(
        sources: S,
        endpoint: String
    ) -> InstructionAuditReport where S.Element == InstructionAuditSource {
        InstructionAuditReport(sources: sources
            .sorted { $0.path < $1.path }
            .map { analyze(source: $0, endpoint: endpoint) })
    }

    private static func analyze(
        source: InstructionAuditSource,
        endpoint: String
    ) -> InstructionAuditSourceReport {
        guard let content = source.content else {
            return InstructionAuditSourceReport(
                path: source.path,
                status: .unavailable,
                findings: [InstructionAuditFinding(kind: .unavailable, message: "Source unavailable.")]
            )
        }

        let text = content.lowercased()
        let conflicts = conflictFindings(in: text)
        if !conflicts.isEmpty {
            return InstructionAuditSourceReport(path: source.path, status: .conflict, findings: conflicts)
        }

        // Directives are matched against whitespace-flattened text: an
        // instruction file that wraps "Do not add another client" across two
        // lines still carries the directive. Conflict detection keeps the
        // original text, because it splits on newlines to scope negations.
        let flattened = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        let missing: [InstructionAuditFinding]
        switch source.kind {
        case .instructionRoot:
            missing = requiredDirectives(endpoint: endpoint).compactMap { directive in
                directive.matches(flattened) ? nil : InstructionAuditFinding(
                    kind: .missingDirective,
                    message: "Missing directive: \(directive.name)."
                )
            }
        case .agentDefinition:
            missing = isSpawner(text) && !nestedDirective.matches(flattened)
                ? [InstructionAuditFinding(
                    kind: .missingDirective,
                    message: "Missing directive: \(nestedDirective.name)."
                )]
                : []
        }

        return InstructionAuditSourceReport(
            path: source.path,
            status: missing.isEmpty ? .pass : .warning,
            findings: missing
        )
    }

    private struct Directive {
        let name: String
        /// What the file has to say, in prose. Copied reports print this so a
        /// session that has never seen Pinemeter can act on a finding that
        /// names only the directive.
        let detail: String
        let matches: @Sendable (String) -> Bool
    }

    /// The contract, as `name: detail` lines, for the copyable report. Built
    /// from the same directive list the audit runs, so the two cannot drift.
    static func contractChecklist(endpoint: String) -> [String] {
        requiredDirectives(endpoint: endpoint).map { "\($0.name): \($0.detail)" }
    }

    /// The single directive an agent definition owes, for the same report.
    static var nestedContractLine: String {
        "\(nestedDirective.name): \(nestedDirective.detail)"
    }

    private static func requiredDirectives(endpoint: String) -> [Directive] {
        [
            Directive(
                name: "pinemeter-broker registration",
                detail: "Name the broker: it is the `pinemeter-broker` MCP server registered with the harness."
            ) { $0.contains("pinemeter-broker") },
            Directive(
                name: "configured endpoint",
                detail: "State the endpoint `\(endpoint)`."
            ) { $0.contains(endpoint.lowercased()) },
            Directive(
                name: "pick(role, caller) call",
                detail: "Every dispatch calls `pick(role, caller)`; the harness sets the caller, never prompt text."
            ) { $0.contains("pick(role, caller)") },
            Directive(
                name: "caller echo validation",
                detail: "Require that the returned caller exactly matches the caller sent, and discard a result that does not."
            ) {
                containsAny($0, ["caller exactly matches", "exactly matches the caller", "validate the echoed caller exactly"])
            },
            routeDirective(route: "native", invocation: "agent"),
            routeDirective(route: "t3", invocation: "t3-dispatch"),
            routeDirective(route: "codex", invocation: "codex-exec"),
            Directive(
                name: "fail-closed behavior",
                detail: "Stop without dispatching when the endpoint or result is unavailable, a tool call fails, "
                    + "the result is stale or malformed, or route and invocation disagree."
            ) {
                $0.contains("stop") && containsAny($0, [
                    "unavailable endpoint", "endpoint or result is unavailable", "tool call fails",
                    "stale or malformed", "route and invocation disagree",
                ])
            },
            Directive(
                name: "single routing authority without fallback",
                detail: "State that Pinemeter is the only model-routing authority, and that a second broker client, "
                    + "policy layer, endpoint, or fallback is never added."
            ) {
                $0.contains("only model-routing authority")
                    && $0.contains("fallback")
                    && containsAny($0, ["never add", "do not add another"])
            },
            nestedDirective,
            Directive(
                name: "explicit one-dispatch human override",
                detail: "A fresh explicit operator instruction may pass one exact configured `override_candidate` "
                    + "to `pick`; require `source: human-override`, state that it bypasses quota, and never infer, "
                    + "persist, reuse, or bypass the broker for an override."
            ) {
                $0.contains("override_candidate")
                    && containsAny($0, ["fresh explicit operator", "fresh, explicit operator"])
                    && containsAny($0, ["never infer", "do not infer"])
                    && containsAny($0, [
                        "never persist", "never infer, persist", "never infer or persist", "do not persist",
                    ])
                    && $0.contains("human-override")
                    && containsAny($0, ["bypass quota", "bypasses quota"])
                    && $0.contains("never bypass")
            },
        ]
    }

    private static func routeDirective(route: String, invocation: String) -> Directive {
        Directive(
            name: "\(route) / \(invocation) route pair",
            detail: "Accept `\(route)` with `\(invocation)`, and reject every pairing outside the three legal ones."
        ) { text in
            containsAny(text, [
                "`\(route)` with `\(invocation)`",
                "\(route) with \(invocation)",
                "`\(route)` -> `\(invocation)`",
                "\(route) -> \(invocation)",
            ])
        }
    }

    private static let nestedDirective = Directive(
        name: "nested-subtask broker selection",
        detail: "Every task and every nested subtask that selects a model or route calls `pick(role, caller)` first, "
            + "and the rule propagates into every child-agent definition that can spawn or delegate subtasks."
    ) { text in
        text.contains("pinemeter")
            && text.contains("pick(role, caller)")
            && containsAny(text, [
                "every task and every nested subtask", "every task and nested subtask",
                "nested subtask", "child-agent definitions", "child agent definitions",
            ])
    }

    private static func conflictFindings(in text: String) -> [InstructionAuditFinding] {
        [
            (
                containsAny(text, [
                    "does not go through the broker", "do not go through the broker",
                    "must not go through the broker",
                ])
                    || hasPositiveClause(in: text, phrases: ["bypass pinemeter", "bypass the broker"]),
                "Conflict: explicit Pinemeter broker bypass."
            ),
            (
                hasPositiveClause(in: text, phrases: ["scripts/model-broker", "model-broker pick"]),
                "Conflict: retired model-broker CLI guidance."
            ),
            (hasPositiveClause(in: text, phrases: ["llmproxy"]), "Conflict: llmproxy route guidance."),
            (
                hasPositiveClause(
                    in: text,
                    phrases: ["fallback to native", "fall back to native", "native fallback"]
                ),
                "Conflict: native fallback guidance."
            ),
        ].compactMap { matches, message in
            matches ? InstructionAuditFinding(kind: .conflict, message: message) : nil
        }
    }

    /// Whether an agent definition can start child agents, and so has to carry
    /// the nested-subtask broker rule.
    ///
    /// A declared tool list settles it: an agent the harness never hands the
    /// Agent/Task tool cannot spawn anything, whatever its prose says. Only
    /// definitions without one fall back to phrasing, where the false
    /// positives to keep out are passive ("Spawned by the orchestrator via
    /// `Task()`"), plural shorthand ("covering task(s)"), and prose about what
    /// the *parent* does with this agent's output.
    private static func isSpawner(_ text: String) -> Bool {
        if let tools = declaredTools(in: text) {
            return tools
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t[]\"'")) }
                .contains { ["agent", "task", "*"].contains($0) }
        }

        return text.components(separatedBy: CharacterSet(charactersIn: "\n.;")).contains { clause in
            containsAny(clause, [
                "agent(", "spawn_agent", "spawn-agent", "can spawn", "may spawn",
                "you spawn", "spawns ", "delegate subtasks", "delegate subtask", "delegate nested",
            ]) && !containsAny(clause, [
                "spawned by", "is spawned", "are spawned", "was spawned",
                "orchestrator", "main agent", "parent agent",
            ])
        }
    }

    /// The value of a `tools:` (Markdown front matter) or `tools = [...]`
    /// (TOML) declaration, when the definition carries one.
    private static func declaredTools(in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("tools:") || $0.hasPrefix("tools =") || $0.hasPrefix("tools=") }
            .map { String($0.drop { $0 != ":" && $0 != "=" }.dropFirst()) }
    }

    private static func hasPositiveClause(in text: String, phrases: [String]) -> Bool {
        text.components(separatedBy: CharacterSet(charactersIn: "\n.;")).contains { clause in
            guard containsAny(clause, phrases) else { return false }
            return !containsAny(clause, [
                "do not use", "don't use", "never use", "must not use",
                "do not run", "never run", "must not run",
                "do not bypass", "never bypass", "must not bypass",
                "retired", "obsolete", "removed",
            ])
        }
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: text.contains)
    }
}
