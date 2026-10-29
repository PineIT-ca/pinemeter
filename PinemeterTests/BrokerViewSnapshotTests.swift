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

    /// Recording is opt-in and cannot change any reference outside this plan.
    private static let localRouteSnapshotMethods: Set<String> = [
        "test_brokerWindow_instancesPane", "test_brokerWindow_instancesPane_unreachableAndUnprobed",
        "test_brokerWindow_instancesPane_dark", "test_brokerPolicyEditor_executionModels",
        "test_brokerPolicyEditor_executionAtNarrowestProductionWidth",
        "test_brokerInstancesPane_localRoutes_states", "test_brokerInstancesPane_localRoutes_narrowest",
        "test_brokerPolicyEditor_controlledOnly_noRoute"
    ]

    /// Renders `view` inside a fixed-size `NSHostingView` under a forced
    /// appearance and asserts it against the committed reference image.
    ///
    /// `appearance` defaults to light. The Broker window is the one surface in
    /// the app built entirely from semantic colours and materials rather than
    /// fixed ones, so it gets dark coverage too: a hardcoded colour that
    /// happens to read on white is invisible against a dark card, and no
    /// compile or unit test can catch that.
    ///
    /// Keep the required render window non-key and its key-view loop fixed.
    /// AppKit can otherwise focus a nested field and animate its scroll view
    /// while the bitmap is captured.
    ///
    /// Broker window callers use 0.98 perceptual precision for the header's
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
                record: Self.localRouteSnapshotMethods.contains(testName.replacingOccurrences(of: "()", with: ""))
                    && ProcessInfo.processInfo.environment["PINEMETER_RECORD_LOCAL_ROUTE_SNAPSHOTS"] == "1" ? true : nil,
                file: file,
                testName: testName,
                line: line
            )
        }

        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: - BrokerCardView (Task 1)

    func test_releaseWelcome_lightAndDark() {
        let model = makeAppModelForBrokerWindowSnapshot()
        model.settings.broker.isEnabled = false
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            snapshot(SetupWizardView(appModel: model), size: CGSize(width: 440, height: 640),
                     appearance: appearance, named: appearance.rawValue)
        }
    }

    func test_releaseDashboard_quotaColumns_lightAndDark() {
        let model = makeAppModelForBrokerWindowSnapshot()
        DemoDataFactory.configure(model, for: .multiProvider)
        model.settings.broker.isEnabled = false
        model.settings.subscriptionResetAnnouncementMode = .localResetTime
        let now = Self.snapshotCheckedAt
        func usage(_ value: Double, updated: Date) -> UsageData {
            UsageData(sessionUsage: .init(utilization: value, resetAt: now.addingTimeInterval(10800)),
                      weeklyUsage: .init(utilization: 28, resetAt: now.addingTimeInterval(345600)),
                      sonnetUsage: nil, lastUpdated: updated)
        }
        model.usageData = usage(42, updated: now)
        model.claudeAccountUsage["22222222-2222-2222-2222-222222222222"] = usage(92, updated: now.addingTimeInterval(-7200))
        model.chatGPTUsageData = .init(rows: [.init(label: "Codex", usedPercent: 34, resetAt: now.addingTimeInterval(18000), menuBarRole: .chatGPT5h)], lastUpdated: now)
        model.geminiUsageData = .init(label: "Gemini API quota", usedPercent: 12, resetAt: now.addingTimeInterval(36000), lastUpdated: now)
        XCTAssertTrue(model.usageQuotaBars.allSatisfy { $0.provider != nil && $0.lastUpdated != nil })
        XCTAssertEqual(model.usageQuotaBars.filter { $0.owner == "Personal" }.first?.lastUpdated, now.addingTimeInterval(-7200))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            snapshot(UsagePopoverView(appModel: model, onRequestClose: nil, referenceDate: now),
                     size: CGSize(width: QuotaChartLayout.popoverWidth(for: model.usageQuotaBars), height: 640), appearance: appearance, named: appearance.rawValue)
        }
    }

    func test_resetLabels_paletteColors_lightAndDark() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            snapshot(
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(MenuBarColorScheme.allCases) { palette in
                        HStack(alignment: .top, spacing: 8) {
                            Text(palette.title).frame(width: 80, alignment: .leading)
                            QuotaResetLabel(detail: "Fri at 8:30pm\nin 4d 6h 15m", palette: palette).frame(width: 72)
                            QuotaResetLabel(detail: "Today at 6:30pm\nin 6h 15m", palette: palette).frame(width: 72)
                            QuotaResetLabel(detail: "Today at 6:30pm\nin 15m", palette: palette).frame(width: 72)
                            QuotaResetLabel(detail: "now", palette: palette).frame(width: 72)
                        }
                    }
                }.padding(16),
                size: CGSize(width: 440, height: 680), appearance: appearance, named: appearance.rawValue
            )
        }
    }

    func test_releaseAccounts_multipleProvidersAtMinimumWidth() {
        let model = makeAppModelForBrokerWindowSnapshot()
        DemoDataFactory.configure(model, for: .multiProvider)
        model.settings.claudeAccounts[0].customLabel = "Work · Design and engineering"
        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.object(forKey: SettingsView.selectedTabDefaultsKey)
        defer { defaults.set(previous, forKey: SettingsView.selectedTabDefaultsKey) }
        SettingsView.selectTab(.accounts)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // The Settings window is a fixed 640pt wide, two cards per row;
            // tall enough for four cards and the Gemini key row.
            snapshot(SettingsView(appModel: model), size: CGSize(width: 640, height: 560),
                     appearance: appearance, named: appearance.rawValue)
        }
    }

    func test_browserSessionImportReview_selectiveSessionsAndPartialFailure() {
        let model = makeAppModelForBrokerWindowSnapshot()
        let review = BrowserSessionImportReview(
            scannedBrowsers: [.chrome, .safari],
            sessions: [
                BrowserSessionImportSession(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    provider: .claude,
                    source: .chrome,
                    profileLabel: "Profile 2",
                    credential: .claudeSessionKey("snapshot-secret-never-rendered")
                ),
                BrowserSessionImportSession(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    provider: .chatGPT,
                    source: .chrome,
                    profileLabel: "Work",
                    credential: .chatGPTCookie("snapshot-cookie-never-rendered")
                ),
            ],
            failures: [BrowserSessionImportFailure(
                provider: .claude,
                source: .safari,
                message: "Safari needs Full Disk Access to import cookies.",
                offersFullDiskAccessSettings: true
            )]
        )

        snapshot(
            BrowserSessionImportReviewView(appModel: model, review: review),
            size: CGSize(width: 480, height: 500)
        )
    }

    func test_releaseBrokerWithoutUsageAccounts() {
        let model = makeAppModelForBrokerWindowSnapshot()
        model.brokerUIState?.oracleFreshness = .init(present: false, stale: true, ageSeconds: nil, accounts: [])
        model.brokerUIState?.lastPickSummary = nil
        snapshot(UsagePopoverView(appModel: model, onRequestClose: nil),
                 size: CGSize(width: 400, height: 460))
    }

    func test_releasePopoverFitsContentAndCapsLongErrors() {
        let model = makeAppModelForBrokerWindowSnapshot()
        let compact = NSHostingView(rootView: UsagePopoverView(appModel: model, onRequestClose: nil))
        let compactHeight = compact.fittingSize.height
        XCTAssertLessThan(compactHeight, 520)
        XCTAssertGreaterThan(compactHeight, 200)

        model.errorMessage = String(repeating: "The provider could not be reached. Check your connection and retry. ", count: 30)
        let long = NSHostingView(rootView: UsagePopoverView(appModel: model, onRequestClose: nil))
        XCTAssertLessThanOrEqual(long.fittingSize.height, 650, "Long errors must scroll without pushing Settings and Quit offscreen")
        XCTAssertLessThanOrEqual(long.fittingSize.width, 720)
    }

    func test_releaseBrokerFailure_keepsRecoveryVisible() {
        let model = makeAppModelForBrokerWindowSnapshot()
        model.brokerUIState?.serverState = .failed(message: "Port 43117 is already in use.")
        // The one-row header puts the port field beside the status text; its
        // digits render in either the field or its editor, a few pixels apart,
        // so this uses the same tolerance as the other broker window images.
        snapshot(BrokerStatusHeader(appModel: model), size: CGSize(width: 580, height: 210),
                 precision: 0.99, perceptualPrecision: 0.98)
        // The pixel tolerance above could absorb a low-contrast button, so the
        // recovery control this test protects is also asserted directly.
        XCTAssertTrue(BrokerStatusHeader(appModel: model).showsRetry)
        model.brokerUIState?.serverState = .running(port: 43117)
        XCTAssertFalse(BrokerStatusHeader(appModel: model).showsRetry)
    }

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

    func test_brokerCard_routingUpdateAvailable() {
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
            BrokerCardView(uiState: uiState, isEnabled: true, hasRoutingUpdate: true),
            size: CGSize(width: 320, height: 190)
        )
    }

    func test_brokerCard_degradedLastPick() {
        let uiState = BrokerUIState(
            serverState: .running(port: 43117),
            lastPickSummary: "planning \u{2192} native/claude-sonnet-5",
            lastPickDegraded: true,
            lastPickDegradedReason: "forced-degraded: every candidate is over its quota ceiling",
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
            size: CGSize(width: 320, height: 400)
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
            size: CGSize(width: 320, height: 230)
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
            size: CGSize(width: 320, height: 220)
        )
    }

    // MARK: - BrokerWindowView (Task 2)

    /// A representative `AppModel`, bootstrapped enough to render the Broker
    /// window without touching disk/network: broker enabled, two T3 instances,
    /// and a running server state, and three recent picks (one degraded)
    /// served by `SnapshotFakeBrokerService.recentPicks()`.
    ///
    /// Timestamps are hour-scale offsets, not seconds/minutes: `Text(_:
    /// style: .relative)` renders live text that only changes once a full
    /// additional hour elapses, so the recorded image stays stable across
    /// the few seconds between a recording run and a verification run —
    /// second/minute-scale offsets flip their displayed text within that gap
    /// and make the snapshot flaky.
    private let brokerWindowSnapshotRecentPicks: [RecentPick] = [
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

    private func makeAppModelForBrokerWindowSnapshot(
        outcomeTrend: BrokerOutcomeView? = nil
    ) -> AppModel {
        let fakeBroker = SnapshotFakeBrokerService(
            recentPicks: brokerWindowSnapshotRecentPicks,
            outcomeTrend: outcomeTrend
        )
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

    private func makeHistorySnapshot(
        revision: Int,
        rules: BrokerRuleSet,
        summary: String? = nil,
        age: TimeInterval = 86_400
    ) -> BrokerManifestHistorySnapshot {
        var profile = BrokerAgentProfile.balanced
        profile.rules = rules
        let presets = [profile]
        return BrokerManifestHistorySnapshot(
            id: UUID(),
            recordedAt: Date().addingTimeInterval(-age),
            contentDigest: try! BrokerManifestHistoryStore.contentDigest(
                presets: presets,
                agentSetup: nil
            ),
            presets: presets,
            agentSetup: nil,
            manifestRevision: revision,
            publishedAt: Date().addingTimeInterval(-age),
            summary: summary
        )
    }

    private func makeHistoryModel(
        revisions: [BrokerManifestHistorySnapshot],
        live: BrokerManifestHistorySnapshot? = nil,
        sourceID: UUID = UUID(),
        urlString: String = "https://example.com/broker-presets.json"
    ) -> AppModel {
        let model = makeAppModelForBrokerWindowSnapshot()
        let source = BrokerPresetManifestSource(
            id: sourceID,
            urlString: urlString,
            cachedPresets: revisions.first?.presets ?? []
        )
        var settings = model.settings.broker
        settings.presetManifest = BrokerPresetManifestConfig(isEnabled: true, sources: [source])
        if let live, let profile = live.profile(id: BrokerAgentProfile.balancedID) {
            settings.updateRemotePresets([profile])
            settings.applyProfile(id: profile.id)
            settings.routingRecovery = BrokerRoutingRecovery(
                profileID: profile.id,
                profileName: profile.name,
                previousRules: profile.rules,
                previousBaseline: profile.rules,
                appliedRules: profile.rules,
                origin: "revision",
                source: BrokerManifestHistoryNamespace(sourceID: source.id, urlString: source.urlString),
                revisionFingerprint: live.contentDigest
            )
        } else {
            settings.applyProfile(id: BrokerAgentProfile.balancedID)
        }
        model.settings.broker = settings
        return model
    }

    func test_manifestHistory_emptyLoadingError() {
        let model = makeAppModelForBrokerWindowSnapshot()
        let states: [BrokerManifestHistoryState] = [.loaded([]), .loading, .readError]
        model.settings.broker.presetManifest.sources = states.enumerated().map { index, _ in
            BrokerPresetManifestSource(urlString: "https://example.com/state-\(index).json")
        }
        let byID = Dictionary(uniqueKeysWithValues: zip(
            model.settings.broker.presetManifest.sources.map(\.id),
            states
        ))

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(
                BrokerPresetManifestCard(
                    appModel: model,
                    historyStateOverride: { byID[$0.id] ?? .loaded([]) }
                ),
                size: CGSize(width: 620, height: 600),
                appearance: appearance,
                named: "manifest-history-empty-loading-error-\(appearance.rawValue)"
            )
        }
    }

    func test_manifestHistory_populatedLatestLive() {
        var firstRules = BrokerRuleSet.default
        firstRules.thresholds.weeklyPct = 70
        var liveRules = BrokerRuleSet.default
        liveRules.thresholds.weeklyPct = 75
        var latestRules = BrokerRuleSet.default
        latestRules.thresholds.weeklyPct = 80
        let revisions = [
            makeHistorySnapshot(revision: 14, rules: latestRules, age: 86_400),
            makeHistorySnapshot(revision: 13, rules: liveRules, age: 172_800),
            makeHistorySnapshot(revision: 12, rules: firstRules, age: 259_200),
        ]
        let model = makeHistoryModel(revisions: revisions, live: revisions[1])

        snapshot(
            BrokerPresetManifestCard(
                appModel: model,
                historyStateOverride: { _ in .loaded(revisions) }
            ),
            size: CGSize(width: 620, height: 600),
            named: "manifest-history-populated-latest-live"
        )
    }

    func test_manifestHistory_oneAndTenRows() {
        let one = makeHistorySnapshot(revision: 1, rules: .default)
        let oneModel = makeHistoryModel(revisions: [one], live: one)
        snapshot(
            BrokerPresetManifestCard(
                appModel: oneModel,
                historyStateOverride: { _ in .loaded([one]) }
            ),
            size: CGSize(width: 620, height: 420),
            named: "manifest-history-one-row-latest-live"
        )

        let ten = (1...10).reversed().map { revision in
            var rules = BrokerRuleSet.default
            rules.thresholds.weeklyPct = Double(60 + revision)
            return makeHistorySnapshot(
                revision: revision,
                rules: rules,
                age: TimeInterval((11 - revision) * 86_400)
            )
        }
        let tenModel = makeHistoryModel(revisions: ten, live: ten[4])
        snapshot(
            BrokerPresetManifestCard(
                appModel: tenModel,
                historyStateOverride: { _ in .loaded(ten) }
            ),
            size: CGSize(width: 620, height: 1_260),
            named: "manifest-history-ten-rows"
        )
    }

    func test_manifestHistory_longSummaryAtMinimumWidth() {
        let revision = makeHistorySnapshot(
            revision: 14,
            rules: .default,
            summary: String(repeating: "A", count: 240)
        )
        let model = makeHistoryModel(revisions: [revision], live: revision)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(
                BrokerPresetManifestCard(
                    appModel: model,
                    historyStateOverride: { _ in .loaded([revision]) }
                ),
                size: CGSize(width: 620, height: 600),
                appearance: appearance,
                named: "manifest-history-long-summary-\(appearance.rawValue)"
            )
        }
    }

    private func makeRevisionReview(
        old: BrokerRuleSet,
        new: BrokerRuleSet,
        summary: String? = nil,
        validationError: String? = nil,
        unsavedEdit: Bool = false
    ) -> BrokerRoutingUpdateReview {
        let model = makeAppModelForBrokerWindowSnapshot()
        var settings = model.settings.broker
        settings.updateRemotePresets([BrokerAgentProfile.balanced])
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        settings.policy.assignExactRules(old)
        settings.activeProfileRules = old
        if unsavedEdit { settings.policy.thresholds.weeklyPct += 1 }
        model.settings.broker = settings
        let snapshot = makeHistorySnapshot(revision: 14, rules: new, summary: summary)
        let source = BrokerManifestHistoryNamespace(
            sourceID: UUID(),
            urlString: "https://example.com/broker-presets.json"
        )
        let selection = BrokerRevisionSelection(
            namespace: source,
            snapshot: snapshot,
            profileID: BrokerAgentProfile.balancedID
        )
        return BrokerRoutingUpdateReview(
            appModel: model,
            revision: selection,
            revisionValidation: { _ in validationError },
            onApplied: {}
        )
    }

    func test_revisionReview_semanticDiff() {
        var old = BrokerRuleSet.default
        old.roles["design"] = [BrokerCandidate(route: .native, model: "old-design", effort: .high)]
        var new = old
        new.roles["design"] = [
            BrokerCandidate(route: .codex, model: "model-1", effort: .low),
            BrokerCandidate(route: .native, model: "model-2", effort: .medium),
            BrokerCandidate(route: .codex, model: "model-3", effort: .high),
            BrokerCandidate(route: .native, model: "model-4", effort: .xhigh),
            BrokerCandidate(route: .codex, model: "model-5"),
        ]
        new.roles["planning"] = [BrokerCandidate(route: .native, model: "new-planning")]
        new.roles.removeValue(forKey: "explore")
        new.thresholds.weeklyPct = 80
        new.allowForcedDegraded["review"] = false

        let view = makeRevisionReview(old: old, new: new)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(
                view,
                size: CGSize(width: 480, height: 760),
                appearance: appearance,
                named: "revision-review-semantic-diff-five-candidates-\(appearance.rawValue)"
            )
        }
    }

    func test_revisionReview_unsavedEdits() {
        var new = BrokerRuleSet.default
        new.thresholds.weeklyPct = 80
        snapshot(
            makeRevisionReview(old: .default, new: new, unsavedEdit: true),
            size: CGSize(width: 480, height: 720),
            named: "revision-review-unsaved-edits"
        )
    }

    func test_revisionReview_unroutableBlocked() {
        var new = BrokerRuleSet.default
        new.roles["planning"] = [
            BrokerCandidate(route: .t3, instance: "missing", model: "unavailable-model"),
        ]
        snapshot(
            makeRevisionReview(
                old: .default,
                new: new,
                validationError: "It refers to an instance this Mac doesn't have (missing)"
            ),
            size: CGSize(width: 480, height: 760),
            named: "revision-review-unroutable-blocked"
        )
    }

    func test_revisionReview_noDifferences() {
        snapshot(
            makeRevisionReview(old: .default, new: .default),
            size: CGSize(width: 480, height: 620),
            named: "revision-review-no-differences"
        )
    }

    func test_undoBanner_afterRestore() {
        let model = makeAppModelForBrokerWindowSnapshot()
        var settings = model.settings.broker
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        var revision = BrokerRuleSet.default
        revision.thresholds.weeklyPct = 80
        XCTAssertTrue(settings.restoreProfileRules(id: BrokerAgentProfile.balancedID, rules: revision))
        model.settings.broker = settings
        snapshot(
            BrokerRoutingUpdateBanner(appModel: model),
            size: CGSize(width: 320, height: 260),
            named: "undo-banner-after-restore"
        )
    }

    func test_routingUpdate_narrowBannerAndReview() {
        let model = makeAppModelForBrokerWindowSnapshot()
        let profile = BrokerAgentProfile.builtIns[0]
        model.settings.broker.applyProfile(id: profile.id)
        var updated = profile
        updated.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "gpt-6-astra", effort: .low)]
        model.settings.broker.updateRemotePresets([updated])
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(BrokerRoutingUpdateBanner(appModel: model),
                     size: CGSize(width: 240, height: 220), appearance: appearance,
                     named: "banner-\(appearance.rawValue)")
            snapshot(BrokerRoutingUpdateReview(appModel: model, onApplied: {}),
                     size: CGSize(width: 480, height: 590), appearance: appearance,
                     named: "review-\(appearance.rawValue)")
        }
        model.settings.broker.policy.roles["planning"] = [BrokerCandidate(route: .auto, model: "local-model")]
        snapshot(BrokerRoutingUpdateReview(appModel: model, onApplied: {}),
                 size: CGSize(width: 480, height: 670), named: "review-local-edits")
        snapshot(BrokerWindowView(appModel: model, initialRecentPicks: [], initialPane: .instances),
                 size: CGSize(width: 1040, height: 900), precision: 0.99,
                 perceptualPrecision: 0.98, named: "settings-instances")
        model.settings.broker.applyProfile(id: profile.id)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(BrokerRoutingUpdateBanner(appModel: model),
                     size: CGSize(width: 240, height: 240), appearance: appearance,
                     named: "undo-\(appearance.rawValue)")
        }

    }

    func test_brokerWindow_routingUpdatesHasOwnPane() {
        XCTAssertTrue(
            BrokerWindowView.sidebarSections.contains { section in
                section.panes.contains(.updates)
            }
        )
        XCTAssertEqual(BrokerWindowView.Pane.updates.title, "Routing updates")
    }

    /// The window as it opens: fixed status header, pane picker, and the Routing
    /// pane (profile bar, role/chain editor, ceilings).
    func test_brokerWindow_routingPane() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 1040, height: 900),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    func test_brokerWindow_instancesPane() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .instances
            ),
            size: CGSize(width: 1040, height: 780),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    private func localRouteSnapshotRow(_ route: BrokerLocalRoute, load: BrokerLocalLoad, now: Date) async throws -> BrokerLocalRouteRow {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerPolicy.default; policy.localRoutes = [route]
        let broker = BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory), livenessChecker: LocalRoutesViewLiveness())
        await broker.setLocalLoad(load)
        let rows = await broker.localRouteRows(now: now)
        return try XCTUnwrap(rows.first)
    }

    func test_brokerInstancesPane_localRoutes_states() async throws {
        let model = makeAppModelForBrokerWindowSnapshot()
        model.settings.broker.policy.t3Instances = [T3InstanceConfig(id: "pi", name: "Local model provider")]
        // Each row is a separate synthetic engine world, so five states fit two synthetic host ids.
        let now = Date().addingTimeInterval(-8 * 3600)
        var routes: [BrokerLocalRoute] = []
        var rows: [BrokerLocalRouteRow] = []
        for (index, state) in ["idle", "busy", "unreachable", "replaces", "off"].enumerated() {
            let host = index % 2 == 0 ? "gpu-a" : "gpu-b"
            let route = BrokerLocalRoute(candidate: "t3:pi/lab/qwen-27b-\(state)", host: host,
                probeURL: "http://\(host).example:11434", preset: "qwen-27b", residency: index == 0 ? .controlled : nil,
                enabled: state != "off", roles: ["explore", "verification"])
            var presets: [String: BrokerLocalLoad.Preset] = [
                "qwen-27b": .init(status: state == "replaces" ? "sleeping" : "loaded", aliases: [], slotsTotal: 1, slotsBusy: state == "busy" ? 1 : 0)
            ]
            if state == "replaces" { presets["other"] = .init(status: "loaded", aliases: [], slotsTotal: 1, slotsBusy: 0) }
            let load = BrokerLocalLoad(hosts: [.init(host: host, state: state == "unreachable" ? "unreachable" : "ok",
                observedAt: now, presets: presets, pending: 0)])
            routes.append(route)
            rows.append(try await localRouteSnapshotRow(route, load: load, now: now))
        }
        XCTAssertEqual(rows.map(\.state), [.idle, .busy, .unreachable, .replacesIdle, .off])
        XCTAssertEqual(rows.map(\.priceLevel), [0, 3, nil, 4, nil])
        model.settings.broker.policy.localRoutes = routes
        snapshot(BrokerInstancesPane(appModel: model, initialLocalRows: rows).padding(20)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!), size: CGSize(width: 720, height: 1100))
    }

    func test_brokerInstancesPane_localRoutes_narrowest() async throws {
        let model = makeAppModelForBrokerWindowSnapshot()
        model.settings.broker.policy.t3Instances = []
        let now = Date().addingTimeInterval(-8 * 3600)
        let route = BrokerLocalRoute(candidate: "t3:local-provider/lab/qwen-27b-synthetic-route-for-width-x", host: "gpu-a",
            probeURL: "http://gpu-a.example:11434", preset: "qwen-27b", residency: .controlled,
            enabled: true, roles: ["explore", "verification"])
        let load = BrokerLocalLoad(hosts: [.init(host: "gpu-a", state: "ok", observedAt: now,
            presets: ["qwen-27b": .init(status: "sleeping", aliases: [], slotsTotal: 1, slotsBusy: 0),
                      "other": .init(status: "loaded", aliases: [], slotsTotal: 1, slotsBusy: 0)], pending: 0)])
        let row = try await localRouteSnapshotRow(route, load: load, now: now)
        model.settings.broker.policy.localRoutes = [route]
        snapshot(BrokerInstancesPane(appModel: model, initialLocalRows: [row]).frame(width: 660).padding(20)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!), size: CGSize(width: 700, height: 620))
    }

    func test_brokerPolicyEditor_controlledOnly_noRoute() {
        let model = makeAppModelForPolicyEditorSnapshot()
        model.settings.broker.policy.residencyRoles["verification"] = .controlled
        snapshot(BrokerPolicyEditorView(appModel: model, initialSelectedRole: "verification"), size: CGSize(width: 640, height: 640))
    }

    /// The unreachable state is the one the status strip exists for: the row
    /// must name the cause and offer "Probe again" and "Set health check
    /// address", and the header must list the instance with a way in.
    func test_brokerWindow_instancesPane_unreachableAndUnprobed() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.brokerUIState?.routeHealth = [
            BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: false, why: "connect failed"),
        ]
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .instances
            ),
            size: CGSize(width: 1040, height: 820),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// The pick log, including the `reason` line the pre-redesign list dropped
    /// and the degraded row's treatment.
    func test_brokerWindow_activityPane() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .activity
            ),
            size: CGSize(width: 1040, height: 640),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// The narrowest the view ever renders in production: the Broker
    /// window's minimum. Rendering the real container rather than assuming a
    /// content width means any width the window's own chrome consumes shows up
    /// here rather than only on a user's screen.
    func test_brokerWindow_atNarrowestWindowWidth() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 900, height: 900),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - Dark appearance
    //
    // The panes are rebuilt on semantic colours (`controlBackgroundColor`,
    // `.quaternary`, `.regularMaterial`) and system tints, none of which can
    // be checked by compiling. These pin that the whole window still reads in
    // dark mode.

    func test_brokerWindow_routingPane_dark() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .routing
            ),
            size: CGSize(width: 1040, height: 900),
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    func test_brokerWindow_instancesPane_dark() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .instances
            ),
            size: CGSize(width: 1040, height: 780),
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    func test_brokerWindow_activityPane_dark() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: brokerWindowSnapshotRecentPicks,
                initialPane: .activity
            ),
            size: CGSize(width: 1040, height: 640),
            appearance: .darkAqua,
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// Two model/effort groups through the `initialOutcomeTrend` seam: one
    /// fully populated, one with a 60-character slug and zero recent tasks
    /// (every "Last 7 days" cell renders the em dash). Covers both E1
    /// backstop cases (populated, long-text) in one light-mode snapshot; the
    /// CI runner is authoritative since snapshots can differ on dev Macs.
    func test_brokerWindow_outcomesPane() {
        let trend = BrokerOutcomeTrend(
            today: "2026-10-09",
            includeAllReasons: false,
            role: "review",
            roles: [BrokerOutcomeTrend.Role(role: "review", recentPicks: 34)],
            state: "populated",
            groups: [
                BrokerOutcomeTrend.Group(
                    model: "claude-opus-5-5",
                    effort: "high",
                    recentTasks: 34,
                    rows: [
                        BrokerOutcomeTrend.Row(label: "Tasks per day", recent: "4.9", baseline: "4.3",
                                               change: "+0.6", modelChanged: false, recentSamples: 34, baselineSamples: 30),
                        BrokerOutcomeTrend.Row(label: "Reported", recent: "97%", baseline: "95%",
                                               change: "+2 pts", modelChanged: false, recentSamples: 34, baselineSamples: 30),
                        BrokerOutcomeTrend.Row(label: "Failed", recent: "3%", baseline: "2%",
                                               change: "+1 pts", modelChanged: false, recentSamples: 33, baselineSamples: 29),
                        BrokerOutcomeTrend.Row(label: "Review passed", recent: "88%", baseline: "85%",
                                               change: "+3 pts", modelChanged: false, recentSamples: 20, baselineSamples: 18),
                        BrokerOutcomeTrend.Row(label: "Tokens per task", recent: "51K", baseline: "48K",
                                               change: "+3K", modelChanged: false, recentSamples: 33, baselineSamples: 29),
                        BrokerOutcomeTrend.Row(label: "Output tokens per task", recent: "12K", baseline: "11K",
                                               change: "+1K", modelChanged: false, recentSamples: 33, baselineSamples: 29),
                        BrokerOutcomeTrend.Row(label: "Duration", recent: "2m 14s", baseline: "2m 2s",
                                               change: "+12s", modelChanged: false, recentSamples: 33, baselineSamples: 29),
                        BrokerOutcomeTrend.Row(label: "Ran on a backup", recent: "6%", baseline: "4%",
                                               change: "+2 pts", modelChanged: false, recentSamples: 33, baselineSamples: 29),
                        BrokerOutcomeTrend.Row(label: "Served model", recent: "claude-opus-5-5 92%",
                                               baseline: "claude-opus-5-5 90%", change: "Same",
                                               modelChanged: false, recentSamples: 33, baselineSamples: 29),
                    ]
                ),
                BrokerOutcomeTrend.Group(
                    model: "claude-opus-5-5-internal-research-preview-build-2026-10-09-r",
                    effort: "default",
                    recentTasks: 0,
                    rows: [
                        BrokerOutcomeTrend.Row(label: "Tasks per day", recent: "\u{2014}", baseline: "1.2",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 24),
                        BrokerOutcomeTrend.Row(label: "Reported", recent: "\u{2014}", baseline: "80%",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 24),
                        BrokerOutcomeTrend.Row(label: "Failed", recent: "\u{2014}", baseline: "10%",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 20),
                        BrokerOutcomeTrend.Row(label: "Review passed", recent: "\u{2014}", baseline: "\u{2014}",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 2),
                        BrokerOutcomeTrend.Row(label: "Tokens per task", recent: "\u{2014}", baseline: "40K",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 20),
                        BrokerOutcomeTrend.Row(label: "Output tokens per task", recent: "\u{2014}", baseline: "9K",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 20),
                        BrokerOutcomeTrend.Row(label: "Duration", recent: "\u{2014}", baseline: "1m 50s",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 20),
                        BrokerOutcomeTrend.Row(label: "Ran on a backup", recent: "\u{2014}", baseline: "0%",
                                               change: "\u{2014}", modelChanged: false, recentSamples: 0, baselineSamples: 20),
                        BrokerOutcomeTrend.Row(label: "Served model", recent: "\u{2014}",
                                               baseline: "claude-opus-5-5 100%", change: "\u{2014}",
                                               modelChanged: false, recentSamples: 0, baselineSamples: 20),
                    ]
                ),
            ]
        )
        let view = BrokerOutcomeView(trend: trend, loadFailed: false)
        let appModel = makeAppModelForBrokerWindowSnapshot(outcomeTrend: view)
        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialOutcomeTrend: view,
                initialPane: .outcomes
            ),
            size: CGSize(width: 1040, height: 760),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// The profile bar carrying local edits: the "Edited" pill plus the
    /// Save/Revert pair that only exists in that state.
    func test_brokerProfileBar_editedUserProfile() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
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
        let appModel = makeAppModelForBrokerWindowSnapshot()
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
        let appModel = makeAppModelForBrokerWindowSnapshot()
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
        let appModel = makeAppModelForBrokerWindowSnapshot()
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
    private static let dispatchSnapshotConnection = T3DispatchConnection.connected(
        expiresAt: snapshotCheckedAt.addingTimeInterval(30 * 24 * 60 * 60),
        scope: "orchestration:read orchestration:operate"
    )

    private func makeInstructionDispatchCardSnapshotModel(
        projectTitle: String? = "Pinemeter"
    ) -> AppModel {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.settings.broker.instructionDispatch.t3ProjectID = projectTitle.map { _ in "project-1" }
        appModel.settings.broker.instructionDispatch.t3ProjectTitle = projectTitle
        return appModel
    }

    private func instructionDispatchCard(
        appModel: AppModel,
        connection: T3DispatchConnection,
        state: BrokerInstructionDispatchCard.InitialDispatchState
    ) -> some View {
        BrokerInstructionDispatchCard(
            appModel: appModel,
            initialConnection: connection,
            initialDispatchState: state,
            now: Self.snapshotCheckedAt
        )
        .padding(BrokerUI.panePadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func test_brokerInstructionDispatchCard_notConnectedOffersThePairingAction() {
        let appModel = makeInstructionDispatchCardSnapshotModel(projectTitle: nil)

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: .notConnected,
                state: .init()
            ),
            size: CGSize(width: 620, height: 520)
        )
    }

    func test_brokerInstructionDispatchCard_lapsedCredentialOffersReconnect() {
        let appModel = makeInstructionDispatchCardSnapshotModel(projectTitle: nil)
        let expiredAt = Self.snapshotCheckedAt.addingTimeInterval(-3600)

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: .expired(expiredAt: expiredAt),
                state: .init(failure: .credentialLapsed)
            ),
            size: CGSize(width: 620, height: 520)
        )
    }

    func test_brokerInstructionDispatchCard_expiringSoonNamesTheRenewalDate() {
        let appModel = makeInstructionDispatchCardSnapshotModel()
        let expiresAt = Self.snapshotCheckedAt.addingTimeInterval(2 * 24 * 60 * 60)

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: .connected(
                    expiresAt: expiresAt,
                    scope: "orchestration:read orchestration:operate"
                ),
                state: .init(projectListState: .available, modelSource: .projectDefault)
            ),
            size: CGSize(width: 620, height: 580)
        )
    }

    func test_brokerInstructionDispatchCard_noProjectsOffersOpenT3() {
        let appModel = makeInstructionDispatchCardSnapshotModel(projectTitle: nil)

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(projectListState: .empty)
            ),
            size: CGSize(width: 620, height: 580)
        )
    }

    func test_brokerInstructionDispatchCard_readyNamesDestinationAndModelSource() {
        let appModel = makeInstructionDispatchCardSnapshotModel()
        appModel.settings.broker.apiKeyMode = .all

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(projectListState: .available, modelSource: .broker)
            ),
            size: CGSize(width: 620, height: 620)
        )
    }

    func test_brokerInstructionDispatchCard_inFlightShowsStartingState() {
        let appModel = makeInstructionDispatchCardSnapshotModel()

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(
                    projectListState: .available,
                    isDispatching: true,
                    modelSource: nil
                )
            ),
            size: CGSize(width: 620, height: 560)
        )
    }

    func test_brokerInstructionDispatchCard_failedProjectLoadOffersRetry() {
        let appModel = makeInstructionDispatchCardSnapshotModel()

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(projectListState: .loadFailed, failure: .t3NotRunning)
            ),
            size: CGSize(width: 620, height: 580)
        )
    }

    func test_brokerInstructionDispatchCard_waitingRunStatesTheStallAfterTheThreshold() {
        let appModel = makeInstructionDispatchCardSnapshotModel()

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(
                    projectListState: .available,
                    modelSource: .projectDefault,
                    outstandingRunState: .waiting,
                    lastDispatchedAt: Self.snapshotCheckedAt.addingTimeInterval(-10 * 60),
                    lastDispatchThreadID: "thread-0189a4a7"
                )
            ),
            size: CGSize(width: 620, height: 620),
            named: "waiting"
        )

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(
                    projectListState: .available,
                    modelSource: .projectDefault,
                    outstandingRunState: .stalled,
                    lastDispatchedAt: Self.snapshotCheckedAt.addingTimeInterval(
                        -T3DispatchController.stalledRunInterval
                    ),
                    lastDispatchThreadID: "thread-0189a4a7"
                )
            ),
            size: CGSize(width: 620, height: 620),
            named: "stalled"
        )
    }

    func test_brokerInstructionDispatchCard_failedDispatchNamesTheFailureClass() {
        let appModel = makeInstructionDispatchCardSnapshotModel()

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(projectListState: .available, failure: .commandRefused)
            ),
            size: CGSize(width: 620, height: 600)
        )
    }

    func test_brokerInstructionDispatchCard_noModelExplainsHowToFixIt() {
        let appModel = makeInstructionDispatchCardSnapshotModel()

        snapshot(
            instructionDispatchCard(
                appModel: appModel,
                connection: Self.dispatchSnapshotConnection,
                state: .init(projectListState: .available, failure: .noModelResolvable)
            ),
            size: CGSize(width: 620, height: 600)
        )
    }

    /// The pane after an agent has run a check, with the issue rows it found.
    /// Rendered with the pane padding its container applies, so the image is
    /// what the Broker window draws.
    func test_brokerInstructionsPane_showsTheLastRecordedCheck() {
        let appModel = makeAppModelForBrokerWindowSnapshot()

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
            size: CGSize(width: 620, height: 940)
        )
    }

    /// A pointer file (a skill, a project `CLAUDE.md`) that names a canonical
    /// policy file instead of repeating the contract, where that canonical
    /// file was submitted in the same check and passed. The grader credits
    /// it rather than flagging every directive as missing, and the row says
    /// so instead of reading as a plain, unexplained pass.
    func test_brokerInstructionsPane_showsACreditedReference() {
        let appModel = makeAppModelForBrokerWindowSnapshot()

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
                            path: "~/.claude/skills/broker-dispatch/SKILL.md",
                            status: .credited,
                            findings: [
                                "Credited through reference to ~/.claude/universal/subagent-execution-policy.md, which passes.",
                            ]
                        ),
                        InstructionCheckSource(
                            path: "~/.claude/universal/subagent-execution-policy.md",
                            status: .pass,
                            findings: []
                        ),
                    ]
                ),
                now: Self.snapshotCheckedAt.addingTimeInterval(3600),
                currentVersion: Self.snapshotVersion
            )
            .padding(BrokerUI.panePadding),
            size: CGSize(width: 620, height: 780)
        )
    }

    /// The same card once the record has stopped counting as evidence: a
    /// clean pass, graded by this build, gone stale on the shelf. The banner
    /// is the only thing that says so, which is why it is pinned in pixels.
    func test_brokerInstructionsPane_staleCheckShowsTheRecheckBanner() {
        let appModel = makeAppModelForBrokerWindowSnapshot()

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
            size: CGSize(width: 620, height: 780)
        )
    }

    /// The pane on a machine where no agent has ever run a check, which is how
    /// most of the app's users will ever see it. `initialCheck: nil` with the
    /// record already loaded is the empty state, not the spinner.
    func test_brokerInstructionsPane_withNoCheckRecorded() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.brokerUIState?.lastPickSummary = nil
        appModel.brokerUIState?.oracleFreshness = .init(present: false, stale: true, ageSeconds: nil, accounts: [])

        snapshot(
            BrokerInstructionsPane(appModel: appModel, initialCheck: nil, hasLoadedCheck: true)
                .padding(BrokerUI.panePadding),
            size: CGSize(width: 620, height: 740)
        )
    }

    /// The Settings > Broker tab hands a pane and an instance id to the Broker
    /// window two ways: a notification for a window that is already open, and
    /// defaults for one about to be created. Both must agree on the keys, and
    /// the defaults handoff must be consumed exactly once.
    func test_brokerWindow_paneHandoffKeysAndOneShotInstanceDefault() {
        let info = BrokerWindowView.showPaneUserInfo(pane: .instances, instanceId: "claudeAgent")
        XCTAssertEqual(info[BrokerWindowView.paneUserInfoKey], "instances")
        XCTAssertEqual(info[BrokerWindowView.instanceUserInfoKey], "claudeAgent")
        XCTAssertNil(BrokerWindowView.showPaneUserInfo(pane: .activity, instanceId: nil)[BrokerWindowView.instanceUserInfoKey])

        let defaults = TestSafeDefaults.standardOrIsolated
        defaults.set("claudeAgent", forKey: BrokerWindowView.pendingInstanceDefaultsKey)
        _ = BrokerWindowView(appModel: makeAppModelForBrokerWindowSnapshot(), initialPane: .instances)
        XCTAssertNil(
            defaults.string(forKey: BrokerWindowView.pendingInstanceDefaultsKey),
            "The pending instance id is a one-shot handoff and must be cleared by init"
        )
    }

    /// The whole window with the broker turned off: the header drops the endpoint
    /// and health rows, and the toggle is the only thing left to act on. This
    /// is the state the app ships in until someone opts into the broker.
    func test_brokerWindow_brokerDisabled() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.settings.broker.isEnabled = false

        snapshot(
            BrokerWindowView(
                appModel: appModel,
                initialRecentPicks: [],
                initialPane: .instructions
            ),
            size: CGSize(width: 900, height: 640),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// The Settings window's Broker tab: status, profile, last pick, and the
    /// one button into the Broker window. Rendered at the Settings window's
    /// 540pt minimum, where the last-pick line is most likely to crowd its
    /// label.
    func test_brokerSummaryTab_runningAtMinimumWidth() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            snapshot(
                BrokerSummaryTab(appModel: appModel),
                size: CGSize(width: 640, height: 420),
                appearance: appearance,
                precision: 0.99,
                perceptualPrecision: 0.98,
                named: appearance.rawValue
            )
        }
    }

    /// Both conditional notices at once: a published routing update for the
    /// active profile and a degraded last pick. These are the rows most likely
    /// to wrap at the minimum width.
    func test_brokerSummaryTab_routingUpdateAndDegradedPick() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        let profile = BrokerAgentProfile.builtIns[0]
        appModel.settings.broker.applyProfile(id: profile.id)
        var updated = profile
        updated.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "gpt-6-astra", effort: .low)]
        appModel.settings.broker.updateRemotePresets([updated])
        appModel.brokerUIState?.lastPickDegraded = true
        snapshot(
            BrokerSummaryTab(appModel: appModel),
            size: CGSize(width: 640, height: 420),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// An unreachable instance and stale usage data each get their own row
    /// with the action that resolves them, instead of one generic notice.
    func test_brokerSummaryTab_unreachableInstanceAndStaleUsage() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.brokerUIState?.routeHealth = [
            BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: false, why: "connect failed"),
        ]
        appModel.brokerUIState?.oracleFreshness = BrokerStatus.OracleFreshness(
            present: true, stale: true, ageSeconds: 5400, accounts: []
        )
        snapshot(
            BrokerSummaryTab(appModel: appModel),
            size: CGSize(width: 640, height: 420),
            precision: 0.99,
            perceptualPrecision: 0.98
        )
    }

    /// With the broker off the summary keeps the button, since the Broker
    /// window is now the only place the broker can be turned on.
    func test_brokerSummaryTab_brokerDisabled() {
        let appModel = makeAppModelForBrokerWindowSnapshot()
        appModel.settings.broker.isEnabled = false
        snapshot(
            BrokerSummaryTab(appModel: appModel),
            size: CGSize(width: 640, height: 420),
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

        let setup = try XCTUnwrap(BrokerInstructionsPane.recheckMessage(for: .setupContractChanged))
        XCTAssertTrue(setup.contains("Agent setup instructions changed"))
        XCTAssertTrue(setup.hasSuffix(rerun))

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

    // MARK: - BrokerWindowView.addableDiscoveredInstances (260814-pz4, RESEARCH Q-2)

    /// A `Menu`'s contents are not visible to a snapshot, so this pure filter
    /// is covered directly, mirroring `setupPrompt(port:)`'s test pattern.
    func test_brokerWindow_addableDiscoveredInstances_offersOnlyInstalledUnaddedInstances() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "WS", installed: true),
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", displayName: "Codex", installed: true),
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", displayName: "Cursor", installed: true),
            DiscoveredT3Instance(instanceId: "grok", driver: "grok", displayName: "Grok", installed: false),
            DiscoveredT3Instance(instanceId: "opencode", driver: "opencode", displayName: "OpenCode", installed: false),
            DiscoveredT3Instance(instanceId: "future", driver: "future", displayName: "Future", installed: false),
        ]

        let addable = BrokerWindowView.addableDiscoveredInstances(discovered: discovered, existing: [])

        XCTAssertEqual(Set(addable.map(\.instanceId)), Set(["claudeAgent", "codex", "cursor"]))
    }

    func test_brokerWindow_addableDiscoveredInstances_excludesInstancesWithExistingRows() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", installed: true),
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true),
        ]
        let existing = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]

        let addable = BrokerWindowView.addableDiscoveredInstances(discovered: discovered, existing: existing)

        XCTAssertEqual(addable.map(\.instanceId), ["codex"])
    }

    func test_brokerWindow_addableDiscoveredInstances_allExistingRows_offersOnlyManualChoice() {
        let discovered: [DiscoveredT3Instance] = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", installed: true),
        ]
        let existing = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]

        let addable = BrokerWindowView.addableDiscoveredInstances(discovered: discovered, existing: existing)

        XCTAssertTrue(addable.isEmpty)
    }

    func test_brokerSetupPrompt_usesConfiguredEndpointAndBothHarnesses() {
        let prompt = BrokerWindowView.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("http://127.0.0.1:54321/mcp"))
        XCTAssertTrue(prompt.contains("pinemeter-broker"))
        XCTAssertTrue(prompt.contains("Claude Code"))
        XCTAssertTrue(prompt.contains("Codex"))
    }

    func test_brokerSetupPrompt_requiresCallerEchoAndKnownRoutePairs() {
        let prompt = BrokerWindowView.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("active harness: `claude-code` for Claude Code or `codex` for Codex"))
        XCTAssertTrue(prompt.contains("non-empty `role`, `caller`, `route`, `model`, and `invocation`"))
        XCTAssertTrue(prompt.contains("exactly matches the caller sent"))
        XCTAssertTrue(prompt.contains("`native` with `agent`"))
        XCTAssertTrue(prompt.contains("`t3` with `t3-dispatch`"))
        XCTAssertTrue(prompt.contains("`codex` with `agent` when caller is `codex`"))
        XCTAssertTrue(prompt.contains("`codex-exec` for every other caller"))
        XCTAssertTrue(prompt.contains("Choose `role` from the names the broker's `status` tool lists"))
        XCTAssertTrue(prompt.contains("`explore` for read-only codebase scanning"))
        XCTAssertTrue(prompt.contains("`verification` for test runs and plan checks"))
    }

    func test_brokerSetupPrompt_failsClosedAndRequiresApprovalBeforeWrites() {
        let prompt = BrokerWindowView.setupPrompt(port: 54321)

        XCTAssertTrue(prompt.contains("Stop without dispatching"))
        XCTAssertTrue(prompt.contains("launch or update Pinemeter and confirm the registered endpoint"))
        XCTAssertTrue(prompt.contains("Never add a second broker client, policy layer, endpoint, fallback, secret, or external routing machinery"))
        XCTAssertTrue(prompt.contains("Show the exact proposed commands and user-file edits"))
        XCTAssertTrue(prompt.contains("Wait for explicit approval before changing user files"))
    }

    func test_brokerSetupPrompt_requiresNestedSelectionAndFinalPrecedenceAudit() {
        let prompt = BrokerWindowView.setupPrompt(port: 54321)

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
    /// production ever renders, which is the Broker window's 620pt minimum
    /// less `BrokerWindowView`'s 20pt pane padding on each side.
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
            models: ["manifest-only": BrokerModelSpec()],
            agentModelAliases: [
                "alias-only": "alias",
                "shared": "shared",
            ]
        )

        XCTAssertEqual(
            BrokerPolicyEditorView.knownModelIDs(in: policy),
            ["candidate-only", "shared", "zeta", "alias-only", "manifest-only"]
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

    // MARK: - BrokerQualityOrderSection (Task 3)

    /// A 40-character model id (UI-SPEC narrowest-width backstop): proves
    /// the Route/model columns truncate in the middle rather than clipping.
    private static let qualityOrderLongModelSlug = "research-preview-extra-long-model-id-40c"

    /// The one true "review" chain this seed and its app model must BOTH
    /// use, in the same order: `claude-sonnet-5-5` first (matching the
    /// seed's `neutralPosition: 1`, chain rank 1), the long slug second
    /// (`neutralPosition: 2`), `gpt-6-luna` last (`neutralPosition: 3`).
    /// Before this fix the app model listed the long slug FIRST while the
    /// seed's `neutralPosition`s (and therefore the rendered chain-rank
    /// badge) put `claude-sonnet-5-5` first — two different orders for what
    /// is supposed to be the same chain. `BrokerRoleScoreSnapshot.chainModels`
    /// now compares ORDERED lists, so that mismatch would read as a stale
    /// chain forever; a single shared array makes the two call sites
    /// impossible to disagree.
    private static func qualityOrderChain() -> [BrokerCandidate] {
        [
            BrokerCandidate(route: .native, model: "claude-sonnet-5-5"),
            BrokerCandidate(route: .codex, model: qualityOrderLongModelSlug, effort: .medium),
            BrokerCandidate(route: .codex, model: "gpt-6-luna", effort: .low),
        ]
    }

    /// One capped base row (`really-long` model), one Raise row (its own
    /// "high" effort), and one "Below floor" order row (`gpt-6-luna`), with
    /// pricing active and exactly one route moved ahead of its neutral slot
    /// — the exact seed the UI-SPEC's two new-snapshot backstops name.
    private func makeQualityOrderSeedSnapshot(
        derived: Bool, health: BrokerRoleHealthSnapshot? = nil
    ) -> BrokerRoleScoreSnapshot {
        let longSlug = Self.qualityOrderLongModelSlug
        var scoringPolicy = BrokerFixture.policy(roles: [:])
        // `chainModels` (and therefore the stale guard) now reads the
        // policy's own chain, not the scored rows — this seed's `policy`
        // must carry the exact same "review" chain the app model below
        // shows, or the section would read as permanently stale.
        scoringPolicy.roles["review"] = Self.qualityOrderChain()
        scoringPolicy.scoring.roles["review"] = BrokerRoleScoring(
            floor: 480, latencyLimit: 34,
            quality: [
                "claude-sonnet-5-5": ["_default": 510],
                longSlug: ["medium": 560, "high": 580],
                "gpt-6-luna": ["low": 440],
            ]
        )
        scoringPolicy.scoring.latency = [
            "claude-sonnet-5-5": ["_default": 20],
            longSlug: ["medium": 18, "high": 40],
            "gpt-6-luna": ["low": 12],
        ]
        let scored = BrokerScoredRole(
            role: "review", derived: derived, floor: derived ? nil : 480, latencyLimit: derived ? nil : 34,
            pricing: "active",
            rows: [
                .init(candidate: "codex/\(longSlug)", model: longSlug, effort: "medium",
                      quality: 560, effective: 510, latency: 18, level: 1, eligible: true, reason: nil,
                      score: 510, position: 1, neutralPosition: 2, raise: nil),
                .init(candidate: "native/claude-sonnet-5-5", model: "claude-sonnet-5-5", effort: nil,
                      quality: 510, effective: 510, latency: 20, level: 2, eligible: true, reason: nil,
                      score: 490, position: 2, neutralPosition: 1, raise: nil),
                .init(candidate: "codex/gpt-6-luna", model: "gpt-6-luna", effort: "low",
                      quality: 440, effective: 440, latency: 12, level: 3, eligible: false, reason: "belowFloor",
                      score: 440, position: 3, neutralPosition: 3, raise: nil),
            ]
        )
        return BrokerRoleScoreSnapshot(scored: scored, policy: scoringPolicy, health: health ?? Self.healthCurrentNoDemotions)
    }

    // MARK: - Model health seeds (29-06)

    private static let healthNow = BrokerHealthDocument.parseTime("2026-10-13T12:00:00Z")!

    private static func healthDay(_ text: String) -> Date? {
        BrokerHealthDocument.parseTime(text + "T00:00:00Z")
    }

    /// A current document that demotes nothing for this role, with the three
    /// sources the UI-SPEC names for the changed references: Fresh, Off, Stale.
    private static var healthCurrentNoDemotions: BrokerRoleHealthSnapshot {
        BrokerRoleHealthSnapshot(
            state: .current, useModelHealth: true, generatedAt: healthNow,
            issuedAt: healthNow.addingTimeInterval(-3 * 3600), validUntil: healthNow.addingTimeInterval(24 * 3600),
            demotions: [], skipped: false,
            sources: [
                .init(id: "marginlab-claude-code", state: "fresh", newestDataDate: healthDay("2026-10-12"), staleLimitDays: 3),
                .init(id: "aa", state: "disabled", newestDataDate: nil, staleLimitDays: 7),
                .init(id: "marginlab-codex", state: "stale", newestDataDate: healthDay("2026-09-29"), staleLimitDays: 3),
            ],
            attribution: []
        )
    }

    /// One demotion with two methods and five sources covering every state chip.
    private static func healthDemoting(_ model: String) -> BrokerRoleHealthSnapshot {
        BrokerRoleHealthSnapshot(
            state: .current, useModelHealth: true, generatedAt: healthNow,
            issuedAt: healthNow.addingTimeInterval(-3 * 3600), validUntil: healthNow.addingTimeInterval(24 * 3600),
            demotions: [.init(
                model: model, expiresAt: BrokerHealthDocument.parseTime("2026-10-16T06:00:00Z")!,
                methods: ["marginlab-cusum", "status-incident"]
            )],
            skipped: false,
            sources: [
                .init(id: "marginlab-claude-code", state: "fresh", newestDataDate: healthDay("2026-10-12"), staleLimitDays: 3),
                .init(id: "marginlab-codex", state: "stale", newestDataDate: healthDay("2026-09-29"), staleLimitDays: 3),
                .init(id: "status-claude", state: "broken", newestDataDate: nil, staleLimitDays: 1),
                .init(id: "status-openai", state: "paused", newestDataDate: healthDay("2026-10-12"), staleLimitDays: 1),
                .init(id: "aa", state: "disabled", newestDataDate: nil, staleLimitDays: 7),
            ],
            attribution: ["Model health data comes from the listed sources under their published terms."]
        )
    }

    /// The seed after the demotion partition moved `model`'s route to the end,
    /// the same reshaping `BrokerService.scoreSnapshot` performs.
    private func makeModelHealthDemotedSeed(demoting model: String, candidate: String) -> BrokerRoleScoreSnapshot {
        var seed = makeQualityOrderSeedSnapshot(derived: false, health: Self.healthDemoting(model))
        let order = seed.orderRows.map(\.candidate).filter { $0 != candidate } + [candidate]
        seed.applyDemotionPartition(order: order, demotedIds: [candidate])
        return seed
    }

    /// `appModel` whose "review" chain names exactly the seed's three
    /// models, so the section's stale guard (`isStale`) never fires and the
    /// grid renders instead of "Updating order…".
    private func makeAppModelForQualityOrderSnapshot(seed: BrokerRoleScoreSnapshot? = nil) -> AppModel {
        let appModel = seed.map { seed in
            AppModel(
                settingsRepository: SettingsRepositoryFake(),
                keychainRepository: KeychainRepositoryFake(),
                usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
                notificationService: NotificationServiceSpy(),
                brokerService: SnapshotFakeBrokerService(recentPicks: [], scoreSnapshot: seed)
            )
        } ?? makeAppModelForPolicyEditorSnapshot()
        // AppSettings.default ships broker.isEnabled == false; the section's
        // "broker off" empty state otherwise hides the populated grid this
        // seed exists to show (BrokerPolicyEditorView.swift:294).
        appModel.settings.broker.isEnabled = true
        appModel.settings.broker.policy.roles["review"] = Self.qualityOrderChain()
        return appModel
    }

    func test_brokerPolicyEditor_qualityAndOrder_populated() {
        let appModel = makeAppModelForQualityOrderSnapshot()
        snapshot(
            BrokerPolicyEditorView(
                appModel: appModel, initialSelectedRole: "review",
                initialQualityExpanded: true, initialScoreSnapshot: makeQualityOrderSeedSnapshot(derived: false)
            ),
            size: CGSize(width: 640, height: 900)
        )
    }

    /// Editor narrowest production width (UI-SPEC "E2/E3 narrowest width"
    /// backstop): both grids must fit without clipping or horizontal scroll.
    func test_brokerPolicyEditor_qualityAndOrder_narrowest() {
        let appModel = makeAppModelForQualityOrderSnapshot()
        snapshot(
            BrokerPolicyEditorView(
                appModel: appModel, initialSelectedRole: "review",
                initialQualityExpanded: true, initialScoreSnapshot: makeQualityOrderSeedSnapshot(derived: false)
            ),
            size: CGSize(width: 580, height: 900)
        )
    }

    /// Derived table (UI-SPEC "Derived" state): the quality grid is hidden
    /// behind the "Derived from chain order" chip and note; no synthetic
    /// tier number is ever rendered.
    func test_brokerPolicyEditor_qualityAndOrder_derived() {
        let appModel = makeAppModelForQualityOrderSnapshot()
        snapshot(
            BrokerPolicyEditorView(
                appModel: appModel, initialSelectedRole: "review",
                initialQualityExpanded: true, initialScoreSnapshot: makeQualityOrderSeedSnapshot(derived: true)
            ),
            // 760 pt: the Phase 29 Model health block pushed the content past 700.
            size: CGSize(width: 640, height: 760)
        )
    }

    /// Pins the formatting inputs the references depend on: UTC and a POSIX
    /// locale, so "Oct 16, 6:00 AM" reads the same on any Mac.
    private func pinnedForModelHealth<V: View>(_ view: V) -> some View {
        view
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }

    /// UI-SPEC "Snapshot impact": one demoted route with the chip at the end of
    /// the order, one demotion row with two methods, five sources covering
    /// Fresh, Stale, Broken, Paused and Off, and one attribution line.
    func test_brokerPolicyEditor_qualityAndOrder_modelHealthDemoted() {
        let seed = makeModelHealthDemotedSeed(demoting: "claude-sonnet-5-5", candidate: "native/claude-sonnet-5-5")
        let appModel = makeAppModelForQualityOrderSnapshot(seed: seed)
        snapshot(
            pinnedForModelHealth(BrokerPolicyEditorView(
                appModel: appModel, initialSelectedRole: "review",
                initialQualityExpanded: true, initialScoreSnapshot: seed
            )),
            size: CGSize(width: 640, height: 1000)
        )
    }

    /// Editor narrowest production width with the 40-character slug as the
    /// demoted model: the order row, the Demotions grid and the Sources grid
    /// must fit without clipping or horizontal scroll.
    func test_brokerPolicyEditor_qualityAndOrder_modelHealthNarrowest() {
        let slug = Self.qualityOrderLongModelSlug
        let seed = makeModelHealthDemotedSeed(demoting: slug, candidate: "codex/\(slug)")
        let appModel = makeAppModelForQualityOrderSnapshot(seed: seed)
        snapshot(
            pinnedForModelHealth(BrokerPolicyEditorView(
                appModel: appModel, initialSelectedRole: "review",
                initialQualityExpanded: true, initialScoreSnapshot: seed
            )),
            size: CGSize(width: 580, height: 1000)
        )
    }

    /// The opt-out row between "Spend expiring quota first" and "Usage data
    /// goes stale after", default thresholds (toggle on), light.
    func test_brokerThresholdsCard_modelHealthRow() {
        let appModel = makeAppModelForPolicyEditorSnapshot()
        snapshot(BrokerThresholdsCard(appModel: appModel), size: CGSize(width: 560, height: 560))
    }

    /// Non-pixel check: the three routing-review fixtures change no threshold
    /// but their own, so none lists the new "Avoid reported quality drops"
    /// line and their recorded references stay valid.
    func test_routingReviewFixtures_listNoModelHealthLine() {
        var unsavedNew = BrokerRuleSet.default
        unsavedNew.thresholds.weeklyPct = 80
        var unroutableNew = BrokerRuleSet.default
        unroutableNew.roles["planning"] = [
            BrokerCandidate(route: .t3, instance: "missing", model: "unavailable-model"),
        ]
        let profile = BrokerAgentProfile.builtIns[0]
        var updated = profile
        updated.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "gpt-6-astra", effort: .low)]

        let settings = BrokerSettings(isEnabled: true, port: 43117, policy: .bundledDefault)
        let fixtures: [(BrokerRuleSet, BrokerRuleSet)] = [
            (.default, unsavedNew), (.default, unroutableNew), (profile.rules, updated.rules),
        ]
        for (old, new) in fixtures {
            XCTAssertEqual(old.thresholds.useModelHealth, new.thresholds.useModelHealth)
            for case .thresholds(let list) in settings.routingChanges(from: old, to: new) {
                XCTAssertFalse(list.contains { $0.field == .useModelHealth })
            }
        }
    }

    /// Non-pixel check (Task 3 action 2): proves the four routing-review
    /// snapshot fixtures this phase does not touch still compute the same
    /// `.qualityTables`/`.qualityGroups` absence 27-05 left them with, so
    /// none of their recorded references need to change here.
    /// `test_brokerCard_routingUpdateAvailable` renders a static
    /// `hasRoutingUpdate` flag directly and never calls `routingChanges` at
    /// all, so it is unaffected by construction and is not repeated below.
    func test_routingReviewFixtures_gainNoQualityTablesOrGroupsChangeFromThisPhase() {
        // test_revisionReview_unsavedEdits
        var unsavedNew = BrokerRuleSet.default
        unsavedNew.thresholds.weeklyPct = 80
        assertNoScoringOrGroupsChange(from: .default, to: unsavedNew)

        // test_revisionReview_unroutableBlocked
        var unroutableNew = BrokerRuleSet.default
        unroutableNew.roles["planning"] = [
            BrokerCandidate(route: .t3, instance: "missing", model: "unavailable-model"),
        ]
        assertNoScoringOrGroupsChange(from: .default, to: unroutableNew)

        // test_routingUpdate_narrowBannerAndReview
        let profile = BrokerAgentProfile.builtIns[0]
        var updated = profile
        updated.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "gpt-6-astra", effort: .low)]
        assertNoScoringOrGroupsChange(from: profile.rules, to: updated.rules)
    }

    private func assertNoScoringOrGroupsChange(
        from old: BrokerRuleSet, to new: BrokerRuleSet, file: StaticString = #filePath, line: UInt = #line
    ) {
        let settings = BrokerSettings(isEnabled: true, port: 43117, policy: .bundledDefault)
        let changes = settings.routingChanges(from: old, to: new)
        XCTAssertFalse(
            changes.contains(.qualityTables),
            "this fixture must not gain a scoring diff from this phase", file: file, line: line
        )
        XCTAssertFalse(
            changes.contains(.qualityGroups),
            "this fixture must not gain an equal-quality diff from this phase", file: file, line: line
        )
    }
}

