//
//  BrokerViewSnapshotTests.swift
//  PinemeterTests
//
//  The repo's first snapshot-test harness (07-05 Task 1, RESEARCH.md
//  Pitfall 8): every view renders inside an `NSHostingView` with an
//  explicit fixed frame and a forced `.aqua` (light) appearance, so
//  reference images are stable across machines and appearance modes.
//  Reference images live under `PinemeterTests/__Snapshots__/` and are
//  committed alongside the tests that recorded them.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Pinemeter

@MainActor
final class BrokerViewSnapshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            Bundle.main.bundleURL.pathExtension == "app",
            "Pixel snapshots require the app-hosted renderer."
        )
    }

    // MARK: - Harness

    /// Renders `view` inside a fixed-size `NSHostingView` under a forced
    /// appearance and asserts it against the committed reference image.
    ///
    /// `appearance` defaults to light. The Broker tab is the one surface in
    /// the app built entirely from semantic colours and materials rather than
    /// fixed ones, so it gets dark coverage too: a hardcoded colour that
    /// happens to read on white is invisible against a dark card, and no
    /// compile or unit test can catch that.
    ///
    /// Views containing a `List` (NSTableView-backed on macOS) only populate
    /// their cell views once genuinely attached to an on-screen window's
    /// display cycle — a bare `NSHostingView.cacheDisplay(in:to:)` snapshot
    /// (no window) renders those rows blank. Hosting inside a real,
    /// off-screen-positioned `NSWindow` and forcing one `orderFrontRegardless`
    /// display pass before capture fixes this for every view here, `List` or
    /// not.
    private func snapshot<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name = .aqua,
        named name: String? = nil,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        // An opaque backdrop, so a reference image is self-describing in any
        // viewer. Without it the captured view's own background is
        // transparent, every viewer composites that onto white, and a dark
        // snapshot appears to have white bands wherever no card or material
        // is drawn — which reads as a Dark Mode bug that is not there.
        let hostingView = NSHostingView(
            rootView: view
                .frame(width: size.width)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: appearance)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        assertSnapshot(
            of: hostingView,
            as: .image(size: size),
            named: name,
            file: file,
            testName: testName,
            line: line
        )

        window.orderOut(nil)
    }

    // MARK: - BrokerCardView (Task 1)

    func test_brokerCard_runningFresh() {
        let uiState = BrokerUIState(
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
        )
        snapshot(
            BrokerCardView(uiState: uiState, isEnabled: true),
            size: CGSize(width: 320, height: 150)
        )
    }

    func test_brokerCard_degradedLastPick() {
        let uiState = BrokerUIState(
            serverState: .running(port: 43117),
            lastPickSummary: "planning \u{2192} native/claude-sonnet-5",
            lastPickDegraded: true,
            routeHealth: [
                BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: false, why: "connection error"),
                BrokerStatus.RouteHealth(instanceId: "claude_secondary", reachable: true, why: "reachable"),
            ],
            oracleFreshness: BrokerStatus.OracleFreshness(
                present: true, stale: true, ageSeconds: 4000, accounts: []
            )
        )
        snapshot(
            BrokerCardView(uiState: uiState, isEnabled: true),
            size: CGSize(width: 320, height: 150)
        )
    }

    func test_brokerCard_failedPortInUse() {
        let uiState = BrokerUIState(
            serverState: .failed(message: "Port 43117 is already in use."),
            lastPickSummary: nil,
            lastPickDegraded: false,
            routeHealth: [],
            oracleFreshness: BrokerStatus.OracleFreshness(
                present: false, stale: false, ageSeconds: nil, accounts: []
            )
        )
        snapshot(
            BrokerCardView(uiState: uiState, isEnabled: true),
            size: CGSize(width: 320, height: 120)
        )
    }

    // MARK: - BrokerSettingsTab (Task 2)

    /// A representative `AppModel`, bootstrapped enough to render the Broker
    /// tab without touching disk/network: broker enabled, two T3 instances,
    /// and a running server state, and three recent picks (one degraded)
    /// served by `SnapshotFakeBrokerService.recentPicks()`.
    ///
    /// Timestamps are hour-scale offsets, not seconds/minutes: `Text(_:
    /// style: .relative)` renders live text that only changes once a full
    /// additional hour elapses, so the recorded image stays stable across
    /// the few seconds between a recording run and a verification run —
    /// second/minute-scale offsets flip their displayed text within that gap
    /// and make the snapshot flaky.
    private let brokerTabSnapshotRecentPicks: [RecentPick] = [
        RecentPick(
            timestamp: Date().addingTimeInterval(-3600),
            role: "execution", caller: "claude-code", candidate: "t3/gpt-5.6-sol",
            route: "t3", degraded: false, reason: "top of chain"
        ),
        RecentPick(
            timestamp: Date().addingTimeInterval(-7200),
            role: "planning", caller: "claude-code", candidate: "native/claude-sonnet-5",
            route: "native", degraded: true, reason: "forced degraded, nothing had headroom"
        ),
        RecentPick(
            timestamp: Date().addingTimeInterval(-18000),
            role: "review", caller: "claude-code", candidate: "native/claude-fable-5",
            route: "native", degraded: false, reason: "top of chain"
        ),
    ]

    private func makeAppModelForBrokerTabSnapshot() -> AppModel {
        let fakeBroker = SnapshotFakeBrokerService(recentPicks: brokerTabSnapshotRecentPicks)
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker
        )
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.policy.t3Instances = [
            T3InstanceConfig(id: "claudeAgent", name: "Claude Agent"),
            T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: nil),
        ]
        appModel.settings = settings
        appModel.brokerUIState = BrokerUIState(
            serverState: .running(port: 43117),
            lastPickSummary: "execution \u{2192} t3/gpt-5.6-sol",
            lastPickDegraded: false,
            routeHealth: [
                BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: true, why: "reachable"),
            ],
            oracleFreshness: BrokerStatus.OracleFreshness(
                present: true, stale: false, ageSeconds: 12, accounts: []
            )
        )
        return appModel
    }

    /// The tab as it opens: fixed status header, pane picker, and the Routing
    /// pane (profile bar, role/chain editor, ceilings).
    func test_brokerSettingsTab_routingPane() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(appModel: appModel, initialRecentPicks: brokerTabSnapshotRecentPicks),
            size: CGSize(width: 680, height: 900)
        )
    }

    func test_brokerSettingsTab_instancesPane() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .instances
            ),
            size: CGSize(width: 680, height: 720)
        )
    }

    /// The pick log, including the `reason` line the pre-redesign list dropped
    /// and the degraded row's treatment.
    func test_brokerSettingsTab_activityPane() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .activity
            ),
            size: CGSize(width: 680, height: 420)
        )
    }

    /// The narrowest the tab ever renders in production: `SettingsView`'s
    /// window minimum. Rendering the real container rather than assuming a
    /// content width means any width the tab's own chrome consumes shows up
    /// here rather than only on a user's screen.
    func test_brokerSettingsTab_atNarrowestWindowWidth() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(appModel: appModel, initialRecentPicks: brokerTabSnapshotRecentPicks),
            size: CGSize(width: 620, height: 900)
        )
    }

    // MARK: - Dark appearance
    //
    // The panes are rebuilt on semantic colours (`controlBackgroundColor`,
    // `.quaternary`, `.regularMaterial`) and system tints, none of which can
    // be checked by compiling. These pin that the whole tab still reads in
    // dark mode.

    func test_brokerSettingsTab_routingPane_dark() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(appModel: appModel, initialRecentPicks: brokerTabSnapshotRecentPicks),
            size: CGSize(width: 680, height: 900),
            appearance: .darkAqua
        )
    }

    func test_brokerSettingsTab_instancesPane_dark() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .instances
            ),
            size: CGSize(width: 680, height: 720),
            appearance: .darkAqua
        )
    }

    func test_brokerSettingsTab_activityPane_dark() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .activity
            ),
            size: CGSize(width: 680, height: 420),
            appearance: .darkAqua
        )
    }

    /// The profile bar carrying local edits: the "Edited" pill plus the
    /// Save/Revert pair that only exists in that state.
    func test_brokerProfileBar_editedUserProfile() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.createProfile(named: "Crunch Week")
        appModel.settings.broker.policy.thresholds.sessionPct = 61
        snapshot(
            BrokerProfileBar(appModel: appModel).padding(20),
            size: CGSize(width: 680, height: 190)
        )
    }

    /// A built-in profile cannot be overwritten, so the same edited state
    /// offers "Duplicate…" where a user profile offers "Save".
    func test_brokerProfileBar_editedBuiltInProfile() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.applyProfile(id: BrokerAgentProfile.conserveID)
        appModel.settings.broker.policy.thresholds.sessionPct = 61
        snapshot(
            BrokerProfileBar(appModel: appModel).padding(20),
            size: CGSize(width: 680, height: 190)
        )
    }

    /// Fixed instant the Instructions tab snapshots are rendered against, so
    /// the relative "checked N ago" line cannot drift as the image ages.
    private static let snapshotCheckedAt = Date(timeIntervalSince1970: 1_760_000_000)

    /// The tab after an agent has run a check, with the issue rows it found.
    func test_instructionsSettingsTab_showsTheLastRecordedCheck() {
        let appModel = makeAppModelForBrokerTabSnapshot()

        snapshot(
            InstructionsSettingsTab(
                appModel: appModel,
                initialCheck: InstructionCheck(
                    runID: "run-1",
                    caller: "claude-code",
                    checkedAt: Self.snapshotCheckedAt,
                    sources: [
                        InstructionCheckSource(
                            path: "~/.claude/CLAUDE.md",
                            status: .conflict,
                            findings: ["Conflict: retired model-broker CLI guidance."]
                        ),
                        InstructionCheckSource(
                            path: "~/.claude/skills/broker-dispatch/SKILL.md",
                            status: .warning,
                            findings: [
                                "Missing directive: caller echo validation.",
                                "Missing directive: fail-closed behavior.",
                            ]
                        ),
                        InstructionCheckSource(
                            path: "~/code/app/CLAUDE.md",
                            status: .pass,
                            findings: []
                        ),
                    ]
                ),
                now: Self.snapshotCheckedAt.addingTimeInterval(3600)
            ),
            size: CGSize(width: 620, height: 620)
        )
    }

    /// The tab with the broker off and no check ever run, which is how most of
    /// the app's users will ever see it. Everything here serves the broker, so
    /// the intro has to say that before anything else does.
    func test_instructionsSettingsTab_brokerDisabled_leadsWithTheBrokerOnlyIntro() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.isEnabled = false

        snapshot(
            InstructionsSettingsTab(appModel: appModel, initialCheck: nil),
            size: CGSize(width: 620, height: 560)
        )
    }

    func test_instructionsCheckSummary_readsFromTheRecordedCounts() {
        let now = Date(timeIntervalSince1970: 1_760_003_600)
        let check = { (sources: [InstructionCheckSource]) in
            InstructionCheck(
                runID: nil,
                caller: "claude-code",
                checkedAt: Date(timeIntervalSince1970: 1_760_000_000),
                sources: sources
            )
        }
        let pass = InstructionCheckSource(path: "a", status: .pass, findings: [])
        let warning = InstructionCheckSource(path: "b", status: .warning, findings: ["gap"])
        let conflict = InstructionCheckSource(path: "c", status: .conflict, findings: ["clash"])

        XCTAssertEqual(
            InstructionsSettingsTab.summary(for: check([pass])),
            "1 source checked, all pass."
        )
        XCTAssertEqual(
            InstructionsSettingsTab.summary(for: check([pass, warning])),
            "2 sources checked, 1 with gaps."
        )
        XCTAssertEqual(
            InstructionsSettingsTab.summary(for: check([pass, warning, conflict])),
            "3 sources checked, 1 conflict with the broker's contract."
        )
        XCTAssertEqual(
            InstructionsSettingsTab.provenance(for: check([pass]), now: now),
            "Checked 1 hour ago by claude-code."
        )
    }

    // MARK: - BrokerSettingsTab.addableDiscoveredInstances (260814-pz4, RESEARCH Q-2)

    /// A `Menu`'s contents are not visible to a snapshot, so this pure filter
    /// is covered directly, mirroring `setupPrompt(port:)`'s test pattern.
    func test_brokerSettingsTab_addableDiscoveredInstances_offersOnlyInstalledUnaddedInstances() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "WS", installed: true),
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", displayName: "Codex", installed: true),
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", displayName: "Cursor", installed: true),
            DiscoveredT3Instance(instanceId: "grok", driver: "grok", displayName: "Grok", installed: false),
            DiscoveredT3Instance(instanceId: "opencode", driver: "opencode", displayName: "OpenCode", installed: false),
            DiscoveredT3Instance(instanceId: "future", driver: "future", displayName: "Future", installed: false),
        ]

        let addable = BrokerSettingsTab.addableDiscoveredInstances(discovered: discovered, existing: [])

        XCTAssertEqual(Set(addable.map(\.instanceId)), Set(["claudeAgent", "codex", "cursor"]))
    }

    func test_brokerSettingsTab_addableDiscoveredInstances_excludesInstancesWithExistingRows() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", installed: true),
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true),
        ]
        let existing = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]

        let addable = BrokerSettingsTab.addableDiscoveredInstances(discovered: discovered, existing: existing)

        XCTAssertEqual(addable.map(\.instanceId), ["codex"])
    }

    func test_brokerSettingsTab_addableDiscoveredInstances_allExistingRows_offersOnlyManualChoice() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", installed: true),
        ]
        let existing = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]

        let addable = BrokerSettingsTab.addableDiscoveredInstances(discovered: discovered, existing: existing)

        XCTAssertTrue(addable.isEmpty)
    }

    func test_brokerSetupPrompt_usesConfiguredEndpointAndBothHarnesses() {
        let prompt = BrokerSettingsTab.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("http://127.0.0.1:54321/mcp"))
        XCTAssertTrue(prompt.contains("pinemeter-broker"))
        XCTAssertTrue(prompt.contains("Claude Code"))
        XCTAssertTrue(prompt.contains("Codex"))
    }

    func test_brokerSetupPrompt_requiresCallerEchoAndKnownRoutePairs() {
        let prompt = BrokerSettingsTab.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("active harness: `claude-code` for Claude Code or `codex` for Codex"))
        XCTAssertTrue(prompt.contains("non-empty `role`, `caller`, `route`, `model`, and `invocation`"))
        XCTAssertTrue(prompt.contains("exactly matches the caller sent"))
        XCTAssertTrue(prompt.contains("`native` with `agent`"))
        XCTAssertTrue(prompt.contains("`t3` with `t3-dispatch`"))
        XCTAssertTrue(prompt.contains("`codex` with `codex-exec`"))
    }

    func test_brokerSetupPrompt_failsClosedAndRequiresApprovalBeforeWrites() {
        let prompt = BrokerSettingsTab.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("Stop without dispatching"))
        XCTAssertTrue(prompt.contains("launch or update Pinemeter and confirm the registered endpoint"))
        XCTAssertTrue(prompt.contains("Never add a second broker client, policy layer, endpoint, fallback, secret, or external routing machinery"))
        XCTAssertTrue(prompt.contains("Show the exact proposed commands and user-file edits"))
        XCTAssertTrue(prompt.contains("Wait for explicit approval before changing user files"))
    }

    func test_brokerSetupPrompt_requiresNestedSelectionAndFinalPrecedenceAudit() {
        let prompt = BrokerSettingsTab.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("every task and every nested subtask"))
        XCTAssertTrue(prompt.contains("call Pinemeter first"))
        XCTAssertTrue(prompt.contains("child-agent definition that can spawn or delegate"))
        XCTAssertTrue(prompt.contains("final effective instruction order"))
        XCTAssertTrue(prompt.contains("later-precedence user, project, skill, and agent instructions"))
        XCTAssertTrue(prompt.contains("Fail validation on any explicit bypass or alternate broker"))
    }

    // MARK: - BrokerPolicyEditorView (Task 3)

    private func makeAppModelForPolicyEditorSnapshot() -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            brokerService: SnapshotFakeBrokerService(recentPicks: [])
        )
    }

    func test_brokerPolicyEditor_bundledDefaultPolicy_planningRoleSelected() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        // AppSettings.default already carries BrokerPolicy.bundledDefault.
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning"),
            size: CGSize(width: 640, height: 560)
        )
    }

    func test_brokerPolicyEditor_t3RowShowsInstancePicker() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        // "execution"'s top candidate in the bundled default policy is
        // t3-routed, so selecting it renders the t3 instance picker.
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution"),
            size: CGSize(width: 640, height: 560)
        )
    }

    /// The layout gate the wide images cannot enforce: the narrowest editor
    /// production ever renders, which is `SettingsView`'s 620pt minimum window
    /// less `BrokerSettingsTab`'s 20pt pane padding on each side. "execution"
    /// is selected because its top candidate is t3-routed, so this is the
    /// widest row type (rank, route, model, actions above instance and
    /// effort) at the narrowest width.
    func test_brokerPolicyEditor_t3RowAtNarrowestProductionWidth() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution"),
            size: CGSize(width: 580, height: 560)
        )
    }

    func test_brokerPolicyEditor_knownModelIDsAreSortedDeduplicatedPolicyUnion() {
        let policy = BrokerPolicy(
            roles: [
                "planning": [
                    BrokerCandidate(route: .native, model: "candidate-only"),
                    BrokerCandidate(route: .t3, model: "shared"),
                ],
                "review": [BrokerCandidate(route: .native, model: "zeta")],
            ],
            agentModelAliases: [
                "alias-only": "alias",
                "shared": "shared",
            ]
        )

        XCTAssertEqual(
            BrokerPolicyEditorView.knownModelIDs(in: policy),
            ["alias-only", "candidate-only", "shared", "zeta"]
        )
    }

    func test_brokerPolicyEditor_customModelIsVisible() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        appModel.settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "vendor/custom-model")
        ]

        XCTAssertTrue(
            BrokerPolicyEditorView.knownModelIDs(in: appModel.settings.broker.policy)
                .contains("vendor/custom-model")
        )
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning"),
            size: CGSize(width: 640, height: 560)
        )
    }
}

