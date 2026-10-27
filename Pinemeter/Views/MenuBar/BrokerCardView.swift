//
//  BrokerCardView.swift
//  Pinemeter
//
//  D-09 popover card summarizing broker server/oracle health, the last
//  routing pick, and per-route reachability. A pure render struct like
//  ChatGPTUsageCardView — no service access, driven entirely by the
//  `BrokerUIState` value AppModel mirrors from the broker's stream. Actions
//  that need the app arrive as closures.
//
//  Every warning state gets a problem row that says why and offers the fix,
//  so a "Degraded" pill never sits alone with nothing to click.
//

import SwiftUI

struct BrokerCardView: View {
    let uiState: BrokerUIState
    let isEnabled: Bool
    let hasRoutingUpdate: Bool
    /// True while any usage refresh is in flight, including one started
    /// outside this card, so Refresh shows busy instead of doing nothing.
    let isRefreshingUsage: Bool
    let onRefreshUsage: () async -> Void
    let onRetryServer: () async -> Void
    let onOpenAccounts: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var runningAction: Action?

    init(
        uiState: BrokerUIState,
        isEnabled: Bool,
        hasRoutingUpdate: Bool = false,
        isRefreshingUsage: Bool = false,
        onRefreshUsage: @escaping () async -> Void = {},
        onRetryServer: @escaping () async -> Void = {},
        onOpenAccounts: @escaping () -> Void = {}
    ) {
        self.uiState = uiState
        self.isEnabled = isEnabled
        self.hasRoutingUpdate = hasRoutingUpdate
        self.isRefreshingUsage = isRefreshingUsage
        self.onRefreshUsage = onRefreshUsage
        self.onRetryServer = onRetryServer
        self.onOpenAccounts = onOpenAccounts
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: openBrokerWindow) {
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
            .accessibilityHint("Opens Broker window")
            .accessibilityAddTraits(.isButton)

            let problems = Self.problems(for: uiState, isEnabled: isEnabled)
            if !problems.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(problems) { problemRow($0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if hasRoutingUpdate {
                Divider()
                    .padding(.horizontal, 16)
                HStack(spacing: 8) {
                    Text("Routing update available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review", action: openBrokerWindow)
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

    private func openBrokerWindow() {
        BrokerWindowView.open(with: openWindow)
    }

    // MARK: - Problems

    /// A fix the card can offer. Hashable so a row can mark the one action
    /// that is in flight.
    enum Action: Hashable {
        case retryServer
        case openBroker
        case showAuditFolder
        case refreshUsage
        case openAccounts
        case openActivity
        case openInstance(String)

        var title: String {
            switch self {
            case .retryServer: "Retry"
            case .openBroker: "Open Broker"
            case .showAuditFolder: "Show Folder"
            case .refreshUsage: "Refresh"
            case .openAccounts: "Accounts\u{2026}"
            case .openActivity: "Activity"
            case .openInstance: "Instances"
            }
        }

        var busyTitle: String {
            switch self {
            case .retryServer: "Retrying\u{2026}"
            case .refreshUsage: "Refreshing\u{2026}"
            default: title
            }
        }
    }

    struct Problem: Identifiable, Equatable {
        let id: String
        let systemImage: String
        let isError: Bool
        let text: String
        let detail: String?
        let actions: [Action]
    }

    /// One row per warning the card shows, each naming the cause and the
    /// actions that resolve it. Static and pure so the derivation is testable
    /// without rendering. Usage, pick and instance rows wait for `.running`,
    /// as the Broker window header does: while the server is starting they
    /// would flash and clear.
    static func problems(for uiState: BrokerUIState, isEnabled: Bool) -> [Problem] {
        guard isEnabled else { return [] }
        var result: [Problem] = []
        if case .failed(let message) = uiState.serverState {
            result.append(Problem(
                id: "server-failed",
                systemImage: "xmark.octagon.fill",
                isError: true,
                text: message,
                detail: "Check the port. If another app is using it, choose a different port in the Broker window or stop that server, then retry.",
                actions: [.retryServer, .openBroker]
            ))
        }
        if uiState.auditPersistenceFailed {
            result.append(Problem(
                id: "audit-failed",
                systemImage: "externaldrive.badge.exclamationmark",
                isError: true,
                text: BrokerHealthGuidance.auditFailed,
                detail: nil,
                actions: [.showAuditFolder]
            ))
        }
        guard case .running = uiState.serverState else { return result }
        let freshness = uiState.oracleFreshness
        if !(freshness.hasUsageData && !freshness.stale) {
            result.append(Problem(
                id: "oracle-stale",
                systemImage: "exclamationmark.triangle.fill",
                isError: false,
                text: BrokerHealthGuidance.oracleProblem(freshness),
                detail: nil,
                actions: freshness.hasUsageData ? [.refreshUsage, .openAccounts] : [.openAccounts]
            ))
        }
        if uiState.lastPickDegraded {
            result.append(Problem(
                id: "last-pick-degraded",
                systemImage: "arrow.triangle.branch",
                isError: false,
                text: BrokerHealthGuidance.degradedPick,
                detail: uiState.lastPickDegradedReason,
                actions: [.openActivity]
            ))
        }
        let unreachable = uiState.routeHealth
            .filter { !$0.reachable }
            .sorted { $0.instanceId < $1.instanceId }
        for entry in unreachable {
            result.append(Problem(
                id: "instance-\(entry.instanceId)",
                systemImage: "xmark.octagon.fill",
                isError: true,
                text: BrokerHealthGuidance.unreachableInstance(entry),
                detail: nil,
                actions: [.openInstance(entry.instanceId)]
            ))
        }
        return result
    }

    private func problemRow(_ problem: Problem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: problem.systemImage)
                .font(.caption)
                .foregroundStyle(problem.isError ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = problem.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.popoverSecondary)
                        .lineLimit(3)
                        .help(detail)
                }
                HStack(spacing: 6) {
                    ForEach(problem.actions, id: \.self) { action in
                        let busy = runningAction == action
                            || (action == .refreshUsage && isRefreshingUsage)
                        Button(busy ? action.busyTitle : action.title) {
                            perform(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runningAction != nil || busy)
                        .accessibilityHint(problem.text)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: Action) {
        switch action {
        case .retryServer:
            run(action, onRetryServer)
        case .refreshUsage:
            run(action, onRefreshUsage)
        case .openBroker:
            BrokerWindowView.open(with: openWindow)
        case .showAuditFolder:
            BrokerHealthGuidance.revealAuditFolder()
        case .openAccounts:
            onOpenAccounts()
        case .openActivity:
            BrokerWindowView.open(with: openWindow, pane: .activity)
        case .openInstance(let instanceId):
            BrokerWindowView.open(with: openWindow, pane: .instances, instanceId: instanceId)
        }
    }

    private func run(_ action: Action, _ work: @escaping () async -> Void) {
        runningAction = action
        Task {
            await work()
            runningAction = nil
        }
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
            .help(statusHelp)
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

    /// What the status pill means, for hover. The problem rows below the
    /// card carry the specific cause and the fix.
    private var statusHelp: String {
        guard isEnabled else { return "The broker is off. Agents cannot ask Pinemeter which model to use." }
        if uiState.auditPersistenceFailed { return BrokerHealthGuidance.auditFailed }
        switch uiState.serverState {
        case .stopped: return "The broker server is stopped."
        case .starting: return "The broker server is starting."
        case .running(let port):
            return isOracleFresh
                ? "The broker is running on port \(port) with fresh usage data."
                : "The broker is running, but it cannot verify quota: \(BrokerHealthGuidance.oracleProblem(uiState.oracleFreshness))"
        case .failed(let message): return message
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
                lastPickSummary: "execution \u{2192} t3/gpt-6.1-sol",
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
