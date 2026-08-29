//
//  BrokerRoutingEditorTests.swift
//  PinemeterTests
//
//  The Broker tab's non-pixel behaviour: chain re-ranking (the edit that
//  actually changes routing order), the reorder drag payload's rejection
//  rules, the activity filter, and the small formatters the header and
//  thresholds card render through.
//

import XCTest
@testable import Pinemeter

final class BrokerRoutingEditorTests: XCTestCase {
    @MainActor
    private func makeEditor(
        role: String,
        chain: [BrokerCandidate]
    ) -> (AppModel, BrokerPolicyEditorView) {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            brokerService: nil
        )
        appModel.settings.broker.policy.roles[role] = chain
        return (appModel, BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: role))
    }

    private let threeCandidateChain = [
        BrokerCandidate(route: .native, model: "claude-fable-5"),
        BrokerCandidate(route: .t3, instance: "claude_secondary", model: "claude-fable-5"),
        BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high),
    ]

    // MARK: - Re-ranking

    @MainActor
    func test_moveCandidate_promotesARowAndKeepsEveryCandidateIntact() {
        let (appModel, view) = makeEditor(role: "review", chain: threeCandidateChain)

        view.moveCandidate(role: "review", from: 2, to: 0)

        let chain = appModel.settings.broker.policy.roles["review"]
        XCTAssertEqual(chain?.map(\.id), [
            "native/claude-haiku-4-5-20251001",
            "native/claude-fable-5",
            "t3:claude_secondary/claude-fable-5",
        ])
        // A reorder edits no candidate, so it must not rewrite one — even the
        // stale (haiku, effort) pair survives until a real edit or dispatch
        // (T-pzh-01).
        XCTAssertEqual(chain?[0].effort, .high)
    }

    @MainActor
    func test_moveCandidate_outOfRangeOrNoOpDestinations_changeNothing() {
        let (appModel, view) = makeEditor(role: "review", chain: threeCandidateChain)
        let before = appModel.settings.broker.policy.roles["review"]

        view.moveCandidate(role: "review", from: 0, to: 0)
        view.moveCandidate(role: "review", from: 0, to: -1)
        view.moveCandidate(role: "review", from: 0, to: 3)
        view.moveCandidate(role: "review", from: 7, to: 0)
        view.moveCandidate(role: "missing-role", from: 0, to: 1)

        XCTAssertEqual(appModel.settings.broker.policy.roles["review"], before)
    }

    @MainActor
    func test_duplicateCandidate_insertsTheCopyDirectlyBelowItsSource() {
        let (appModel, view) = makeEditor(role: "review", chain: threeCandidateChain)

        view.duplicateCandidate(role: "review", index: 1)

        let chain = appModel.settings.broker.policy.roles["review"]
        XCTAssertEqual(chain?.count, 4)
        XCTAssertEqual(chain?[1], chain?[2])
        XCTAssertEqual(chain?[3].model, "claude-haiku-4-5-20251001")
    }

    @MainActor
    func test_duplicateCandidate_outOfRange_changesNothing() {
        let (appModel, view) = makeEditor(role: "review", chain: threeCandidateChain)

        view.duplicateCandidate(role: "review", index: 9)

        XCTAssertEqual(appModel.settings.broker.policy.roles["review"]?.count, 3)
    }

    // MARK: - Reorder drag payload

    func test_dragPayload_roundTripsWithinTheSameRole() {
        let payload = BrokerPolicyEditorView.dragPayload(role: "review", index: 2)
        XCTAssertEqual(BrokerPolicyEditorView.dragSourceIndex(payload, role: "review"), 2)
    }

    func test_dragPayload_isRejectedForAnotherRoleOrForForeignText() {
        let payload = BrokerPolicyEditorView.dragPayload(role: "review", index: 2)

        // Another role's row: accepting this would reorder the wrong chain.
        XCTAssertNil(BrokerPolicyEditorView.dragSourceIndex(payload, role: "execution"))
        // Text dragged in from any other app lands on the same destination.
        XCTAssertNil(BrokerPolicyEditorView.dragSourceIndex("hello", role: "review"))
        XCTAssertNil(BrokerPolicyEditorView.dragSourceIndex(nil, role: "review"))
        XCTAssertNil(
            BrokerPolicyEditorView.dragSourceIndex("pinemeter-broker-candidate\u{1F}review\u{1F}x", role: "review")
        )
    }

    // MARK: - Activity filter

    private let picks: [RecentPick] = [
        RecentPick(
            timestamp: Date(timeIntervalSince1970: 3),
            role: "execution", caller: "claude-code", candidate: "t3/gpt-5.6-sol",
            route: "t3", degraded: false, reason: "top of chain"
        ),
        RecentPick(
            timestamp: Date(timeIntervalSince1970: 2),
            role: "planning", caller: "codex", candidate: "native/claude-sonnet-5",
            route: "native", degraded: true, reason: "forced degraded, nothing had headroom"
        ),
        RecentPick(
            timestamp: Date(timeIntervalSince1970: 1),
            role: "review", caller: "claude-code", candidate: "native/claude-fable-5",
            route: "native", degraded: false, reason: "top of chain"
        ),
    ]

    func test_activityFilter_emptyQuery_keepsEveryPickInOrder() {
        let result = BrokerActivityPane.filter(picks, query: "  ", degradedOnly: false)
        XCTAssertEqual(result.map(\.role), ["execution", "planning", "review"])
    }

    func test_activityFilter_matchesRoleModelRouteCallerAndReasonCaseInsensitively() {
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "REVIEW", degradedOnly: false).count, 1)
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "sonnet", degradedOnly: false).count, 1)
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "native", degradedOnly: false).count, 2)
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "codex", degradedOnly: false).count, 1)
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "headroom", degradedOnly: false).count, 1)
        XCTAssertTrue(BrokerActivityPane.filter(picks, query: "nothing-matches", degradedOnly: false).isEmpty)
    }

    func test_activityFilter_degradedOnly_combinesWithTheQuery() {
        XCTAssertEqual(BrokerActivityPane.filter(picks, query: "", degradedOnly: true).map(\.role), ["planning"])
        XCTAssertTrue(BrokerActivityPane.filter(picks, query: "review", degradedOnly: true).isEmpty)
    }

    // MARK: - Instance validation (moved out of the tab with the rows)

    func test_validateInstanceId_rejectsCandidateIdSeparatorsAndDuplicates() {
        let own = UUID()
        let other = T3InstanceConfig(id: "codex", name: "Codex")

        XCTAssertNil(BrokerInstancesPane.validateInstanceId("claude_secondary", existing: [other], ownRowKey: own))
        XCTAssertNotNil(BrokerInstancesPane.validateInstanceId("has/slash", existing: [], ownRowKey: own))
        XCTAssertNotNil(BrokerInstancesPane.validateInstanceId("has:colon", existing: [], ownRowKey: own))
        XCTAssertNotNil(BrokerInstancesPane.validateInstanceId("", existing: [], ownRowKey: own))
        XCTAssertNotNil(BrokerInstancesPane.validateInstanceId("codex", existing: [other], ownRowKey: own))
        // The row's own current id is not a duplicate of itself.
        XCTAssertNil(
            BrokerInstancesPane.validateInstanceId("codex", existing: [other], ownRowKey: other.rowKey)
        )
    }

    func test_nonLoopbackBaseURLCaption_warnsOnlyForOriginsTheProbeWillSkip() {
        XCTAssertNil(BrokerInstancesPane.nonLoopbackBaseURLCaption(for: nil))
        XCTAssertNil(BrokerInstancesPane.nonLoopbackBaseURLCaption(for: ""))
        XCTAssertNil(BrokerInstancesPane.nonLoopbackBaseURLCaption(for: "http://127.0.0.1:9100"))
        XCTAssertNotNil(BrokerInstancesPane.nonLoopbackBaseURLCaption(for: "https://example.com"))
    }

    // MARK: - Formatters

    func test_stalenessLabel_readsInTheUnitTheValueIsRoundIn() {
        XCTAssertEqual(BrokerThresholdsCard.stalenessLabel(45), "45 sec")
        XCTAssertEqual(BrokerThresholdsCard.stalenessLabel(300), "5 min")
        XCTAssertEqual(BrokerThresholdsCard.stalenessLabel(1200), "20 min")
        XCTAssertEqual(BrokerThresholdsCard.stalenessLabel(3600), "1 hour")
        XCTAssertEqual(BrokerThresholdsCard.stalenessLabel(7200), "2 hours")
    }

    func test_ageText_collapsesToTheLargestWholeUnit() {
        XCTAssertEqual(BrokerStatusHeader.ageText(12), "12s")
        XCTAssertEqual(BrokerStatusHeader.ageText(59.6), "1m")
        XCTAssertEqual(BrokerStatusHeader.ageText(600), "10m")
        XCTAssertEqual(BrokerStatusHeader.ageText(4000), "1h")
    }
}
