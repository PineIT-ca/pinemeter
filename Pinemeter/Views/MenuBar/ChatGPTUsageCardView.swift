//
//  ChatGPTUsageCardView.swift
//  Pinemeter
//

import SwiftUI

/// Quota-oriented usage card for ChatGPT plan limits.
struct ChatGPTUsageCardView: View {
    let usageData: ChatGPTUsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "message.badge.waveform")
                    .font(.title3)
                    .foregroundColor(usageData.status.color)

                Text("ChatGPT Usage")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: usageData.status.iconName)
                        .font(.caption)
                    Text(usageData.status.rawValue.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(usageData.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(usageData.status.color.opacity(0.15))
                .cornerRadius(8)
            }

            ForEach(usageData.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        Text("\(Int(row.usedPercent.rounded()))%")
                            .font(.subheadline.monospacedDigit())
                            .fontWeight(.semibold)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.2))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(status(for: row).color)
                                .frame(width: geometry.size.width * min(row.usedPercent / 100, 1.0))
                        }
                    }
                    .frame(height: 8)

                    if let resetAt = row.resetAt {
                        Text("Resets \(resetAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption)
                Text("Updated \(usageData.lastUpdated, style: .relative)")
                    .font(.caption)
                Spacer()
            }
            .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func status(for row: ChatGPTUsageData.LimitRow) -> UsageStatus {
        switch row.usedPercent {
        case 0..<Constants.Thresholds.Status.warningStart:
            return .safe
        case Constants.Thresholds.Status.warningStart..<Constants.Thresholds.Status.criticalStart:
            return .warning
        default:
            return .critical
        }
    }

    private var accessibilityLabel: String {
        guard let percentage = usageData.percentage else {
            return "ChatGPT usage unavailable"
        }
        return "ChatGPT Usage: highest quota bucket is \(Int(percentage.rounded())) percent used"
    }
}

#Preview {
    ChatGPTUsageCardView(
        usageData: ChatGPTUsageData(
            rows: [
                .init(label: "Codex Tasks", usedPercent: 12, resetAt: Date().addingTimeInterval(3600)),
                .init(label: "Code Review", usedPercent: 55, resetAt: Date().addingTimeInterval(7200)),
            ],
            lastUpdated: Date()
        )
    )
    .padding()
    .frame(width: 320)
}
