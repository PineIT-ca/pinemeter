//
//  UsageData.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Complete usage data across all limit types
struct UsageData: Codable, Equatable, Sendable {
    /// 5-hour rolling session usage. Nil when the plan has no session
    /// window (Anthropic removed the 5-hour limit on higher-tier plans).
    let sessionUsage: UsageLimit?

    /// 7-day weekly usage across all models
    let weeklyUsage: UsageLimit

    /// 7-day Sonnet-specific usage (nil if not used)
    let sonnetUsage: UsageLimit?

    /// Model-scoped Fable usage (nil when the account has no Fable limit).
    var fableUsage: UsageLimit? = nil

    /// Timestamp of when this data was fetched
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case sessionUsage = "session_usage"
        case weeklyUsage = "weekly_usage"
        case sonnetUsage = "sonnet_usage"
        case fableUsage = "fable_usage"
        case lastUpdated = "last_updated"
    }
}

extension UsageData {
    /// The meter the menu bar icon tracks: the session window, or the
    /// weekly window on plans without one.
    var primaryUsage: UsageLimit {
        sessionUsage ?? weeklyUsage
    }

    /// Returns the primary usage level for menu bar display
    var primaryStatus: UsageStatus {
        primaryUsage.status
    }

    /// Session utilization as the broker oracle sees it. A plan without a
    /// session window has no session cap, which the engine gates read as 0%.
    var oracleSessionPercentage: Double {
        sessionUsage?.percentage ?? 0
    }

    var freshnessDescription: String {
        UsageFreshness.ageDescription(lastUpdated: lastUpdated, now: Date())
    }

    var isStale: Bool {
        UsageFreshness.isStale(lastUpdated: lastUpdated, now: Date())
    }
}

/// Shared age policy for each provider's last successful usage response.
enum UsageFreshness {
    static func isStale(lastUpdated: Date?, now: Date) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) > Constants.Refresh.stalenessThreshold
    }

    static func ageDescription(lastUpdated: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(lastUpdated))
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 86400 { return "\(Int(age / 3600)) hr ago" }
        return "\(Int(age / 86400)) days ago"
    }
}
