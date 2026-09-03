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

    private var routeHealthRow: some View {
        // `t3:` prefix on instance chips disambiguates from the bare "codex"
        // chip below — the bundled default policy happens to register a T3
        // instance also named "codex" (the T3-hosted lane), distinct from the
        // direct `.codex` CLI route, so an unprefixed label would render two
        // identical-looking "codex" chips for two different routes.
        HStack(spacing: 6) {
            routeChip(label: "native", healthy: true)
            ForEach(sortedRouteHealth, id: \.instanceId) { entry in
                routeChip(label: "t3:\(entry.instanceId)", healthy: entry.reachable)
            }
            routeChip(label: "codex", healthy: true)
            Spacer()
        }
    }

    private var sortedRouteHealth: [BrokerStatus.RouteHealth] {
        uiState.routeHealth.sorted { $0.instanceId < $1.instanceId }
    }

    private func routeChip(label: String, healthy: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(healthy ? Color.green : Color.red)
                .frame(width: 6, height: 6)
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
        uiState.oracleFreshness.present && !uiState.oracleFreshness.stale
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
        case .failed(let message):
            return message
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
