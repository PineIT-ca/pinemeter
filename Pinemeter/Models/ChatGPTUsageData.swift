//
//  ChatGPTUsageData.swift
//  Pinemeter
//

import Foundation

/// ChatGPT quota usage data returned by ChatGPT's internal usage endpoint.
struct ChatGPTUsageData: Codable, Equatable, Sendable {
    enum MenuBarQuotaRole: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case chatGPT5h
        case chatGPTWeekly
        case chatGPTPro

        var menuBarLabel: String {
            switch self {
            case .chatGPT5h:
                return "ChatGPT 5h"
            case .chatGPTWeekly:
                return "ChatGPT weekly"
            case .chatGPTPro:
                return "ChatGPT Pro"
            }
        }

        /// Short quota-kind heading for the popover bar chart.
        var columnHeading: String {
            switch self {
            case .chatGPT5h:
                return "5h"
            case .chatGPTWeekly:
                return "Weekly"
            case .chatGPTPro:
                return "Pro"
            }
        }

        var sortOrder: Int {
            switch self {
            case .chatGPT5h:
                return 0
            case .chatGPTWeekly:
                return 1
            case .chatGPTPro:
                return 2
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

    var menuBarRows: [LimitRow] {
        var seenRoles = Set<MenuBarQuotaRole>()
        return rows
            .filter { row in
                guard let role = row.menuBarRole, !seenRoles.contains(role) else {
                    return false
                }
                seenRoles.insert(role)
                return true
            }
            .sorted { lhs, rhs in
                guard let lhsRole = lhs.menuBarRole, let rhsRole = rhs.menuBarRole else {
                    return lhs.label < rhs.label
                }
                return lhsRole.sortOrder < rhsRole.sortOrder
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
