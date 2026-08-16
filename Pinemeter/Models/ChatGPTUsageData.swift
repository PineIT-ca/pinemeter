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

        var menuBarLabel: String {
            switch self {
            case .chatGPT5h:
                return "Codex 5h"
            case .chatGPTWeekly:
                return "Codex weekly"
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

        init(
            label: String,
            usedPercent: Double,
            resetAt: Date?,
            sourceLabel: String? = nil,
            subtitle: String? = nil,
            menuBarRole: MenuBarQuotaRole? = nil
        ) {
            self.label = label
            self.sourceLabel = sourceLabel ?? label
            self.subtitle = subtitle
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.menuBarRole = menuBarRole
        }
    }

    let rows: [LimitRow]
    let lastUpdated: Date
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
