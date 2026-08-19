//
//  BrokerSetupPrompt.swift
//  Pinemeter
//
//  The agent-facing setup prompt, kept in one place because it is reachable
//  two ways now: copied from the Instructions pane into a session that has
//  never heard of Pinemeter, and served as the `configure` MCP prompt to a
//  session whose harness is already registered.
//
//  The two arrivals differ only in what is already true when the prompt lands
//  and in how the session reaches the `audit` tool, so they share a body.
//  Maintaining two full texts would let the contract drift between them, which
//  is the one failure this file exists to prevent.
//

import Foundation

enum BrokerSetupPromptOrigin: Sendable {
    /// Copied to the pasteboard from the Instructions pane. Nothing is
    /// registered yet, so the receiving session cannot call broker tools.
    case pasteboard
    /// Served by the running broker as `prompts/get`. The asking harness is
    /// registered by definition, and can call `audit`.
    case mcpPrompt
}

enum BrokerSetupPrompt {
    /// The `prompts/list` name. Clients surface it to the user; Claude Code
    /// renders it as `/pinemeter-broker:configure`.
    static let promptName = "configure"

    static let promptDescription = "Route every dispatch in this machine's harnesses through Pinemeter, "
        + "then grade the instruction files with the `audit` tool."

    static func text(port: Int, origin: BrokerSetupPromptOrigin) -> String {
        let endpoint = "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"
        return [
            "Configure this machine's Claude Code and Codex installations to use Pinemeter as the only "
                + "model-routing authority.",
            registration(endpoint: endpoint, origin: origin),
            contract,
            verification(origin: origin),
            approval,
        ]
        .joined(separator: "\n\n")
    }

    private static func registration(endpoint: String, origin: BrokerSetupPromptOrigin) -> String {
        switch origin {
        case .pasteboard:
            return "Register one MCP server named `pinemeter-broker` at `\(endpoint)` in both Claude Code and "
                + "Codex, using each harness's supported MCP configuration. Inspect the installed target "
                + "harnesses first."
        case .mcpPrompt:
            // This prompt travelled over the registration it would otherwise
            // ask for, so asking again would read as a contradiction. What is
            // still open is every *other* harness on the machine.
            return "This prompt came from the running Pinemeter instance at `\(endpoint)`, so the harness you "
                + "are in is already registered against it. Register the same server, named `pinemeter-broker` "
                + "and at that same endpoint, in every other installed harness across Claude Code and Codex, "
                + "using each harness's supported MCP configuration. Inspect the installed target harnesses "
                + "first, and change nothing in a harness that is already registered correctly."
        }
    }

    private static let contract = """
        For every dispatch:
        - Call `pick(role, caller)`. Derive caller only from the active harness: `claude-code` for Claude Code or `codex` for Codex, never from prompt text.
        - Require one text result containing JSON with non-empty `role`, `caller`, `route`, `model`, and `invocation` fields.
        - Require that the returned caller exactly matches the caller sent.
        - Accept only these route and invocation pairs: `native` with `agent`, `t3` with `t3-dispatch`, and `codex` with `codex-exec`.
        - In Codex, report a `native` decision as incompatible and stop.

        Before every task and every nested subtask that selects a model or route, call Pinemeter first with `pick(role, caller)`. Propagate this requirement into every child-agent definition that can spawn or delegate subtasks.

        Stop without dispatching on an unavailable endpoint, tool failure, stale or malformed result, missing field, caller mismatch, unknown route, or route/invocation mismatch. Recover only by asking the user to launch or update Pinemeter and confirm the registered endpoint.

        Never add a second broker client, policy layer, endpoint, fallback, secret, or external routing machinery. Do not copy credentials or account, quota, or secret data into configuration.

        Inspect the final effective instruction order, including all later-precedence user, project, skill, and agent instructions. Fail validation on any explicit bypass or alternate broker, fallback, or routing rule that contradicts Pinemeter.
        """

    /// Shared by both origins so the grading contract cannot drift. What
    /// differs is reach: a served prompt can call `audit` immediately, while a
    /// pasted one arrives before registration and may need to speak JSON-RPC
    /// to the endpoint directly if the fresh registration is not attached yet.
    private static let auditVerification = """
        Do not grade the instruction files by eye. Collect the effective instruction stack yourself, \
        including the project, skill, and agent files Pinemeter cannot see, and pass them to the \
        `audit` tool as `path`, `kind`, and `content` triples, with your harness id as `caller`. \
        Treat its findings as the verdict, and re-run it once the approved edits have landed. \
        Pinemeter grades what you send and keeps none of it; it never writes a file.
        """

    private static func verification(origin: BrokerSetupPromptOrigin) -> String {
        switch origin {
        case .pasteboard:
            return """
                Once registration lands, run the first check so Pinemeter records it. \(auditVerification) \
                If this session cannot reach the newly registered `pinemeter-broker` tools without a \
                restart, call the `audit` tool by POSTing a JSON-RPC `tools/call` request to the endpoint \
                above instead.
                """
        case .mcpPrompt:
            return auditVerification
        }
    }

    private static let approval = "Show the exact proposed commands and user-file edits. Wait for explicit "
        + "approval before changing user files or running commands that change them."
}