/// Minimal `BrokerLifecycleProtocol` fake for rendering `BrokerWindowView`
/// with a canned recent-picks ring buffer — no real actor state, no IO.
private actor SnapshotFakeBrokerService: BrokerLifecycleProtocol {
    private let seededRecentPicks: [RecentPick]
    private let seededOutcomeTrend: BrokerOutcomeView?
    private let seededScoreSnapshot: BrokerRoleScoreSnapshot?
    private var uiState = BrokerUIState.initial

    init(
        recentPicks: [RecentPick],
        outcomeTrend: BrokerOutcomeView? = nil,
        scoreSnapshot: BrokerRoleScoreSnapshot? = nil
    ) {
        self.seededRecentPicks = recentPicks
        self.seededOutcomeTrend = outcomeTrend
        self.seededScoreSnapshot = scoreSnapshot
    }

    func pick(role: String, caller: String?, residency: BrokerResidency?) async throws -> BrokerDecision {
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

    /// Matches whatever was handed to `BrokerWindowView`'s `initialOutcomeTrend`
    /// seam, so this fake's own `.task`-triggered reload (which races the
    /// off-screen snapshot capture, see the window's own seam comment) can
    /// never render something different from the seeded state.
    func outcomeTrend(role: String?, includeAllReasons: Bool) async -> BrokerOutcomeView {
        seededOutcomeTrend ?? BrokerOutcomeView(
            trend: BrokerOutcomeTrend(
                today: BrokerOutcomeStore.day(Date()), includeAllReasons: includeAllReasons,
                role: nil, roles: [], state: "no-data", groups: []
            ),
            loadFailed: false
        )
    }

    /// Matches the editor's own `initialScoreSnapshot` seam (25-06 lesson,
    /// same race): the section's `.task(id:)` reload must never race ahead
    /// of the off-screen snapshot capture with something other than the
    /// seeded state.
    func scoreSnapshot(role: String) async -> BrokerRoleScoreSnapshot? {
        seededScoreSnapshot
    }
}
