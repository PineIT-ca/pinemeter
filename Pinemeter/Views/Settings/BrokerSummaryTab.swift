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

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Broker")
                        .font(.title2.weight(.semibold))

                    HStack(spacing: 8) {
                        Circle()
                            .fill(status.statusColor)
                            .frame(width: 8, height: 8)
                        Text(status.statusText)
                    }

                    LabeledContent("Routing profile", value: appModel.settings.broker.activeProfile?.name ?? "Custom")
                    LabeledContent("Last pick", value: appModel.brokerUIState?.lastPickSummary ?? "No picks yet")

                    if appModel.settings.broker.activeProfileHasUpdatedRules {
                        Label("Routing update available", systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                    }
                    if appModel.brokerUIState?.lastPickDegraded == true
                        || appModel.brokerUIState?.routeHealth.contains(where: { !$0.reachable }) == true {
                        Label("Some broker paths are degraded", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Open Broker Window…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: PinemeterApp.brokerWindowID)
                }
                .buttonStyle(.borderedProminent)

                Text("Configure routing, instances, network, and activity in the Broker window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsColumn()
        }
    }
}
