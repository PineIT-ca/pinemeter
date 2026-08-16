import Darwin
import Foundation

enum InstructionAuditStatus: Equatable, Sendable {
    case pass
    case warning
    case conflict
    case unavailable
}

enum InstructionAuditFindingKind: Equatable, Sendable {
    case missingDirective
    case conflict
    case unavailable
}

struct InstructionAuditFinding: Equatable, Sendable {
    let kind: InstructionAuditFindingKind
    let message: String
}

struct InstructionAuditSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case instructionRoot
        case agentDefinition
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

actor InstructionAuditService {
    static let maxFileSizeBytes = 1_048_576
    static let maxAgentFilesPerDirectory = 64

    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func audit(endpoint: String) -> InstructionAuditReport {
        Self.analyze(sources: loadSources(), endpoint: endpoint)
    }

    nonisolated static func analyze<S: Sequence>(
        sources: S,
        endpoint: String
    ) -> InstructionAuditReport where S.Element == InstructionAuditSource {
        InstructionAuditReport(sources: sources
            .sorted { $0.path < $1.path }
            .map { analyze(source: $0, endpoint: endpoint) })
    }

    private nonisolated static func analyze(
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

        let missing: [InstructionAuditFinding]
        switch source.kind {
        case .instructionRoot:
            missing = requiredDirectives(endpoint: endpoint).compactMap { directive in
                directive.matches(text) ? nil : InstructionAuditFinding(
                    kind: .missingDirective,
                    message: "Missing directive: \(directive.name)."
                )
            }
        case .agentDefinition:
            missing = isSpawner(text) && !nestedDirective.matches(text)
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
        let matches: @Sendable (String) -> Bool
    }

    private nonisolated static func requiredDirectives(endpoint: String) -> [Directive] {
        [
            Directive(name: "pinemeter-broker registration") { $0.contains("pinemeter-broker") },
            Directive(name: "configured endpoint") { $0.contains(endpoint.lowercased()) },
            Directive(name: "pick(role, caller) call") { $0.contains("pick(role, caller)") },
            Directive(name: "caller echo validation") {
                containsAny($0, ["caller exactly matches", "exactly matches the caller", "validate the echoed caller exactly"])
            },
            routeDirective(route: "native", invocation: "agent"),
            routeDirective(route: "t3", invocation: "t3-dispatch"),
            routeDirective(route: "codex", invocation: "codex-exec"),
            Directive(name: "fail-closed behavior") {
                $0.contains("stop") && containsAny($0, [
                    "unavailable endpoint", "endpoint or result is unavailable", "tool call fails",
                    "stale or malformed", "route and invocation disagree",
                ])
            },
            Directive(name: "single routing authority without fallback") {
                $0.contains("only model-routing authority")
                    && $0.contains("fallback")
                    && containsAny($0, ["never add", "do not add another"])
            },
            nestedDirective,
        ]
    }

    private nonisolated static func routeDirective(route: String, invocation: String) -> Directive {
        Directive(name: "\(route) / \(invocation) route pair") { text in
            containsAny(text, [
                "`\(route)` with `\(invocation)`",
                "\(route) with \(invocation)",
                "`\(route)` -> `\(invocation)`",
                "\(route) -> \(invocation)",
            ])
        }
    }

    private nonisolated static let nestedDirective = Directive(name: "nested-subtask broker selection") { text in
        text.contains("pinemeter")
            && text.contains("pick(role, caller)")
            && containsAny(text, [
                "every task and every nested subtask", "every task and nested subtask",
                "nested subtask", "child-agent definitions", "child agent definitions",
            ])
    }

    private nonisolated static func conflictFindings(in text: String) -> [InstructionAuditFinding] {
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

    private nonisolated static func isSpawner(_ text: String) -> Bool {
        containsAny(text, [
            "agent(", "task(", "spawn_agent", "spawn-agent", "can spawn", "may spawn",
            "spawns ", "delegate subtasks", "delegate subtask", "delegate nested",
        ])
    }

    private nonisolated static func hasPositiveClause(in text: String, phrases: [String]) -> Bool {
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

    private nonisolated static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: text.contains)
    }

    private func loadSources() -> [InstructionAuditSource] {
        let fixedFiles: [(String, [String])] = [
            ("~/.claude/CLAUDE.md", [".claude", "CLAUDE.md"]),
            ("~/.claude/CLAUDE.model-policy.md", [".claude", "CLAUDE.model-policy.md"]),
            ("~/.claude/universal/subagent-execution-policy.md", [".claude", "universal", "subagent-execution-policy.md"]),
            ("~/.codex/AGENTS.md", [".codex", "AGENTS.md"]),
            ("~/.codex/AGENTS.model-policy.md", [".codex", "AGENTS.model-policy.md"]),
        ]

        var sources = fixedFiles.map { displayPath, components in
            InstructionAuditSource(
                path: displayPath,
                kind: .instructionRoot,
                content: Self.readRegularFile(at: components.reduce(homeDirectory) {
                    $0.appendingPathComponent($1)
                })
            )
        }

        for harness in [".claude", ".codex"] {
            let directory = homeDirectory
                .appendingPathComponent(harness, isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            sources += entries
                .filter { ["md", "toml"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(Self.maxAgentFilesPerDirectory)
                .map { url in
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    let content = values?.isRegularFile == true && values?.isSymbolicLink != true
                        ? Self.readRegularFile(at: url)
                        : nil
                    return InstructionAuditSource(
                        path: "~/\(harness)/agents/\(url.lastPathComponent)",
                        kind: .agentDefinition,
                        content: content
                    )
                }
        }

        return sources
    }

    private nonisolated static func readRegularFile(at url: URL) -> String? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= Int64(maxFileSizeBytes),
              let data = try? handle.read(upToCount: maxFileSizeBytes + 1),
              data.count <= maxFileSizeBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
