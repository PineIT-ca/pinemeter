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
/// two ways -- as prose inside a decision's reason, for the calling agent, and
/// as a modal title, for the operator.
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
}
