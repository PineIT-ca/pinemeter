//
//  BrokerSummaryTab.swift
//  Pinemeter
//
//  The Settings window's Broker tab: a read-only glance at the broker and a
//  way into the Broker window, where all broker configuration lives.
//
//  Read-only on purpose. The `onChange` hooks that push edited broker
//  settings to the running server live in `BrokerWindowView`, so a control
//  here would persist a change the running broker never receives until a
//  later change fires those hooks or the app restarts.
//

import AppKit
import SwiftUI

struct BrokerSummaryTab: View {
    @Bindable var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Borrowed for its status derivation only, so this tab and the Broker
    /// window's header can never disagree about the broker's state.
    private var status: BrokerStatusHeader { BrokerStatusHeader(appModel: appModel) }

    private struct Problem: Identifiable {
        let id: String
        let text: String
        let systemImage: String
        let color: Color
        let actionTitle: String
        let action: () -> Void
    }

    private var oracleFresh: Bool {
        guard let freshness = appModel.brokerUIState?.oracleFreshness else { return false }
        return freshness.hasUsageData && !freshness.stale
    }

    /// One row per broker problem, each carrying the action that resolves it,
    /// so this tab answers "what is wrong" and "what do I click" together
    /// instead of leaving both generic notices unactionable.
    private var problems: [Problem] {
        var result: [Problem] = []

        // The broker-off and server-failed states are already the status
        // line above and the prominent button below, so they get no row.
        guard appModel.settings.broker.isEnabled else { return result }
        // Server-state rows wait for `.running`, as the Broker header does:
        // while the server is failed or starting they would point at the
        // wrong fix or flash and clear.
        guard case .running = appModel.brokerUIState?.serverState else { return result }
        if appModel.settings.broker.activeProfileHasUpdatedRules {
            result.append(Problem(
                id: "routing-update",
                text: "Routing update available",
                systemImage: "arrow.down.circle",
                color: .orange,
                actionTitle: "Review…",
                action: { openBrokerWindow() }
            ))
        }
        if appModel.brokerUIState?.lastPickDegraded == true {
            result.append(Problem(
                id: "last-pick-degraded",
                text: "Last pick was degraded",
                systemImage: "exclamationmark.triangle",
                color: .orange,
                actionTitle: "Open Activity",
                action: { openBrokerWindow(pane: .activity) }
            ))
        }
        for entry in appModel.brokerUIState?.routeHealth ?? [] where !entry.reachable {
            result.append(Problem(
                id: "instance-\(entry.instanceId)",
                text: "\(entry.instanceId) is unreachable",
                systemImage: "xmark.octagon.fill",
                color: .red,
                actionTitle: "Open Instances",
                action: { openBrokerWindow(pane: .instances, instanceId: entry.instanceId) }
            ))
        }
        if !oracleFresh {
            let hasUsageData = appModel.brokerUIState?.oracleFreshness.hasUsageData == true
            result.append(Problem(
                id: "oracle-stale",
                // The status line above already states the condition; this
                // row states the remedy.
                text: hasUsageData
                    ? "Reconnect a usage account to refresh stale quota data."
                    : "Connect a usage account so the broker can verify quota.",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange,
                actionTitle: "Open Accounts",
                action: {
                    NotificationCenter.default.post(name: .openAccountsSettings, object: nil)
                }
            ))
        }
        return result
    }

    /// The defaults write covers a window that is about to be created, whose
    /// `init` reads the remembered pane; the notification covers a window
    /// that is already open and would otherwise stay on its current pane.
    private func openBrokerWindow(pane: BrokerWindowView.Pane? = nil, instanceId: String? = nil) {
        if let pane {
            TestSafeDefaults.standardOrIsolated.set(pane.rawValue, forKey: BrokerWindowView.paneDefaultsKey)
        }
        if let instanceId {
            TestSafeDefaults.standardOrIsolated.set(instanceId, forKey: BrokerWindowView.pendingInstanceDefaultsKey)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.brokerWindowID)
        if let pane {
            NotificationCenter.default.post(
                name: .showBrokerPane,
                object: nil,
                userInfo: BrokerWindowView.showPaneUserInfo(pane: pane, instanceId: instanceId)
            )
        }
    }

    /// The status icon, derived the same way `BrokerStatusHeader` derives
    /// its colour and text, so the icon, colour and words always agree.
    private var statusSymbol: String {
        guard appModel.settings.broker.isEnabled else { return "moon.zzz.fill" }
        switch appModel.brokerUIState?.serverState {
        case .none, .starting: return "hourglass"
        case .stopped: return "stop.circle.fill"
        case .running: return status.statusColor == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(appModel.settings.broker.port)\(BrokerMCPServer.endpointPath)"
    }

    @State private var didCopyEndpoint = false

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

    var body: some View {
        let isEnabled = appModel.settings.broker.isEnabled
        let problems = problems
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Model Broker") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status.statusColor)
                        .accessibilityHidden(true)
                    Text(status.statusText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .settingsRowPadding()
                .accessibilityElement(children: .combine)

                SettingsRow("Routing profile") {
                    Text(appModel.settings.broker.activeProfile?.name ?? "Custom")
                        .foregroundStyle(.secondary)
                }

                SettingsRow("Last pick") {
                    Text(appModel.brokerUIState?.lastPickSummary ?? "No picks yet")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                SettingsRow("Endpoint") {
                    HStack(spacing: 6) {
                        Text(verbatim: endpoint)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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
                }
            }

            if !problems.isEmpty {
                SettingsSection("Needs attention") {
                    ForEach(problems) { problem in
                        HStack(spacing: 16) {
                            Label(problem.text, systemImage: problem.systemImage)
                                .foregroundStyle(problem.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(problem.actionTitle, action: problem.action)
                                .controlSize(.small)
                        }
                        .settingsRowPadding()
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // With the broker off the Broker window is the only place it
                // can be turned on, so the button says so and lands on Setup.
                Button(isEnabled ? "Open Broker Window\u{2026}" : "Set Up Broker\u{2026}") {
                    openBrokerWindow(pane: isEnabled ? nil : .instructions)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(isEnabled
                     ? "Configure routing, instances, network, and activity in the Broker window."
                     : "Turn the broker on and copy the setup prompt for your agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPane()
    }
}
