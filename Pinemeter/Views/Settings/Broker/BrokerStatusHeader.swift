//
//  BrokerStatusHeader.swift
//  Pinemeter
//
//  The Broker tab's fixed header. It stays out of the scroll view on purpose:
//  "is the broker on, is it healthy, what did it just route" is the question
//  the user opens this tab with most often, and it must be answerable without
//  scrolling back to the top from wherever they were editing.
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

    @State private var didCopyEndpoint = false
    @State private var isRetrying = false

    private var isEnabled: Bool { appModel.settings.broker.isEnabled }
    private var serverState: BrokerUIState.ServerState? { appModel.brokerUIState?.serverState }
    private var auditPersistenceFailed: Bool {
        appModel.brokerUIState?.auditPersistenceFailed == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if isEnabled {
                endpointRow
                healthRow
                if case .failed = serverState {
                    Text("Check the port above. If another app is using it, choose a different port or stop that server, then retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, BrokerUI.panePadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: statusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Model Broker")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $appModel.settings.broker.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable model broker")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Endpoint row

    private var endpointRow: some View {
        HStack(spacing: 6) {
            Text("Endpoint")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            Button {
                copyEndpoint()
            } label: {
                Image(systemName: didCopyEndpoint ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy the broker endpoint")
            .accessibilityLabel(didCopyEndpoint ? "Endpoint copied" : "Copy endpoint")

            Spacer(minLength: 0)
        }
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

    /// Freshness, last pick and per-instance reachability in one line of
    /// chips. These three are what turn "the server is up" into "the server
    /// can actually route", which is the distinction a stale oracle or an
    /// unreachable T3 instance quietly breaks.
    private var healthRow: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                BrokerChip(
                    text: oracleText,
                    systemImage: oracleFresh ? "clock" : "exclamationmark.triangle.fill",
                    tint: oracleFresh ? .secondary : .orange
                )
                .help("How old the usage data the broker gates on is.")

                if let lastPick = appModel.brokerUIState?.lastPickSummary {
                    BrokerChip(
                        text: lastPick,
                        systemImage: "arrow.triangle.branch",
                        tint: appModel.brokerUIState?.lastPickDegraded == true ? .orange : .secondary,
                        isMonospaced: true
                    )
                    .help("The broker's most recent routing decision.")
                }

                ForEach(sortedRouteHealth, id: \.instanceId) { entry in
                    BrokerChip(
                        text: entry.instanceId,
                        systemImage: entry.reachable ? "circle.fill" : "xmark",
                        tint: entry.reachable ? .green : .red
                    )
                    .help("T3 instance \(entry.instanceId): \(entry.why)")
                    .accessibilityLabel("\(entry.instanceId): \(entry.reachable ? "Reachable" : "Unavailable"). \(entry.why)")
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Broker health")
        .frame(height: 40)
    }

    private var sortedRouteHealth: [BrokerStatus.RouteHealth] {
        (appModel.brokerUIState?.routeHealth ?? []).sorted { $0.instanceId < $1.instanceId }
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

    private var statusColor: Color {
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

    private var statusText: String {
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
