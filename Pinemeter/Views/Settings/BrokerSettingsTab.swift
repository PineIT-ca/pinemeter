//
//  BrokerSettingsTab.swift
//  Pinemeter
//
//  D-05/D-09 Broker settings tab.
//
//  Layout follows how the tab is actually used rather than how the model is
//  structured. Three things happen here on completely different schedules:
//
//  - Constantly: "is it on, is it healthy, what did it just route." That is
//    the fixed header — it never scrolls away, because checking it is the
//    most common reason to open this tab at all.
//  - Regularly: routing rules. Profiles, roles, chains, ceilings. This is the
//    default pane and gets the whole width.
//  - Rarely: instances and account bindings, set up once per Mac; and the
//    pick log, read only when something routed wrong.
//
//  A single scroll containing all of that is what the tab used to be, and it
//  put one-time setup between the user and the thing they came to change.
//  Splitting the three into panes behind a segmented control is the standard
//  macOS answer, and it keeps every pane short enough to take in at once.
//

import SwiftUI

struct BrokerSettingsTab: View {
    @Bindable var appModel: AppModel

    @State private var pane: Pane
    @State private var recentPicks: [RecentPick]

    enum Pane: String, CaseIterable, Identifiable {
        case routing
        case instances
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .routing: return "Routing"
            case .instances: return "Instances"
            case .activity: return "Activity"
            }
        }
    }

    /// `initialRecentPicks` and `initialPane` are test seams: production call
    /// sites use the defaults and let `.task(id:)` populate the real ring
    /// buffer asynchronously. Snapshot tests inject a canned array and pin a
    /// pane so the rendered image doesn't race an off-screen `NSHostingView`'s
    /// SwiftUI lifecycle, which never reliably pumps `.task` before capture.
    init(
        appModel: AppModel,
        initialRecentPicks: [RecentPick] = [],
        initialPane: Pane = .routing
    ) {
        self.appModel = appModel
        self._recentPicks = State(initialValue: initialRecentPicks)
        self._pane = State(initialValue: initialPane)
    }

    var body: some View {
        VStack(spacing: 0) {
            BrokerStatusHeader(appModel: appModel)

            Divider()

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, BrokerUI.panePadding)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityLabel("Broker settings section")

            ScrollView(.vertical) {
                paneContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BrokerUI.panePadding)
            }
        }
        .task(id: appModel.brokerUIState?.lastPickSummary) {
            recentPicks = await appModel.brokerRecentPicks()
        }
        .onChange(of: appModel.settings.broker.isEnabled) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
        .onChange(of: appModel.settings.broker.port) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
        .onChange(of: appModel.settings.broker.policy) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .routing:
            // Everything a rule profile carries, in the order a pick is
            // resolved: which candidates, then which instance an unqualified
            // t3 candidate lands on, then the ceilings that gate them. Keeping
            // all of it in one pane is what makes the profile bar's "Edited"
            // badge legible — every control that can set it is on this screen.
            VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
                BrokerProfileBar(appModel: appModel)
                BrokerPolicyEditorView(appModel: appModel)
                BrokerInstanceResolutionCard(appModel: appModel)
                BrokerThresholdsCard(appModel: appModel)
            }
        case .instances:
            BrokerInstancesPane(appModel: appModel)
        case .activity:
            BrokerActivityPane(
                picks: recentPicks,
                isEnabled: appModel.settings.broker.isEnabled,
                onRefresh: { recentPicks = await appModel.brokerRecentPicks() }
            )
        }
    }

    // MARK: - Discovered instance filtering
    //
    // Kept on the tab rather than moved into `BrokerInstancesPane`: it is the
    // one piece of add-menu behaviour with a hard requirement behind it
    // (RESEARCH Q-2) and it is covered directly, because a `Menu`'s contents
    // are invisible to a snapshot.

    /// Discovered instances the add menu may offer: `installed == true` and no
    /// existing row yet. `appModel.discoveredT3Instances` itself must stay
    /// unfiltered so an already-configured row for an uninstalled instance
    /// stays visible and keeps refreshing (R-02).
    static func addableDiscoveredInstances(
        discovered: [DiscoveredT3Instance],
        existing: [T3InstanceConfig]
    ) -> [DiscoveredT3Instance] {
        let existingIds = Set(existing.map(\.id))
        return discovered.filter { $0.installed && !existingIds.contains($0.instanceId) }
    }

    // MARK: - Agent setup prompt

    /// The pasteboard form of the setup prompt. The text itself lives in
    /// `BrokerSetupPrompt`, which the running broker also serves as its
    /// `configure` MCP prompt.
    static func setupPrompt(port: Int) -> String {
        BrokerSetupPrompt.text(port: port, origin: .pasteboard)
    }
}

/// Compact server-state line. Still used by the Instructions tab, which needs
/// the same fact the Broker tab's header carries but has no room for the
/// header itself.
struct BrokerServerStatusLine: View {
    let isEnabled: Bool
    let serverState: BrokerUIState.ServerState?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Broker server: \(text)")
    }

    private var color: Color {
        guard isEnabled else { return .gray }
        switch serverState {
        case .none, .stopped, .starting:
            return .gray
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var text: String {
        guard isEnabled else { return "Disabled" }
        switch serverState {
        case .none, .starting:
            return "Starting\u{2026}"
        case .stopped:
            return "Stopped"
        case .running(let port):
            return "Running on port \(port)"
        case .failed(let message):
            return message
        }
    }
}
