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
    private final class SnapshotWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func disableControlFocus(in view: NSView) {
        (view as? NSControl)?.refusesFirstResponder = true
        view.subviews.forEach(disableControlFocus)
    }

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
    /// Keep the required render window non-key and its key-view loop fixed.
    /// AppKit can otherwise focus a nested field and animate its scroll view
    /// while the bitmap is captured.
    ///
    /// Broker tab callers use 0.98 perceptual precision for the header's
    /// `NSVisualEffectView`. This tolerates colour shifts in at most 1% of
    /// pixels; moved or resized content still fails well below that threshold.
    private func snapshot<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name = .aqua,
        precision: Float = 1,
        perceptualPrecision: Float = 1,
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
                .environment(\.locale, Locale(identifier: "en_CA"))
        )
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: appearance)

        let window = SnapshotWindow(
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.initialFirstResponder = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        disableControlFocus(in: hostingView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.orderFrontRegardless()
            window.makeFirstResponder(hostingView)
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            disableControlFocus(in: hostingView)
            window.displayIfNeeded()

            assertSnapshot(
                of: hostingView,
                as: .image(
                    precision: precision,
                    perceptualPrecision: perceptualPrecision,
                    size: size
                ),
                named: name,
                file: file,
                testName: testName,
                line: line
            )
        }

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

    func test_brokerCard_auditPersistenceFailure() {
        let uiState = BrokerUIState(
            serverState: .running(port: 43117),
            lastPickSummary: nil,
            lastPickDegraded: false,
            auditPersistenceFailed: true,
            routeHealth: [],
            oracleFreshness: BrokerStatus.OracleFreshness(
                present: true, stale: false, ageSeconds: 12, accounts: []
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
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 680, height: 900),
            precision: 0.99,
            perceptualPrecision: 0.98
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
            size: CGSize(width: 680, height: 720),
            precision: 0.99,
            perceptualPrecision: 0.98
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
            size: CGSize(width: 680, height: 420),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// The narrowest the tab ever renders in production: `SettingsView`'s
    /// window minimum. Rendering the real container rather than assuming a
    /// content width means any width the tab's own chrome consumes shows up
    /// here rather than only on a user's screen.
    func test_brokerSettingsTab_atNarrowestWindowWidth() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 620, height: 900),
            precision: 0.99,
            perceptualPrecision: 0.98
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
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: brokerTabSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 680, height: 900),
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
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
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
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
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
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

    /// A built-in whose rules the manifest has moved on from: the "Manifest"
    /// chip says the loaded rules were published rather than shipped, and
    /// "Updated" says newer published rules are waiting to be picked.
    func test_brokerProfileBar_builtInWithManifestRules() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.applyProfile(id: BrokerAgentProfile.balancedID)
        var published = BrokerAgentProfile.balanced.rules
        published.roles["planning"] = [BrokerCandidate(route: .auto, model: "claude-sonnet-5")]
        appModel.settings.broker.updateRemotePresets([
            BrokerAgentProfile(
                id: BrokerAgentProfile.balancedID,
                name: "Ignored",
                detail: "",
                symbolName: "leaf",
                rules: published
            ),
        ])
        snapshot(
            BrokerProfileBar(appModel: appModel).padding(20),
            size: CGSize(width: 680, height: 190)
        )
    }

    func test_brokerProfileBar_manifestBadge_isSilentWhenThePublishedRulesMatchTheBuild() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.applyProfile(id: BrokerAgentProfile.balancedID)
        appModel.settings.broker.updateRemotePresets([
            BrokerAgentProfile(
                id: BrokerAgentProfile.balancedID,
                name: "Ignored",
                detail: "",
                symbolName: "leaf",
                rules: BrokerAgentProfile.balanced.rules
            ),
        ])

        XCTAssertFalse(
            appModel.settings.broker.manifestSuppliesRules(id: BrokerAgentProfile.balancedID),
            "the manifest republishes every built-in; badging one that agrees with the build "
                + "would spend the badge on the case nobody needs told about"
        )
        XCTAssertFalse(appModel.settings.broker.activeProfileHasUpdatedRules)
    }

    func test_brokerProfileBar_menuTitle_marksRulesThatCameFromTheManifest() {
        let profile = BrokerAgentProfile.balanced

        XCTAssertEqual(
            BrokerProfileBar.menuTitle(for: profile, isActive: false, isFromManifest: false),
            "Balanced"
        )
        XCTAssertEqual(
            BrokerProfileBar.menuTitle(for: profile, isActive: true, isFromManifest: false),
            "\u{2713} Balanced"
        )
        XCTAssertEqual(
            BrokerProfileBar.menuTitle(for: profile, isActive: true, isFromManifest: true),
            "\u{2713} Balanced (manifest rules)",
            "a built-in renders in the Built-in section under its compiled name, so the "
                + "row itself has to say the rules came off the network"
        )
    }

    /// Fixed instant the Instructions pane snapshots are rendered against, so
    /// the relative "checked N ago" line cannot drift as the image ages.
    private static let snapshotCheckedAt = Date(timeIntervalSince1970: 1_760_000_000)

    /// The build the Instructions pane snapshots are rendered against, paired
    /// with each record's `gradedBy` so the re-check banner is in whichever
    /// state the case is about rather than in whatever state the recording
    /// machine's own version put it.
    private static let snapshotVersion = "1.1.0"

    /// The pane after an agent has run a check, with the issue rows it found.
    /// Rendered with the pane padding its container applies, so the image is
    /// what the Broker tab draws.
    func test_brokerInstructionsPane_showsTheLastRecordedCheck() {
        let appModel = makeAppModelForBrokerTabSnapshot()

        snapshot(
            BrokerInstructionsPane(
                appModel: appModel,
                initialCheck: InstructionCheck(
                    runID: "run-1",
                    caller: "claude-code",
                    checkedAt: Self.snapshotCheckedAt,
                    gradedBy: Self.snapshotVersion,
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
                now: Self.snapshotCheckedAt.addingTimeInterval(3600),
                currentVersion: Self.snapshotVersion
            )
            .padding(BrokerUI.panePadding),
            size: CGSize(width: 620, height: 620)
        )
    }

    /// The same card once the record has stopped counting as evidence: a
    /// clean pass, graded by this build, gone stale on the shelf. The banner
    /// is the only thing that says so, which is why it is pinned in pixels.
    func test_brokerInstructionsPane_staleCheckShowsTheRecheckBanner() {
        let appModel = makeAppModelForBrokerTabSnapshot()

        snapshot(
            BrokerInstructionsPane(
                appModel: appModel,
                initialCheck: InstructionCheck(
                    runID: "run-1",
                    caller: "claude-code",
                    checkedAt: Self.snapshotCheckedAt,
                    gradedBy: Self.snapshotVersion,
                    sources: [
                        InstructionCheckSource(path: "~/.claude/CLAUDE.md", status: .pass, findings: []),
                        InstructionCheckSource(path: "~/code/app/CLAUDE.md", status: .pass, findings: []),
                    ]
                ),
                now: Self.snapshotCheckedAt.addingTimeInterval(InstructionRecheck.interval + 3600),
                currentVersion: Self.snapshotVersion
            )
            .padding(BrokerUI.panePadding),
            size: CGSize(width: 620, height: 480)
        )
    }

    /// The pane on a machine where no agent has ever run a check, which is how
    /// most of the app's users will ever see it. `initialCheck: nil` with the
    /// record already loaded is the empty state, not the spinner.
    func test_brokerInstructionsPane_withNoCheckRecorded() {
        let appModel = makeAppModelForBrokerTabSnapshot()

        snapshot(
            BrokerInstructionsPane(appModel: appModel, initialCheck: nil, hasLoadedCheck: true)
                .padding(BrokerUI.panePadding),
            size: CGSize(width: 620, height: 420)
        )
    }

    /// The whole tab with the broker turned off: the header drops the endpoint
    /// and health rows, and the toggle is the only thing left to act on. This
    /// is the state the app ships in until someone opts into the broker.
    func test_brokerSettingsTab_brokerDisabled() {
        let appModel = makeAppModelForBrokerTabSnapshot()
        appModel.settings.broker.isEnabled = false

        snapshot(
            BrokerSettingsTab(
                appModel: appModel,
                initialRecentPicks: [],
                initialPane: .instructions
            ),
            size: CGSize(width: 620, height: 560),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// Both banners have to end at the one action that clears them, and the
    /// never-checked case has to stay silent: the card's own empty state
    /// already asks for a first check, in more useful words.
    func test_instructionsRecheckBanner_namesTheActionAndSkipsTheEmptyState() throws {
        let rerun = "run the server's `configure` prompt in a registered agent."

        let updated = try XCTUnwrap(BrokerInstructionsPane.recheckMessage(for: .contractMayHaveChanged))
        XCTAssertTrue(updated.contains("Pinemeter has updated"))
        XCTAssertTrue(updated.hasSuffix(rerun))

        let stale = try XCTUnwrap(BrokerInstructionsPane.recheckMessage(for: .stale))
        XCTAssertTrue(stale.contains("more than 14 days old"))
        XCTAssertTrue(stale.hasSuffix(rerun))

        XCTAssertNil(BrokerInstructionsPane.recheckMessage(for: .neverChecked))
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
            BrokerInstructionsPane.summary(for: check([pass])),
            "1 source checked, all pass."
        )
        XCTAssertEqual(
            BrokerInstructionsPane.summary(for: check([pass, warning])),
            "2 sources checked, 1 with gaps."
        )
        XCTAssertEqual(
            BrokerInstructionsPane.summary(for: check([pass, warning, conflict])),
            "3 sources checked, 1 conflict with the broker's contract."
        )
        XCTAssertEqual(
            BrokerInstructionsPane.provenance(for: check([pass]), now: now),
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

    func test_brokerPolicyEditor_executionModels() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution"),
            size: CGSize(width: 640, height: 560)
        )
    }

    /// The layout gate the wide images cannot enforce: the narrowest editor
    /// production ever renders, which is `SettingsView`'s 620pt minimum window
    /// less `BrokerSettingsTab`'s 20pt pane padding on each side.
    func test_brokerPolicyEditor_executionAtNarrowestProductionWidth() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        snapshot(
            BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution"),
            size: CGSize(width: 580, height: 560)
        )
    }

    func test_brokerPolicyEditor_knownModelIDsLeadWithChainModelsThenAliasOnly() {
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
            ["candidate-only", "shared", "zeta", "alias-only"]
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
