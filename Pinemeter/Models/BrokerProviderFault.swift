//
//  BrokerProviderFault.swift
//  Pinemeter
//

import Foundation

/// A quota source that exists on this machine and is failing to answer.
///
/// Distinct from "no data yet" and from "old data". Both of those resolve on
/// their own; a fault does not, because something outside the app has to be
/// repaired before the next poll can succeed. That difference is the whole
/// point of the type: it is the signal that separates "wait" from "act".
///
/// Produced by ``BrokerEngine/providerFault(for:policy:oracle:)`` and rendered
/// three ways -- as prose inside a decision's reason, for the calling agent
/// (``agentAction``), as the operator-facing remedy appended to that same
/// reason (``operatorRemedy``), and as a modal title, for the operator.
enum BrokerProviderFault: Equatable, Sendable {
    /// The ChatGPT usage poll is failing. Codex lanes lose their headroom
    /// signal until the account is reconnected.
    case chatGPTDisconnected
    /// One Claude account's usage poll is failing, named by its label so the
    /// operator knows which of several accounts to repair.
    case claudeAccountDisconnected(label: String)

    /// The modal title, which leads with the cause instead of the symptom so
    /// the operator does not have to read the reason to learn what broke.
    var alertTitle: String {
        switch self {
        case .chatGPTDisconnected: "ChatGPT Usage Disconnected"
        case .claudeAccountDisconnected: "Claude Usage Disconnected"
        }
    }

    /// The clause appended to a reason so the caller reads a cause rather than
    /// a symptom. Phrased to complete "<candidate> ...".
    var reasonClause: String {
        switch self {
        case .chatGPTDisconnected:
            "ChatGPT usage poll is failing (account disconnected)"
        case .claudeAccountDisconnected(let label):
            "Claude usage poll for account \"\(label)\" is failing (account disconnected)"
        }
    }

    /// Which credential this fault traces back to, so UI and recovery code
    /// can act on the fault without re-deriving the provider from prose.
    var credentialProvider: CredentialProvider {
        switch self {
        case .chatGPTDisconnected: .chatGPT
        case .claudeAccountDisconnected: .claude
        }
    }

    /// The operator-facing remedy: the real fix (sign in at the provider's
    /// site, then Rescan browsers), not a generic "try again" instruction.
    /// Named incident 2026-10-01 -- every ChatGPT browser session expired and
    /// the operator saw only "degraded", with no screen saying what to do.
    var operatorRemedy: String {
        switch self {
        case .chatGPTDisconnected:
            "Codex routes use the ChatGPT account. Sign in at chatgpt.com in your browser, then choose Rescan browsers in Pinemeter."
        case .claudeAccountDisconnected(let label):
            "Sign in to the Claude account \"\(label)\" at claude.ai in your browser, then choose Rescan browsers in Pinemeter."
        }
    }

    /// The agent-facing `suggested_action`: what to tell the operator and
    /// what to do next, phrased for a calling agent that renders it verbatim.
    var agentAction: String {
        switch self {
        case .chatGPTDisconnected:
            "Ask the operator to sign in at chatgpt.com in a browser and choose Rescan browsers in Pinemeter, then call pick again with the same role and caller. Codex routes use the ChatGPT account."
        case .claudeAccountDisconnected(let label):
            "Ask the operator to sign in to the Claude account \"\(label)\" at claude.ai in a browser and choose Rescan browsers in Pinemeter, then call pick again with the same role and caller."
        }
    }
}
