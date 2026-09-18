//
//  BrokerCardView.swift
//  Pinemeter
//
//  D-09 popover card summarizing broker server/oracle health, the last
//  routing pick, and per-route reachability. A pure render struct like
//  ChatGPTUsageCardView — no service access, driven entirely by the
//  `BrokerUIState` value AppModel mirrors from the broker's stream.
//

import SwiftUI

struct BrokerCardView: View {
    let uiState: BrokerUIState
    let isEnabled: Bool
    let hasRoutingUpdate: Bool

    @Environment(\.openWindow) private var openWindow

    init(uiState: BrokerUIState, isEnabled: Bool, hasRoutingUpdate: Bool = false) {
        self.uiState = uiState
        self.isEnabled = isEnabled
        self.hasRoutingUpdate = hasRoutingUpdate
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: openSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if case .failed(let message) = uiState.serverState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isEnabled && !isOracleFresh {
                        Text(uiState.oracleFreshness.hasUsageData
                             ? "Usage data is stale. Quota checks are limited."
                             : "Connect usage accounts to verify remaining quota.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    lastPickRow
                    routeHealthRow
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens Settings")
            .accessibilityAddTraits(.isButton)

            if hasRoutingUpdate {
                Divider()
                    .padding(.horizontal, 16)
                HStack(spacing: 8) {
                    Text("Routing update available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review", action: openSettings)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func openSettings() {
        SettingsView.selectBrokerTab()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.settingsWindowID)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text("Broker")
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: statusIconName)
                    .font(.caption)
                Text(statusLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .foregroundColor(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .cornerRadius(8)
        }
    }

    // MARK: - Last pick

    @ViewBuilder
    private var lastPickRow: some View {
        if let lastPickSummary = uiState.lastPickSummary {
            HStack(spacing: 6) {
                Text(lastPickSummary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if uiState.lastPickDegraded {
                    Text("Degraded")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(6)
                }

                Spacer()
            }
        } else {
            Text("No picks yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Route health

    @ViewBuilder
    private var routeHealthRow: some View {
        if sortedRouteHealth.isEmpty {
            Text("No agent connections checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(sortedRouteHealth, id: \.instanceId) { entry in
                        routeChip(label: "t3:\(entry.instanceId)", healthy: entry.reachable)
                    }
                }
            }
            .frame(height: 36)
        }
    }

    private var sortedRouteHealth: [BrokerStatus.RouteHealth] {
        uiState.routeHealth.sorted { $0.instanceId < $1.instanceId }
    }

    private func routeChip(label: String, healthy: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(healthy ? Color.green : Color.orange)
            Text(label)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(6)
    }

    // MARK: - Status derivation

    /// True once the oracle has a snapshot that isn't past the staleness
    /// threshold (D-09's "server running + oracle fresh" green condition).
    private var isOracleFresh: Bool {
        uiState.oracleFreshness.hasUsageData && !uiState.oracleFreshness.stale
    }

    private var statusColor: Color {
        guard isEnabled else { return .gray }
        if uiState.auditPersistenceFailed { return .red }
        switch uiState.serverState {
        case .stopped, .starting:
            return .gray
        case .running:
            return isOracleFresh ? .green : .orange
        case .failed:
            return .red
        }
    }

    private var statusIconName: String {
        guard isEnabled else { return "moon.zzz" }
        if uiState.auditPersistenceFailed { return "externaldrive.badge.exclamationmark" }
        switch uiState.serverState {
        case .stopped:
            return "stop.circle"
        case .starting:
            return "hourglass"
        case .running:
            return isOracleFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var statusLabel: String {
        guard isEnabled else { return "Disabled" }
        if uiState.auditPersistenceFailed { return "Audit failed" }
        switch uiState.serverState {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting\u{2026}"
        case .running:
            return isOracleFresh ? "Running" : "Degraded"
        case .failed:
            return "Needs attention"
        }
    }

    private var accessibilityLabel: String {
        var parts = ["Broker: \(statusLabel)"]
        if let lastPickSummary = uiState.lastPickSummary {
            parts.append(
                uiState.lastPickDegraded
                    ? "Last pick \(lastPickSummary), degraded"
                    : "Last pick \(lastPickSummary)"
            )
        }
        if case .failed(let message) = uiState.serverState { parts.append(message) }
        if isEnabled && !isOracleFresh { parts.append("Usage quota is not verified") }
        for route in sortedRouteHealth {
            parts.append("\(route.instanceId): \(route.reachable ? "Reachable" : "Unavailable")")
        }
        return parts.joined(separator: ". ")
    }
}

#Preview {
    VStack(spacing: 16) {
        BrokerCardView(
            uiState: BrokerUIState(
                serverState: .running(port: 43117),
                lastPickSummary: "execution \u{2192} t3/gpt-5.6-sol",
                lastPickDegraded: false,
                routeHealth: [
                    BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: true, why: "reachable"),
                    BrokerStatus.RouteHealth(instanceId: "codex", reachable: true, why: "reachable"),
                ],
                oracleFreshness: BrokerStatus.OracleFreshness(
                    present: true, stale: false, ageSeconds: 12, accounts: []
                )
            ),
            isEnabled: true
        )

        BrokerCardView(
            uiState: BrokerUIState(
                serverState: .failed(message: "Port 43117 is already in use."),
                lastPickSummary: nil,
                lastPickDegraded: false,
                routeHealth: [],
                oracleFreshness: BrokerStatus.OracleFreshness(
                    present: false, stale: false, ageSeconds: nil, accounts: []
                )
            ),
            isEnabled: true
        )
    }
    .padding()
    .frame(width: 320)
}
