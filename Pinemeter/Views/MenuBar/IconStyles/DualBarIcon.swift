//
//  DualBarIcon.swift
//  Pinemeter
//
//  Created by Edd on 2025-12-28.
//

import SwiftUI

/// One quota meter, rendered as a mini bar in the menu-bar icon and as an
/// annotated column in the popover.
struct MenuBarQuotaBar: Equatable, Sendable {
    /// Full name used in tooltips and accessibility (e.g. "Acme 5h").
    let label: String
    /// Quota kind shown as the popover column heading (e.g. "5h", "Weekly").
    let heading: String
    /// Whose quota it is, shown under the popover column (account label or
    /// provider name). Empty when the label already says everything.
    let owner: String
    let percentage: Double
    let status: UsageStatus
    /// Secondary annotation for the popover column (e.g. reset time).
    let detail: String?
    /// What renaming this bar's owner label targets, when the label can be
    /// renamed inline in the popover; nil for single-account "Claude".
    let renameTarget: QuotaRenameTarget?

    var kind: MenuBarQuotaKind {
        switch heading {
        case "5h": .fiveHour
        case "Weekly": .weekly
        default: .special
        }
    }

    var isNearLimit: Bool { percentage >= 90 }

    var meterColor: Color {
        if isNearLimit { return .red }

        switch kind {
        case .fiveHour: return .cyan
        case .weekly: return .purple
        case .special: return .yellow
        }
    }

    static func groupedByOwner(_ bars: [MenuBarQuotaBar]) -> [[MenuBarQuotaBar]] {
        bars.reduce(into: []) { groups, bar in
            guard let previous = groups.last?.last else {
                groups.append([bar])
                return
            }

            let sameOwner = previous.renameTarget == bar.renameTarget
                && (bar.renameTarget != nil || previous.owner == bar.owner)
            if sameOwner {
                groups[groups.count - 1].append(bar)
            } else {
                groups.append([bar])
            }
        }
    }

    init(
        label: String,
        percentage: Double,
        status: UsageStatus,
        detail: String? = nil,
        heading: String? = nil,
        owner: String = "",
        renameTarget: QuotaRenameTarget? = nil
    ) {
        self.label = label
        self.heading = heading ?? label
        self.owner = owner
        self.percentage = percentage
        self.status = status
        self.detail = detail
        self.renameTarget = renameTarget
    }
}

enum MenuBarQuotaKind: Equatable, Sendable {
    case fiveHour
    case weekly
    case special
}

/// Identifies what a popover owner-label rename writes to.
enum QuotaRenameTarget: Equatable, Sendable {
    case claudeAccount(id: String)
    case provider(CredentialProvider)
}

/// Multi-bar menu bar icon showing Claude and ChatGPT quota buckets.
struct DualBarIcon: View {
    let percentage: Double
    let status: UsageStatus
    let isLoading: Bool
    let isStale: Bool
    let quotaBars: [MenuBarQuotaBar]

    private let barWidth: CGFloat = 34
    private let barHeight: CGFloat = 3
    private let barSpacing: CGFloat = 1

    private var bars: [MenuBarQuotaBar] {
        if quotaBars.isEmpty {
            return [MenuBarQuotaBar(label: "Claude 5h", percentage: percentage, status: status, heading: "5h")]
        }
        // Mirror every popover bar; the cap only guards against runaway width.
        return Array(quotaBars.prefix(12))
    }

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        MiniMeter(
                            percentage: bar.percentage,
                            color: isStale ? .gray : bar.meterColor,
                            isStale: isStale
                        )
                        .frame(width: 5, height: 15)
                        .help("\(bar.label): \(Int(bar.percentage))%")
                    }
                }
            }

            if isStale && !isLoading {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusColor: Color {
        isStale ? .gray : status.color
    }

    private var accessibilityLabel: String {
        bars
            .map { "\($0.label): \(Int($0.percentage)) percent" }
            .joined(separator: ", ")
    }

}

/// Individual vertical mini-meter component for the menu bar.
private struct MiniMeter: View {
    let percentage: Double
    let color: Color
    let isStale: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))

                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: geo.size.height * min(max(percentage, 0) / 100, 1.0))
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        DualBarIcon(
            percentage: 65,
            status: .warning,
            isLoading: false,
            isStale: false,
            quotaBars: [
                MenuBarQuotaBar(label: "Claude 5h", percentage: 65, status: .warning, heading: "5h"),
                MenuBarQuotaBar(label: "Claude weekly", percentage: 35, status: .safe, heading: "Weekly"),
                MenuBarQuotaBar(label: "ChatGPT Pro", percentage: 82, status: .warning, heading: "Pro"),
                MenuBarQuotaBar(label: "ChatGPT 4o", percentage: 20, status: .safe),
            ]
        )
        DualBarIcon(percentage: 45, status: .safe, isLoading: true, isStale: false, quotaBars: [])
        DualBarIcon(percentage: 45, status: .safe, isLoading: false, isStale: true, quotaBars: [])
    }
    .padding()
}
