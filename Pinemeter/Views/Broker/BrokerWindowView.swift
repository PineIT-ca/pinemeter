//
//  BrokerWindowView.swift
//  Pinemeter
//
//  D-05/D-09 Broker window.
//
//  Layout follows how the window is actually used rather than how the model is
//  structured. Three things happen here on completely different schedules:
//
//  - Constantly: "is it on, is it healthy, what did it just route." That is
//    the fixed header — it never scrolls away, because checking it is the
//    most common reason to open this window at all.
//  - Regularly: routing rules. Profiles, roles, chains, ceilings. This is the
//    default pane and gets the whole width.
//  - Rarely: instances and account bindings, set up once per Mac; the pick
//    log, read only when something routed wrong; and the instruction contract,
//    read when an agent is not asking the broker at all.
//
//  A single scroll containing all of that is what the window used to be, and it
//  put one-time setup between the user and the thing they came to change.
//  Splitting them into panes behind a System Settings style sidebar keeps
//  every pane short enough to take in at once, and the sidebar carries a
//  badge wherever a pane has something wrong in it, so a fault is visible
//  from every other pane.
//
//  The header's problem list links directly into these panes: an unreachable
//  instance row switches to Instances and scrolls to the row, so noticing a
//  fault and fixing it stay one click apart instead of two.
//

import SwiftUI

struct BrokerWindowView: View {
    @Bindable var appModel: AppModel

    @State private var pane: Pane
    @State private var recentPicks: [RecentPick]
    @State private var pendingScrollInstanceId: String?
    /// The saved instruction check, for the Setup badge. Loaded from disk
    /// like the Setup pane does, because the in-memory last-check stamp is
    /// nil after every launch.
    @State private var latestInstructionCheck: InstructionCheck?

