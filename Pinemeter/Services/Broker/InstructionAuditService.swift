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
    /// A source that would otherwise warn for `missing_directive`, but points
    /// by path at another submitted source that passes and covers the gap.
    /// Kept distinct from `pass`: the file itself never states the contract,
    /// so a plain pass would overstate what this file's own wording proves.
    case credited

    /// Display copy. The wire form is `rawValue`, so rewording this is safe.
    var label: String {
        switch self {
        case .pass: "Pass"
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        case .credited: "Credited"
        }
    }
}

enum InstructionAuditFindingKind: String, Codable, Equatable, Sendable {
    case missingDirective = "missing_directive"
    case conflict
    case unavailable
    case creditedReference = "credited_reference"
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
    /// One source, graded on its own wording alone. `coveredNames` are the
    /// required-directive names this file's own text satisfies — computed
    /// whether or not the file needed to state them, because a *reference* to
    /// this file only credits what the text actually demonstrates.
    private struct Evaluation {
        enum Outcome {
            case unavailable
            case conflict([InstructionAuditFinding])
            case checked(missingNames: [String])
        }

        let outcome: Outcome
        let coveredNames: Set<String>
        /// Whitespace-flattened lowercased text, reused to look for other
        /// submitted sources' paths without recomputing it per candidate.
        let flattened: String?
    }

    /// Coverage is judged over the effective stack an agent submits in one
    /// call, not source by source: a file that points at another submitted
    /// file's path, when that file passes, is credited for the directives the
    /// referenced file's own text covers, instead of reading as a gap.
    /// Conflicts are never credited away, and a reference to a path that is
    /// missing, unsubmitted, or itself failing still leaves the finding in
    /// place. References outside the submitted set are never followed, and
    /// nothing here reads from disk — only what was sent is graded.
    static func analyze<S: Sequence>(
        sources: S,
        endpoint: String
    ) -> InstructionAuditReport where S.Element == InstructionAuditSource {
        let all = Array(sources)
        let evaluations = all.map { ($0, evaluate(source: $0, endpoint: endpoint)) }
        let baseStatusByPath = Dictionary(
            evaluations.map { ($0.0.path, status(for: $0.1)) },
            uniquingKeysWith: { _, latest in latest }
        )
        let coveredNamesByPath = Dictionary(
            evaluations.map { ($0.0.path, $0.1.coveredNames) },
            uniquingKeysWith: { _, latest in latest }
        )

        let reports = evaluations.map { source, evaluation in
            report(
                for: source,
                evaluation: evaluation,
                allSources: all,
                baseStatusByPath: baseStatusByPath,
                coveredNamesByPath: coveredNamesByPath
            )
        }

        return InstructionAuditReport(sources: reports.sorted { $0.path < $1.path })
    }

