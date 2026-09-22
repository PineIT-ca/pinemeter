//
//  BrokerDegradedAlertAction.swift
//  Pinemeter
//

import Foundation

/// The one action the degraded-pick alert offers beside `Dismiss`.
///
/// Split out of `AppDelegate` so the choice is testable: an `NSAlert` is only
/// observable through `runModal`, which a unit test cannot drive.
///
/// Why the choice exists at all: `BrokerService.pick` already runs the
/// refresh-and-re-pick retry for every retryable degraded decision *before* it
/// posts `.brokerDegradedPick`, and `refreshIfAllowed` then rate-limits a
/// second attempt for `minimumRefreshInterval`. So by the time this alert is on
/// screen, a re-poll has already been tried and has already failed to produce a
/// trustworthy route. Clearing cooldowns is the only thing left that can change
/// what the next `pick` returns — and only if a cooldown is actually set.
/// Offering it otherwise advertises a repair that provably does nothing.
enum BrokerDegradedAlertAction: Equatable {
    /// At least one cooldown is still in the future, so reconsidering every
    /// path can reach a candidate this pick skipped.
    case clearCooldowns
    /// Nothing the alert can do reaches the cause. Send the user to the pane
    /// that holds the real remedy (bind an account, fix an instance, renew a
    /// credential).
    case openBrokerSettings
    /// A provider this machine has is no longer answering. Nothing the broker
    /// can do reaches that; only reconnecting the account does.
    case openAccountsSettings

    /// A provider fault outranks the cooldown question. Clearing cooldowns
    /// cannot make a dead poll answer, so offering it while an account is
    /// disconnected sends the operator to the wrong pane for the wrong reason.
    static func forDecision(fault: BrokerProviderFault?, hasActiveCooldowns: Bool) -> Self {
        if fault != nil { return .openAccountsSettings }
        return hasActiveCooldowns ? .clearCooldowns : .openBrokerSettings
    }

    var buttonTitle: String {
        switch self {
        case .clearCooldowns: "Clear Cooldowns"
        case .openBrokerSettings: "Open Broker Settings"
        case .openAccountsSettings: "Open Accounts Settings"
        }
    }
}