/// Minimal `BrokerLifecycleProtocol` fake for rendering `BrokerSettingsTab`
/// with a canned recent-picks ring buffer — no real actor state, no IO.
private actor SnapshotFakeBrokerService: BrokerLifecycleProtocol {
    private let seededRecentPicks: [RecentPick]
    private var uiState = BrokerUIState.initial

    init(recentPicks: [RecentPick]) {
        self.seededRecentPicks = recentPicks
    }

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        throw BrokerError.configError("SnapshotFakeBrokerService.pick is unconfigured")
    }

    func status() async -> BrokerStatus {
        BrokerStatus(
            running: false,
            port: nil,
            oracle: BrokerStatus.OracleFreshness(present: false, stale: false, ageSeconds: nil, accounts: []),
            cooldowns: [],
            t3: [],
            roles: [],
            recentPicksCount: seededRecentPicks.count
        )
    }

    func down(target: String, minutes: Int?) async throws {}
    func up(target: String) async throws {}
    func refresh() async throws {}
    func updatePolicy(_ policy: BrokerPolicy) async {}
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async {}
    func updateT3Liveness(_ liveness: [String: T3Liveness]) async {}
    func updateServerState(_ state: BrokerUIState.ServerState) async { uiState.serverState = state }
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) async {}
    func uiStateUpdates() async -> AsyncStream<BrokerUIState> {
        AsyncStream { continuation in
            continuation.yield(uiState)
            continuation.finish()
        }
    }
    func recentPicks() async -> [RecentPick] { seededRecentPicks }
}
