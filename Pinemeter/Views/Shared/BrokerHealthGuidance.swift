//
//  BrokerHealthGuidance.swift
//  Pinemeter
//
//  Plain-language causes for the broker's warning states. The popover card,
//  the Broker window header and the Settings Broker tab all draw from here,
//  so a warning reads the same wherever it shows and always says why, not
//  only that something is wrong.
//

import AppKit

enum BrokerHealthGuidance {
    /// Why quota checks are limited. Names the accounts whose last poll did
    /// not return fresh data when the oracle reports any, because "usage data
    /// is stale" alone does not tell the user which account to look at.
    static func oracleProblem(_ freshness: BrokerStatus.OracleFreshness) -> String {
        guard freshness.hasUsageData else {
            return "No usage data yet. Connect a usage account so the broker can check remaining quota before it routes."
        }
        let unhealthy = freshness.accounts.filter { $0.state != BrokerQuotaState.fresh.rawValue }
        if !unhealthy.isEmpty {
            let names = unhealthy.map { "\($0.label) (\($0.state))" }.joined(separator: ", ")
            return "Usage data is not current for \(names). Picks route without verified quota until a refresh succeeds. Reconnect the account if refreshing does not help."
        }
        let newest = freshness.ageSeconds.map { " The newest reading is \(BrokerStatusHeader.ageText($0)) old." } ?? ""
        return "A usage account has not refreshed recently.\(newest) Picks route without verified quota until a refresh succeeds."
    }

    /// What a degraded pick means, independent of the engine's reason text.
    static let degradedPick = "No candidate had verified quota headroom, so the broker routed anyway and marked the pick degraded."

    static let auditFailed = "The broker could not write its audit log, so it refuses picks. Check free disk space and permissions for the Pinemeter folder in Application Support. The next pick that saves clears this."

    static func unreachableInstance(_ entry: BrokerStatus.RouteHealth) -> String {
        "T3 instance \(entry.instanceId) is unreachable: \(entry.why)."
    }

    /// Reveals the folder that holds the broker audit log, the one place the
    /// user can check when audit persistence fails.
    @MainActor
    static func revealAuditFolder() {
        let directory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: .default,
            requestedDirectory: nil
        )
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