    private static func evaluate(source: InstructionAuditSource, endpoint: String) -> Evaluation {
        guard let content = source.content else {
            return Evaluation(outcome: .unavailable, coveredNames: [], flattened: nil)
        }

        let text = content.lowercased()
        let conflicts = conflictFindings(in: text)
        if !conflicts.isEmpty {
            return Evaluation(outcome: .conflict(conflicts), coveredNames: [], flattened: nil)
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

        switch source.kind {
        case .instructionRoot:
            var missing: [String] = []
            var covered: Set<String> = []
            for directive in requiredDirectives(endpoint: endpoint) {
                if directive.matches(flattened) {
                    covered.insert(directive.name)
                } else {
                    missing.append(directive.name)
                }
            }
            return Evaluation(outcome: .checked(missingNames: missing), coveredNames: covered, flattened: flattened)
        case .agentDefinition:
            let satisfies = nestedDirective.matches(flattened)
            let missing = isSpawner(text) && !satisfies ? [nestedDirective.name] : []
            let covered: Set<String> = satisfies ? [nestedDirective.name] : []
            return Evaluation(outcome: .checked(missingNames: missing), coveredNames: covered, flattened: flattened)
        }
    }

    /// The status `evaluate` would have produced on its own, before crediting.
    /// Used only to decide which submitted sources are eligible to credit
    /// another: a source must pass in isolation to lend its coverage.
    private static func status(for evaluation: Evaluation) -> InstructionAuditStatus {
        switch evaluation.outcome {
        case .unavailable: .unavailable
        case .conflict: .conflict
        case .checked(let missingNames): missingNames.isEmpty ? .pass : .warning
        }
    }

    private static func report(
        for source: InstructionAuditSource,
        evaluation: Evaluation,
        allSources: [InstructionAuditSource],
        baseStatusByPath: [String: InstructionAuditStatus],
        coveredNamesByPath: [String: Set<String>]
    ) -> InstructionAuditSourceReport {
        switch evaluation.outcome {
        case .unavailable:
            return InstructionAuditSourceReport(
                path: source.path,
                status: .unavailable,
                findings: [InstructionAuditFinding(kind: .unavailable, message: "Source unavailable.")]
            )
        case .conflict(let findings):
            return InstructionAuditSourceReport(path: source.path, status: .conflict, findings: findings)
        case .checked(let missingNames):
            guard !missingNames.isEmpty, let flattened = evaluation.flattened else {
                return InstructionAuditSourceReport(path: source.path, status: .pass, findings: [])
            }

            let references = referenceTokens(in: flattened)
            var remaining = Set(missingNames)
            var creditedVia: [String] = []
            for other in allSources where other.path != source.path {
                guard baseStatusByPath[other.path] == .pass,
                      references.contains(other.path.lowercased()) else { continue }
                let covered = coveredNamesByPath[other.path] ?? []
                let newlyCredited = remaining.intersection(covered)
                guard !newlyCredited.isEmpty else { continue }
                remaining.subtract(newlyCredited)
                creditedVia.append(other.path)
            }

            let remainingFindings = missingNames.filter(remaining.contains).map {
                InstructionAuditFinding(kind: .missingDirective, message: "Missing directive: \($0).")
            }

            guard !creditedVia.isEmpty else {
                return InstructionAuditSourceReport(path: source.path, status: .warning, findings: remainingFindings)
            }

            let creditFindings = creditedVia.sorted().map {
                InstructionAuditFinding(
                    kind: .creditedReference,
                    message: "Credited through reference to \($0), which passes."
                )
            }

            return InstructionAuditSourceReport(
                path: source.path,
                status: remaining.isEmpty ? .credited : .warning,
                findings: remainingFindings + creditFindings
            )
        }
    }

    /// Path-like tokens in already-lowercased text, found in one linear pass.
    ///
    /// A reference must name another source's path as a whole token, so
    /// `~/.claude/CLAUDE.md` does not credit a source submitted as
    /// `CLAUDE.md`. Matching tokens against a set also keeps the work linear:
    /// a substring search for each caller-chosen path in each 256 KiB source
    /// is quadratic, and a crafted `audit` call could hold a core for minutes.
    static func referenceTokens(in text: String) -> Set<String> {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "`'\"()[]<>{},;|*"))
        let trailing = CharacterSet(charactersIn: ".:!?")
        var tokens = Set<String>()
        for raw in text.components(separatedBy: separators) {
            var token = Substring(raw)
            // Trim sentence punctuation from the end only, before and after
            // the suffix handling below: a leading dot is part of paths such
            // as `.claude/agents/worker.md`.
            while let last = token.unicodeScalars.last, trailing.contains(last) {
                token = token.dropLast()
            }
            // Claude Code's `@path` import form.
            if token.hasPrefix("@") { token = token.dropFirst() }
            // A `#fragment` or a `:line` / `:line:column` suffix still names
            // the file. Only ASCII digit groups are cut.
            if let hash = token.firstIndex(of: "#") { token = token[..<hash] }
            while let colon = token.lastIndex(of: ":"),
                  case let suffix = token[token.index(after: colon)...],
                  !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                token = token[..<colon]
            }
            while let last = token.unicodeScalars.last, trailing.contains(last) {
                token = token.dropLast()
            }
            let tokenString = String(token)
            guard tokenString.count >= 2,
                  tokenString.count <= BrokerMCPServer.maxAuditPathLength,
                  tokenString.contains("/") || tokenString.contains(".") else { continue }
            tokens.insert(tokenString)
        }
        return tokens
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
                name: "role names from status",
                detail: "Choose `role` from the names the broker's `status` tool lists."
            ) {
                $0.contains("status") && $0.contains("explore") && $0.contains("verification")
            },
            Directive(
                name: "caller echo validation",
                detail: "Require that the returned caller exactly matches the caller sent, and discard a result that does not."
            ) {
                containsAny($0, ["caller exactly matches", "exactly matches the caller", "validate the echoed caller exactly"])
            },
            routeDirective(route: "native", invocation: "agent"),
            routeDirective(route: "t3", invocation: "t3-dispatch"),
            Directive(
                name: "caller-aware codex invocation",
                detail: "Accept `codex` with `agent` when caller is `codex`, and `codex` with `codex-exec` "
                    + "for every other caller. Codex uses its harness-native subagent tool with the returned "
                    + "model and optional effort, and gives the child a self-contained prompt that preserves "
                    + "the nested Pinemeter-pick requirement."
            ) {
                $0.contains("codex")
                    && $0.contains("agent")
                    && $0.contains("codex-exec")
                    && containsAny($0, ["when caller is codex", "caller: codex", "caller `codex`"])
                    && containsAny($0, ["every other caller", "non-codex caller", "other callers"])
                    && containsAny($0, ["harness-native subagent", "native child agent"])
                    && containsAny($0, ["optional effort", "invocation.effort"])
                    && $0.contains("self-contained")
                    && $0.contains("nested")
                    && $0.contains("pinemeter")
                    && $0.contains("pick(role, caller)")
            },
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
            Directive(
                name: "explicit Fable review override",
                detail: "Treat an explicit Fable review request as `override_candidate: auto/claude-fable-5-1` "
                    + "with role `review`, and never substitute another model when that override is unavailable."
            ) {
                $0.contains("explicit request for a fable review")
                    && $0.contains("auto/claude-fable-5-1")
                    && $0.contains("override_candidate")
                    && $0.contains("review")
                    && $0.contains("must not substitute another model")
            },
        ]
    }

    private static func routeDirective(route: String, invocation: String) -> Directive {
        Directive(
            name: "\(route) / \(invocation) route pair",
            detail: "Accept `\(route)` with `\(invocation)`, and reject every pairing outside the caller-aware legal combinations."
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
