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
//  - Rarely: instances and account bindings, set up once per Mac; the pick
//    log, read only when something routed wrong; and the instruction contract,
//    read when an agent is not asking the broker at all.
//
//  A single scroll containing all of that is what the tab used to be, and it
//  put one-time setup between the user and the thing they came to change.
//  Splitting them into panes behind a segmented control is the standard
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
        case instructions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .routing: return "Routing"
            case .instances: return "Instances"
            case .activity: return "Activity"
            case .instructions: return "Instructions"
            }
        }
    }

    /// Where the last-used pane is remembered, per the HIG's "restore the most
    /// recently viewed pane": related settings are adjusted more than once, so
    /// reopening on Routing after someone spent the session in Instances costs
    /// them the same two clicks every time.
    static let paneDefaultsKey = "brokerSettingsPane"

    /// `initialRecentPicks` and `initialPane` are test seams: production call
    /// sites use the defaults and let `.task(id:)` populate the real ring
    /// buffer asynchronously. Snapshot tests inject a canned array and pin a
    /// pane so the rendered image doesn't race an off-screen `NSHostingView`'s
    /// SwiftUI lifecycle, which never reliably pumps `.task` before capture.
    /// A pinned pane also keeps a reference image independent of whatever pane
    /// the host machine's defaults happen to have stored.
    init(
        appModel: AppModel,
        initialRecentPicks: [RecentPick] = [],
        initialPane: Pane? = nil
    ) {
        self.appModel = appModel
        self._recentPicks = State(initialValue: initialRecentPicks)
        self._pane = State(initialValue: initialPane ?? Self.restoredPane())
    }

    private static func restoredPane() -> Pane {
        UserDefaults.standard.string(forKey: paneDefaultsKey).flatMap(Pane.init(rawValue:)) ?? .routing
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
        .onChange(of: pane) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.paneDefaultsKey)
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
        case .instructions:
            BrokerInstructionsPane(appModel: appModel)
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
