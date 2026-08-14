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
    // MARK: - Harness

    /// Renders `view` inside a fixed-size `NSHostingView` under forced light
    /// appearance and asserts it against the committed reference image.
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
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        assertSnapshot(
            of: hostingView,
            as: .image(size: size),
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
                BrokerStatus.RouteHealth(instanceId: "claude_autimo", reachable: true, why: "reachable"),
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
            brokerService: fakeBroker
        )
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.policy.t3Instances = [
            T3InstanceConfig(id: "claudeAgent", name: "Claude Agent"),
            T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)", boundAccountId: nil),
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

    func test_brokerSettingsTab_enabledWithInstancesAndPicks() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(appModel: appModel, initialRecentPicks: brokerTabSnapshotRecentPicks),
            size: CGSize(width: 620, height: 900)
        )
    }

    // MARK: - BrokerPolicyEditorView (Task 3)

    private func makeAppModelForPolicyEditorSnapshot() -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            brokerService: SnapshotFakeBrokerService(recentPicks: [])
        )
    }

    func test_brokerPolicyEditor_bundledDefaultPolicy_planningRoleSelected() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        // AppSettings.default already carries BrokerPolicy.bundledDefault.
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning"),
            size: CGSize(width: 620, height: 420)
        )
    }

    func test_brokerPolicyEditor_t3RowShowsInstancePicker() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        // "execution"'s top candidate in the bundled default policy is
        // t3-routed, so selecting it renders the t3 instance picker.
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution"),
            size: CGSize(width: 620, height: 420)
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

    func down(target: String, minutes: Int?) async {}
    func up(target: String) async {}
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