    enum Pane: String, CaseIterable, Identifiable {
        case instructions
        case routing
        case updates
        case instances
        case activity
        case network
        case remoteHosts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .routing: return "Routing"
            case .updates: return "Routing updates"
            case .instances: return "Instances"
            case .network: return "Network"
            case .remoteHosts: return "Remote hosts"
            case .activity: return "Activity"
            case .instructions: return "Setup"
            }
        }

        var systemImage: String {
            switch self {
            case .routing: return "arrow.triangle.branch"
            case .updates: return "arrow.down.doc"
            case .instances: return "server.rack"
            case .network: return "network"
            case .remoteHosts: return "externaldrive.connected.to.line.below"
            case .activity: return "clock.arrow.circlepath"
            case .instructions: return "checklist"
            }
        }
    }

    /// Sidebar groups, in the order the window is used: first-run setup,
    /// then the rules that change most, then the log read when something
    /// routed wrong, then the connections set once per Mac.
    struct SidebarSection: Identifiable {
        let title: String
        let panes: [Pane]
        var id: String { title }
    }

    static let sidebarSections: [SidebarSection] = [
        SidebarSection(title: "Get Started", panes: [.instructions]),
        SidebarSection(title: "Routing", panes: [.routing, .updates, .instances]),
        SidebarSection(title: "Monitor", panes: [.activity]),
        SidebarSection(title: "Connections", panes: [.network, .remoteHosts]),
    ]

    /// What a sidebar item flags beside its name. Nothing is the common
    /// case; a badge only appears when the pane behind it has a problem the
    /// user has to go there to fix.
    enum SidebarBadge: Equatable {
        /// A red count: things that are broken.
        case count(Int)
        /// An orange warning mark: the last thing that happened went wrong.
        case warning
        /// An accent dot: something new is waiting, nothing is broken.
        case dot
        /// A neutral count: steps still to do.
        case remaining(Int)

        var accessibilityText: String {
            switch self {
            case .count(let n): return n == 1 ? "1 problem" : "\(n) problems"
            case .warning: return "warning"
            case .dot: return "update available"
            case .remaining(let n): return n == 1 ? "1 step remaining" : "\(n) steps remaining"
            }
        }
    }

    /// Where the last-used pane is remembered, per the HIG's "restore the most
    /// recently viewed pane": related settings are adjusted more than once, so
    /// reopening on Routing after someone spent the session in Instances costs
    /// them the same two clicks every time.
    static let paneDefaultsKey = "brokerSettingsPane"

    /// A one-shot instance id to scroll to on the next open. Written by a
    /// caller that opens the window (which cannot yet receive
    /// `.showBrokerPane`, since the window is not subscribed until it
    /// exists), read and cleared in `init`.
    static let pendingInstanceDefaultsKey = "brokerSettingsPendingInstance"

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
        self._pendingScrollInstanceId = State(initialValue: Self.takePendingInstance())
    }

    private static func takePendingInstance() -> String? {
        let defaults = TestSafeDefaults.standardOrIsolated
        let id = defaults.string(forKey: pendingInstanceDefaultsKey)
        if id != nil { defaults.removeObject(forKey: pendingInstanceDefaultsKey) }
        return id
    }

    static let paneUserInfoKey = "pane"
    static let instanceUserInfoKey = "instanceId"

    /// `userInfo` for `.showBrokerPane`, so the poster and the receiver agree
    /// on the keys.
    static func showPaneUserInfo(pane: Pane, instanceId: String?) -> [String: String] {
        var info = [paneUserInfoKey: pane.rawValue]
        if let instanceId { info[instanceUserInfoKey] = instanceId }
        return info
    }

    /// Opens the Broker window, optionally on `pane`. The defaults write
    /// covers a window that is about to be created, whose `init` reads the
    /// remembered pane; the notification covers a window that is already open
    /// and would otherwise stay on its current pane.
    @MainActor
    static func open(with openWindow: OpenWindowAction, pane: Pane? = nil, instanceId: String? = nil) {
        if let pane {
            TestSafeDefaults.standardOrIsolated.set(pane.rawValue, forKey: paneDefaultsKey)
        }
        if let instanceId {
            TestSafeDefaults.standardOrIsolated.set(instanceId, forKey: pendingInstanceDefaultsKey)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.brokerWindowID)
        if let pane {
            NotificationCenter.default.post(
                name: .showBrokerPane,
                object: nil,
                userInfo: showPaneUserInfo(pane: pane, instanceId: instanceId)
            )
        }
    }

    static func restoredPane() -> Pane {
        TestSafeDefaults.standardOrIsolated
            .string(forKey: paneDefaultsKey)
            .flatMap(Pane.init(rawValue:)) ?? .instructions
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                BrokerStatusHeader(
                    appModel: appModel,
                    onOpenInstances: { instanceId in
                        pane = .instances
                        pendingScrollInstanceId = instanceId
                    },
                    onOpenActivity: { pane = .activity }
                )

                Divider()

                BrokerRoutingUpdateBanner(appModel: appModel)

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        paneContent
                            .frame(maxWidth: BrokerUI.readableWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(BrokerUI.panePadding)
                    }
                    // `onAppear` covers an id handed over through defaults at
                    // init, which `onChange` never sees.
                    .onAppear { scrollToPendingInstance(proxy) }
                    .onChange(of: pendingScrollInstanceId) { _, _ in scrollToPendingInstance(proxy) }
                }
            }
        }
        .task(id: appModel.brokerUIState?.lastPickSummary) {
            recentPicks = await appModel.brokerRecentPicks()
        }
        // The store never goes from a record to none, so a nil result keeps
        // whatever is already loaded.
        .task(id: appModel.brokerUIState?.lastInstructionCheckAt) {
            if let latest = await appModel.brokerLatestInstructionCheck() {
                latestInstructionCheck = latest
            }
        }
        .onChange(of: pane) { _, newValue in
            TestSafeDefaults.standardOrIsolated.set(newValue.rawValue, forKey: Self.paneDefaultsKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBrokerPane)) { note in
            guard let raw = note.userInfo?[Self.paneUserInfoKey] as? String,
                  let requested = Pane(rawValue: raw) else { return }
            pane = requested
            pendingScrollInstanceId = note.userInfo?[Self.instanceUserInfoKey] as? String
            // The poster also wrote the id to defaults for a window that did
            // not exist yet. This one did, so consume it here or the next
            // fresh open would scroll to a stale row.
            TestSafeDefaults.standardOrIsolated.removeObject(forKey: Self.pendingInstanceDefaultsKey)
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
        .onChange(of: appModel.settings.broker.networkAccess) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
        .onChange(of: appModel.settings.broker.apiKeyMode) { previousMode, _ in
            Task { await appModel.applyBrokerAPIKeyModeChange(from: previousMode) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.sidebarSections) { section in
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, section.id == Self.sidebarSections.first?.id ? 12 : 16)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)

                ForEach(section.panes) { item in
                    sidebarRow(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: BrokerUI.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Broker settings section")
    }

    private func sidebarRow(_ item: Pane) -> some View {
        let isSelected = item == pane
        let badge = sidebarBadge(for: item)
        return Button {
            pane = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.body)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    sidebarBadgeView(badge, isSelected: isSelected)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: BrokerUI.rowRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: BrokerUI.rowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(badge?.accessibilityText ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Badge glyphs carry a symbol as well as a colour, and the selected row
    /// inverts to white, so a badge never depends on hue alone.
    @ViewBuilder
    private func sidebarBadgeView(_ badge: SidebarBadge, isSelected: Bool) -> some View {
        switch badge {
        case .count(let count):
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.red : Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isSelected ? Color.white : Color.red, in: Capsule())
        case .remaining(let count):
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    isSelected ? Color.white : Color.secondary.opacity(0.7),
                    in: Capsule()
                )
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white : Color.orange)
        case .dot:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
        }
    }

    private var isServerRunning: Bool {
        guard appModel.settings.broker.isEnabled else { return false }
        if case .running = appModel.brokerUIState?.serverState { return true }
        return false
    }

    /// The same facts the status header's problem list and the Settings
    /// window's Broker tab draw from, so the three can never disagree about
    /// what is wrong. Server-state badges wait for `.running` for the same
    /// reason the header's problem list does: while the server is starting
    /// they would flash and clear.
    func sidebarBadge(for item: Pane) -> SidebarBadge? {
        let state = appModel.brokerUIState
        switch item {
        case .instructions:
            let remaining = BrokerSetupProgress(
                serverRunning: isServerRunning,
                check: latestInstructionCheck,
                lastPickSummary: state?.lastPickSummary,
                lastPickDegraded: state?.lastPickDegraded ?? false,
                currentVersion: BrokerMCPServer.appVersion,
                currentSetupRevision: appModel.settings.broker.effectiveAgentSetup?.revision,
                now: Date()
            ).remainingSteps
            return remaining > 0 ? .remaining(remaining) : nil
        case .routing:
            return nil
        case .updates:
            guard isServerRunning, appModel.settings.broker.activeProfileHasUpdatedRules else { return nil }
            return .dot
        case .instances:
            guard isServerRunning else { return nil }
            let unreachable = (state?.routeHealth ?? []).filter { !$0.reachable }.count
            return unreachable > 0 ? .count(unreachable) : nil
        case .activity:
            guard isServerRunning, state?.lastPickDegraded == true else { return nil }
            return .warning
        case .network, .remoteHosts:
            return nil
        }
    }

    /// Deferred one turn so the Instances pane has laid out when the switch
    /// and the scroll land in the same update.
    private func scrollToPendingInstance(_ proxy: ScrollViewProxy) {
        guard let id = pendingScrollInstanceId else { return }
        Task { @MainActor in
            withAnimation {
                proxy.scrollTo(BrokerInstancesPane.scrollAnchor(for: id), anchor: .top)
            }
            pendingScrollInstanceId = nil
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .routing:
            // Model priority and quota ceilings are the user-facing rules.
            // Route and instance resolution belong to the broker.
            VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
                BrokerPaneHeader(
                    "Routing",
                    purpose: "Which models each role tries, in order, and the quota ceilings that gate them."
                )
                BrokerProfileBar(appModel: appModel)
                BrokerPolicyEditorView(appModel: appModel)
                BrokerThresholdsCard(appModel: appModel)
            }
        case .updates:
            VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
                BrokerPaneHeader(
                    "Routing updates",
                    purpose: "Automatic published rules, saved revisions, and rollback."
                )
                BrokerPresetManifestCard(appModel: appModel)
            }
        case .instances:
            BrokerInstancesPane(appModel: appModel)
        case .network:
            BrokerNetworkPane(appModel: appModel)
        case .remoteHosts:
            BrokerRemoteHostsPane(appModel: appModel)
        case .activity:
            BrokerActivityPane(
                picks: recentPicks,
                isEnabled: appModel.settings.broker.isEnabled,
                onRefresh: { recentPicks = await appModel.brokerRecentPicks() },
                onResetDegradedPaths: { await appModel.resetBrokerDegradedPaths() }
            )
        case .instructions:
            BrokerInstructionsPane(appModel: appModel)
        }
    }

    // MARK: - Discovered instance filtering
    //
    // Kept on the window rather than moved into `BrokerInstancesPane`: it is the
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
