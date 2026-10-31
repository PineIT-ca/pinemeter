//
//  BrokerStatusHeader.swift
//  Pinemeter
//
//  The Broker window's fixed header. It stays out of the scroll view on purpose:
//  "is the broker on, is it healthy, what did it just route" is the question
//  the user opens this window with most often, and it must be answerable without
//  scrolling back to the top from wherever they were editing.
//
//  It is one row when everything is fine: state, endpoint, switch. The chip
//  row and the problem list only appear when they carry something the user
//  has to act on, so a healthy broker costs the panes below about 44pt
//  rather than the 140pt the always-on health row used to.
//
//  The endpoint line doubles as the port editor. The port is the one server
//  setting anyone changes, it is only ever changed because the printed
//  endpoint has to match what an agent is configured with, so editing it
//  inside that string is both the shortest path and the clearest one.
//

import AppKit
import SwiftUI

struct BrokerStatusHeader: View {
    @Bindable var appModel: AppModel
    var onOpenInstances: (String?) -> Void = { _ in }
    var onOpenActivity: () -> Void = {}

    @State private var didCopyEndpoint = false
    @State private var isRetrying = false
    @State private var isRefreshingUsage = false

    init(
        appModel: AppModel,
        onOpenInstances: @escaping (String?) -> Void = { _ in },
        onOpenActivity: @escaping () -> Void = {}
    ) {
        self.appModel = appModel
        self.onOpenInstances = onOpenInstances
        self.onOpenActivity = onOpenActivity
    }

    private var isEnabled: Bool { appModel.settings.broker.isEnabled }
    private var serverState: BrokerUIState.ServerState? { appModel.brokerUIState?.serverState }

