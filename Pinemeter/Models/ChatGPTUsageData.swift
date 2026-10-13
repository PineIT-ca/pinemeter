//
//  ChatGPTUsageData.swift
//  Pinemeter
//

import Foundation

/// ChatGPT quota usage data returned by ChatGPT's internal usage endpoint.
struct ChatGPTUsageData: Codable, Equatable, Sendable {
    enum MenuBarQuotaRole: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        // The WHAM endpoint meters Codex, so its rows are labeled as Codex
        // quotas; the enum names keep their original (Codable-persisted)
        // raw values from when the rows were labeled "ChatGPT ...".
        case chatGPT5h
        case chatGPTWeekly
        case chatGPTPro
        case chatGPTCodexSpark
        case chatGPTMonthly

        var menuBarLabel: String {
            switch self {
            case .chatGPT5h:
                return "Codex 5h"
            case .chatGPTWeekly:
                return "Codex weekly"
            case .chatGPTMonthly:
                return "Codex monthly"
            case .chatGPTPro:
                return "ChatGPT Pro"
            case .chatGPTCodexSpark:
                return "Codex Spark"
            }
        }

        /// Short quota-kind heading for the popover bar chart.
        var columnHeading: String {
            switch self {
            case .chatGPT5h:
                return "5h"
            case .chatGPTWeekly:
                return "Codex"
            case .chatGPTMonthly:
                return "30d"
            case .chatGPTPro:
                return "Pro"
            case .chatGPTCodexSpark:
                return "Spark"
            }
        }

    }

    struct LimitRow: Codable, Equatable, Identifiable, Sendable {
        var id: String { sourceLabel }

        let label: String
        let sourceLabel: String
        let subtitle: String?
        let usedPercent: Double
        let resetAt: Date?
        let menuBarRole: MenuBarQuotaRole?
        /// Short popover column heading when the role's own heading is too
        /// coarse -- two windows metering the same feature (Codex-Spark's 5h
        /// and weekly windows) need headings that tell them apart.
        let menuBarHeading: String?
        /// Server-reported window length (`limit_window_seconds`). Preferred
        /// over the role-implied duration for pacing, because the same role
        /// has been served over different window lengths over time.
        let windowSeconds: Double?

        init(
            label: String,
            usedPercent: Double,
            resetAt: Date?,
            sourceLabel: String? = nil,
            subtitle: String? = nil,
            menuBarRole: MenuBarQuotaRole? = nil,
            menuBarHeading: String? = nil,
            windowSeconds: Double? = nil
        ) {
            self.label = label
            self.sourceLabel = sourceLabel ?? label
            self.subtitle = subtitle
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.menuBarRole = menuBarRole
            self.menuBarHeading = menuBarHeading
            self.windowSeconds = windowSeconds
        }

        // Explicit snake_case CodingKeys and per-key fallback decode (this
        // type crosses the disk-persistence boundary via
        // ChatGPTUsageCacheRepository, target invariant E): a future field
        // addition or removal on disk must never crash a decode of an
        // otherwise-valid cached row.
        enum CodingKeys: String, CodingKey {
            case label
            case sourceLabel = "source_label"
            case subtitle
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case menuBarRole = "menu_bar_role"
            case menuBarHeading = "menu_bar_heading"
            case windowSeconds = "window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            self.label = label
            self.sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel) ?? label
            self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            self.usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent) ?? 0
            self.resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
            self.menuBarRole = try container.decodeIfPresent(MenuBarQuotaRole.self, forKey: .menuBarRole)
            self.menuBarHeading = try container.decodeIfPresent(String.self, forKey: .menuBarHeading)
            self.windowSeconds = try container.decodeIfPresent(Double.self, forKey: .windowSeconds)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(sourceLabel, forKey: .sourceLabel)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
            try container.encode(usedPercent, forKey: .usedPercent)
            try container.encodeIfPresent(resetAt, forKey: .resetAt)
            try container.encodeIfPresent(menuBarRole, forKey: .menuBarRole)
            try container.encodeIfPresent(menuBarHeading, forKey: .menuBarHeading)
            try container.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        }
    }

    let rows: [LimitRow]
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case rows
        case lastUpdated = "last_updated"
    }

    init(rows: [LimitRow], lastUpdated: Date) {
        self.rows = rows
        self.lastUpdated = lastUpdated
    }

    // Per-key fallback decode (target invariant E): a corrupt or
    // partially-written cache file on disk must be ignored gracefully by
    // ChatGPTUsageCacheRepository rather than propagating a decode error --
    // `rows` falls back to empty and `lastUpdated` is required (a snapshot
    // without a timestamp cannot be judged fresh or stale, so this throws
    // and the repository treats the whole file as absent).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rows = try container.decodeIfPresent([LimitRow].self, forKey: .rows) ?? []
        self.lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

extension ChatGPTUsageData {
    var primaryRow: LimitRow? {
        rows.max { $0.usedPercent < $1.usedPercent }
    }

    var percentage: Double? {
        primaryRow?.usedPercent
    }

    /// Rows for display surfaces: keeps every unclassified row but collapses
    /// duplicate roles (first row per role wins), so a server change that
    /// maps two windows to the same role cannot render twin bars.
    var displayRows: [LimitRow] {
        var seenRoles = Set<MenuBarQuotaRole>()
        return rows.filter { row in
            guard let role = row.menuBarRole else { return true }
            guard !seenRoles.contains(role) else { return false }
            seenRoles.insert(role)
            return true
        }
    }

    var status: UsageStatus {
        guard let percentage else { return .safe }
        return UsageStatus(chatGPTPercentage: percentage)
    }
}

extension ChatGPTUsageData.LimitRow {
    var status: UsageStatus {
        UsageStatus(chatGPTPercentage: usedPercent)
    }
}

private extension UsageStatus {
    init(chatGPTPercentage: Double) {
        switch chatGPTPercentage {
        case 0..<Constants.Thresholds.Status.warningStart:
            self = .safe
        case Constants.Thresholds.Status.warningStart..<Constants.Thresholds.Status.criticalStart:
            self = .warning
        default:
            self = .critical
        }
    }
}