    /// True when the server failed to start, which is the one state that
    /// shows the port guidance and the Retry broker button.
    var showsRetry: Bool {
        if case .failed = serverState { return true }
        return false
    }
    private var auditPersistenceFailed: Bool {
        appModel.brokerUIState?.auditPersistenceFailed == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            if isEnabled {
                // An audit failure outlives a server restart: only a pick
                // that saves clears it, so its row does not wait for `.running`.
                if auditPersistenceFailed {
                    auditFailureRow
                }
                // Only once the server is up: while it is starting, an
                // oracle or instance warning would flash and then clear.
                if case .running = serverState {
                    if showsHealthRow {
                        healthRow
                    }
                    problemList
                }
                if showsRetry {
                    HStack(spacing: 10) {
                        Text("Check the port. If another app is using it, choose a different port or stop that server, then retry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(isRetrying ? "Retrying…" : "Retry broker") {
                            Task {
                                isRetrying = true
                                await appModel.applyBrokerSettingsChange()
                                isRetrying = false
                            }
                        }
                        .disabled(isRetrying)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, BrokerUI.panePadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    // MARK: - Status row

    /// State, endpoint and the switch on one line. The endpoint stays next
    /// to the state because "is it up" and "at what address" are read
    /// together every time an agent is pointed at the broker.
    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(statusText)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Broker status: \(statusText)")

            Spacer(minLength: 12)

            if isEnabled {
                endpointField
            }

            Toggle("", isOn: $appModel.settings.broker.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable model broker")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Endpoint

    private var endpointField: some View {
        HStack(spacing: 4) {
            // `verbatim` on both literals: these are URL fragments, not
            // localizable copy, and the `LocalizedStringKey` overload styles
            // the scheme as a link.
            HStack(spacing: 0) {
                Text(verbatim: "http://127.0.0.1:")
                TextField("", value: $appModel.settings.broker.port, formatter: Self.portFormatter)
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Broker port")
                    .help("Loopback port the broker listens on (1024-65535).")
                Text(verbatim: BrokerMCPServer.endpointPath)
            }
            .foregroundStyle(.primary)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                HierarchicalShapeStyle.quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .help("The broker's MCP endpoint. Edit the port here.")

            Button {
                copyEndpoint()
            } label: {
                Image(systemName: didCopyEndpoint ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy the broker endpoint")
            .accessibilityLabel(didCopyEndpoint ? "Endpoint copied" : "Copy endpoint")
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Endpoint")
    }

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: BrokerSettings.portRange.lowerBound)
        formatter.maximum = NSNumber(value: BrokerSettings.portRange.upperBound)
        formatter.hasThousandSeparators = false
        return formatter
    }()

    private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(endpoint, forType: .string) else { return }
        didCopyEndpoint = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyEndpoint = false
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(appModel.settings.broker.port)\(BrokerMCPServer.endpointPath)"
    }

    // MARK: - Health row

    /// Shown only when a chip has something to say. A fresh oracle, a clean
    /// last pick and reachable instances are the normal state, and the
    /// sidebar and the panes already report them; repeating "fine" here
    /// costs every pane a row.
    private var showsHealthRow: Bool {
        !oracleFresh
            || appModel.brokerUIState?.lastPickDegraded == true
            || sortedRouteHealth.contains { !$0.reachable }
    }

    /// Freshness, a degraded last pick and unreachable instances in one line
    /// of chips. These are what turn "the server is up" into "the server
    /// cannot actually route", which is the distinction a stale oracle or an
    /// unreachable T3 instance quietly breaks.
    private var healthRow: some View {
        HStack(spacing: 6) {
            if !oracleFresh {
                BrokerChip(
                    text: oracleText,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
                .help("How old the usage data the broker gates on is.")
            }

            if let lastPick = appModel.brokerUIState?.lastPickSummary,
               appModel.brokerUIState?.lastPickDegraded == true {
                Button(action: onOpenActivity) {
                    BrokerChip(
                        text: "Degraded: \(lastPick)",
                        systemImage: "arrow.triangle.branch",
                        tint: .orange,
                        isMonospaced: true
                    )
                }
                .buttonStyle(.plain)
                .help(degradedHelp)
                .accessibilityLabel("Last pick degraded: \(lastPick). \(degradedHelp)")
                .accessibilityHint("Opens Activity")
            }

            ForEach(sortedRouteHealth.filter { !$0.reachable }, id: \.instanceId) { entry in
                Button {
                    onOpenInstances(entry.instanceId)
                } label: {
                    BrokerChip(text: entry.instanceId, systemImage: "xmark", tint: .red)
                }
                .buttonStyle(.plain)
                .help("T3 instance \(entry.instanceId): \(entry.why)")
                .accessibilityLabel("\(entry.instanceId): Unavailable. \(entry.why)")
                .accessibilityHint("Opens Instances")
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Broker health")
    }

    private var auditFailureRow: some View {
        HStack {
            Label(BrokerHealthGuidance.auditFailed, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Show Folder") { BrokerHealthGuidance.revealAuditFolder() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .font(.caption)
        .padding(.leading, 30)
    }

    private var degradedHelp: String {
        [BrokerHealthGuidance.degradedPick, appModel.brokerUIState?.lastPickDegradedReason]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var sortedRouteHealth: [BrokerStatus.RouteHealth] {
        (appModel.brokerUIState?.routeHealth ?? []).sorted { $0.instanceId < $1.instanceId }
    }

    /// One line per problem the header can name, each with the action that
    /// fixes it, so "something is wrong" always comes with "here is where to
    /// go" instead of leaving the user to find the right pane themselves.
    @ViewBuilder
    private var problemList: some View {
        let unreachableInstances = sortedRouteHealth.filter { !$0.reachable }
        let attentionProviders = appModel.providerCredentialStatuses.filter {
            !$0.state.health.isUsable
                && $0.state.health != .unknown
                && $0.state.health != .validating
                && $0.state.health != .missing
        }
        let lastPickDegraded = appModel.brokerUIState?.lastPickDegraded == true
        if !unreachableInstances.isEmpty || !attentionProviders.isEmpty || !oracleFresh
            || lastPickDegraded {
            VStack(alignment: .leading, spacing: 6) {
                if lastPickDegraded {
                    HStack {
                        Label(degradedHelp, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                            .help(degradedHelp)
                        Spacer()
                        Button("Open Activity", action: onOpenActivity)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                ForEach(unreachableInstances, id: \.instanceId) { entry in
                    HStack {
                        Label("\(entry.instanceId) is unreachable", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Open Instances") { onOpenInstances(entry.instanceId) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                ForEach(attentionProviders) { status in
                    HStack {
                        Label(
                            "\(status.providerName) session needs attention",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Accounts") {
                            NotificationCenter.default.post(name: .openAccountsSettings, object: nil)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
                if !oracleFresh, let freshness = appModel.brokerUIState?.oracleFreshness {
                    HStack {
                        Label(
                            BrokerHealthGuidance.oracleProblem(freshness),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if freshness.hasUsageData {
                            Button(isRefreshingUsage ? "Refreshing…" : "Refresh") {
                                Task {
                                    isRefreshingUsage = true
                                    await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
                                    isRefreshingUsage = false
                                }
                            }
                            .disabled(isRefreshingUsage || appModel.isRefreshingConfiguredUsage)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        Button("Open Accounts") {
                            NotificationCenter.default.post(name: .openAccountsSettings, object: nil)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .font(.caption)
            .padding(.leading, 30)
        }
    }

    private var oracleFresh: Bool {
        guard let freshness = appModel.brokerUIState?.oracleFreshness else { return false }
        return freshness.hasUsageData && !freshness.stale
    }

    var oracleText: String {
        guard let freshness = appModel.brokerUIState?.oracleFreshness, freshness.hasUsageData else {
            return "No usage data"
        }
        guard let age = freshness.ageSeconds else {
            return freshness.stale ? "Usage data stale" : "Usage data fresh"
        }
        let rendered = Self.ageText(age)
        return freshness.stale ? "Usage data \(rendered) old (stale)" : "Usage data \(rendered) old"
    }

    static func ageText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        return "\(whole / 3600)h"
    }

    // MARK: - Status derivation

    var statusColor: Color {
        guard isEnabled else { return .secondary }
        if auditPersistenceFailed { return .red }
        switch serverState {
        case .none, .stopped, .starting: return .secondary
        case .running: return oracleFresh ? .green : .orange
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        guard isEnabled else { return "moon.zzz.fill" }
        if auditPersistenceFailed { return "externaldrive.badge.exclamationmark" }
        switch serverState {
        case .none, .starting: return "hourglass"
        case .stopped: return "stop.circle.fill"
        case .running: return oracleFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var statusText: String {
        guard isEnabled else { return "Off. Agents cannot ask Pinemeter which model to use." }
        if auditPersistenceFailed { return "Audit persistence failed. Picks are blocked." }
        switch serverState {
        case .none, .starting:
            return "Starting\u{2026}"
        case .stopped:
            return "Stopped"
        case .running(let port):
            if oracleFresh { return "Broker running on port \(port)" }
            return appModel.brokerUIState?.oracleFreshness.hasUsageData == true
                ? "Broker running. Usage data is stale; quota checks are limited."
                : "Broker running. Connect usage accounts to verify remaining quota."
        case .failed(let message):
            return message
        }
    }
}
