//
//  BrokerRoleScoreViewModelTests.swift
//  PinemeterTests
//
//  Non-pixel coverage for the "Quality and order" section (SCORE-04, SC5):
//  `BrokerRoleScoreSnapshot`'s construction from `BrokerScoredRole`, every
//  `BrokerQualityOrderPresentation` formatter/chip/summary/accessibility
//  helper, and `BrokerQualityOrderModel`'s load state machine. The pixel
//  suite (`BrokerViewSnapshotTests`) does not run on the private Woodpecker
//  lane (docs/ci.md), so every behavioral claim here must be provable
//  without rendering a view.
//

import XCTest
@testable import Pinemeter

final class BrokerRoleScoreViewModelTests: XCTestCase {
    private let now = BrokerFixture.now

    // MARK: - BrokerRoleScoreSnapshot construction

    func test_snapshot_buildsQualityTableWithBaseAndRaiseRowsInFixedOrder() throws {
        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertFalse(snapshot.isDerived)
        XCTAssertEqual(snapshot.chainModels, ["gpt-6-astra"])
        XCTAssertEqual(snapshot.latencyLimit, 96)

        let table = try XCTUnwrap(snapshot.modelTables.first)
        XCTAssertEqual(table.model, "gpt-6-astra")
        XCTAssertEqual(table.chainRank, 1)
        XCTAssertTrue(table.hasBaseEstimate)
        XCTAssertEqual(table.rows.map(\.effortKey), ["medium", "high", "xhigh"])
        XCTAssertEqual(table.rows.map(\.isBase), [true, false, false])

        XCTAssertEqual(table.rows[0].quality, 496)
        XCTAssertEqual(table.rows[0].effective, 496)
        XCTAssertEqual(table.rows[0].latency, 15)

        XCTAssertEqual(table.rows[1].quality, 509)
        XCTAssertNil(table.rows[1].effective, "raise rows never show an effective value")
        XCTAssertEqual(table.rows[1].latency, 36)

        XCTAssertEqual(table.rows[2].quality, 524)
        XCTAssertEqual(table.rows[2].latency, 96)
    }

    /// Nit (review fix): the "Base" row must be the model's first occurrence
    /// in the POLICY chain (what the engine's `baseKeys` treats as base),
    /// not whichever row `rankingEquivalentCandidatesByHeadroom` ranked
    /// first. The chain here lists the SAME model at two different efforts
    /// on two different routes — `low` effort on `native` first, `high`
    /// effort on a `t3` instance second — and the `t3` account is given far
    /// more headroom than the primary account so headroom ranking puts the
    /// `high` row first. The chain order must still win: `low` is "Base".
    func test_snapshot_baseRowUsesThePolicyChainsFirstOccurrenceNotTheHeadroomWinner() throws {
        var policy = BrokerFixture.policy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(
                    id: "secondary", name: "Secondary", boundAccountId: "acct-secondary",
                    detectedModels: ["claude-opus-5-5"]
                ),
            ]
        )
        policy.roles["review"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5-5", effort: .low),
            BrokerCandidate(route: .t3, instance: "secondary", model: "claude-opus-5-5", effort: .high),
        ]
        policy.scoring.roles["review"] = .init(
            quality: ["claude-opus-5-5": ["low": 480, "high": 520]]
        )
        let oracle = BrokerFixture.oracle(accounts: [
            BrokerFixture.account(weekly: 90), // primary (native): little headroom left
            BrokerFixture.account(
                id: "acct-secondary", label: "Secondary", isPrimary: false, weekly: 10
            ), // secondary (t3): most headroom
        ])

        let ranked = BrokerEngine.rankingEquivalentCandidatesByHeadroom(
            BrokerEngine.expandingModelChoices(policy.roles["review"]!, policy: policy, oracle: oracle, now: now),
            policy: policy, oracle: oracle, now: now
        )
        XCTAssertEqual(
            ranked.map(\.id), ["t3:secondary/claude-opus-5-5", "native/claude-opus-5-5"],
            "headroom ranking must put the t3/high row first, or this test proves nothing"
        )

        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: nil, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)
        let table = try XCTUnwrap(snapshot.modelTables.first)

        let baseRows = table.rows.filter(\.isBase)
        XCTAssertEqual(baseRows.map(\.effortKey), ["low"], "the chain's first occurrence (low) must be Base")
        XCTAssertEqual(baseRows.first?.quality, 480)
    }

    func test_snapshot_orderRowsMatchScoredRowsAndMovedCountsReorderedPositions() throws {
        var (policy, oracle, demand) = BrokerScoringTests.crossModelWorld()
        policy.scoring.roles["review"] = .init(quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496],
        ])
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertEqual(snapshot.orderRows.map(\.candidate), scored.rows.map(\.candidate))
        XCTAssertEqual(snapshot.orderRows.map(\.position), scored.rows.map(\.position))
        XCTAssertEqual(snapshot.moved, 1)

        let decision = try BrokerEngine.decide(
            role: "review", caller: nil, policy: policy, oracle: oracle,
            cooldowns: [:], now: now, t3: [:], demand: demand
        )
        XCTAssertEqual(snapshot.orderRows.first?.candidate, decision.model)
    }

    func test_snapshot_derivedRoleHasNoModelTables() throws {
        let (policy, oracle, demand) = BrokerScoringTests.crossModelWorld()
        XCTAssertTrue(policy.scoring.isEmpty, "crossModelWorld ships no explicit scoring table")
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertTrue(snapshot.isDerived)
        XCTAssertTrue(snapshot.modelTables.isEmpty)
    }

    func test_snapshot_ineligibleReasonPassesThroughOnlyWhenNotEligible() throws {
        var (policy, oracle, demand) = BrokerScoringTests.scoringWorld()
        policy.scoring.roles["review"] = .init(floor: 500, quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496],
        ])
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        let belowFloorRow = try XCTUnwrap(snapshot.orderRows.first { $0.model == "gpt-6-astra" })
        XCTAssertEqual(belowFloorRow.ineligibleReason, "belowFloor")
        let eligibleRow = try XCTUnwrap(snapshot.orderRows.first { $0.model == "claude-opus-5-5" })
        XCTAssertNil(eligibleRow.ineligibleReason)
    }

    // MARK: - effortOrder

    func test_effortOrder_builtInLevelsThenRemainingKeysThenDefaultLast() {
        let policy = BrokerFixture.policy(roles: [:])
        let keys: Set<String> = ["xhigh", "low", "_default", "medium", "custom-key", "high"]
        XCTAssertEqual(
            BrokerRoleScoreSnapshot.effortOrder(keys: keys, model: "claude-sonnet-5", policy: policy),
            ["low", "medium", "high", "xhigh", "custom-key", "_default"]
        )
    }

    func test_effortOrder_emptyKeysIsEmpty() {
        let policy = BrokerFixture.policy(roles: [:])
        XCTAssertEqual(BrokerRoleScoreSnapshot.effortOrder(keys: [], model: "any", policy: policy), [])
    }

    // MARK: - BrokerQualityOrderPresentation: numbers

    func test_oneDecimal_formatsTenthsWithSignAndEmDashForNil() {
        XCTAssertEqual(BrokerQualityOrderPresentation.oneDecimal(502), "50.2")
        XCTAssertEqual(BrokerQualityOrderPresentation.oneDecimal(0), "0.0")
        XCTAssertEqual(BrokerQualityOrderPresentation.oneDecimal(-23), "\u{2212}2.3")
        XCTAssertEqual(BrokerQualityOrderPresentation.oneDecimal(nil), "\u{2014}")
    }

    func test_spokenNumber_readsMinusWordAndUnknown() {
        XCTAssertEqual(BrokerQualityOrderPresentation.spokenNumber(-23), "minus 2.3")
        XCTAssertEqual(BrokerQualityOrderPresentation.spokenNumber(502), "50.2")
        XCTAssertEqual(BrokerQualityOrderPresentation.spokenNumber(nil), "unknown")
    }

    func test_latencySeconds_narrowSpaceUnitAndEmDashForNil() {
        XCTAssertEqual(BrokerQualityOrderPresentation.latencySeconds(21), "21\u{202F}s")
        XCTAssertEqual(BrokerQualityOrderPresentation.latencySeconds(nil), "\u{2014}")
    }

    func test_latencyLimitText_noneWhenNilOtherwiseSeconds() {
        XCTAssertEqual(BrokerQualityOrderPresentation.latencyLimitText(nil), "None")
        XCTAssertEqual(BrokerQualityOrderPresentation.latencyLimitText(34), "34\u{202F}s")
    }

    func test_priceLevel_rawLevelOrEmDashForNil() {
        XCTAssertEqual(BrokerQualityOrderPresentation.priceLevel(0), "0")
        XCTAssertEqual(BrokerQualityOrderPresentation.priceLevel(4), "4")
        XCTAssertEqual(BrokerQualityOrderPresentation.priceLevel(nil), "\u{2014}")
    }

    /// A derived role has no quality table, so its order rows must never
    /// show a real score — the Score column reads "—" regardless of what
    /// the scored row itself carries (UI-SPEC U3, extended to the order
    /// block; must_haves "for a derived table the Score column shows —").
    func test_orderRowScore_nilsOutAnyScoreWhenRoleIsDerived() {
        XCTAssertEqual(BrokerQualityOrderPresentation.orderRowScore(510, isDerived: true), nil)
        XCTAssertEqual(BrokerQualityOrderPresentation.orderRowScore(nil, isDerived: true), nil)
        XCTAssertEqual(BrokerQualityOrderPresentation.orderRowScore(510, isDerived: false), 510)
        XCTAssertEqual(BrokerQualityOrderPresentation.orderRowScore(nil, isDerived: false), nil)
    }

    // MARK: - effortLabel

    func test_effortLabel_builtInLevelsUseDisplayLabel() {
        let policy = BrokerFixture.policy(roles: [:])
        XCTAssertEqual(
            BrokerQualityOrderPresentation.effortLabel("xhigh", model: "claude-sonnet-5-5", policy: policy),
            "XHigh"
        )
    }

    func test_effortLabel_defaultKeyUsesModelsNilLabel() {
        let policy = BrokerFixture.policy(roles: [:])
        XCTAssertEqual(
            BrokerQualityOrderPresentation.effortLabel("_default", model: "claude-sonnet-5-5", policy: policy),
            "Default (high)"
        )
    }

    // MARK: - Chips and capping

    func test_ineligibleChip_precedenceMatchesEngineReasons() {
        XCTAssertEqual(BrokerQualityOrderPresentation.ineligibleChip("noEstimate")?.text, "No estimate")
        XCTAssertEqual(BrokerQualityOrderPresentation.ineligibleChip("belowFloor")?.text, "Below floor")
        XCTAssertEqual(BrokerQualityOrderPresentation.ineligibleChip("overLatencyLimit")?.text, "Over limit")
        XCTAssertNil(BrokerQualityOrderPresentation.ineligibleChip(nil))
    }

    func test_isCapped_trueOnlyWhenEffectiveIsLowerThanQuality() {
        XCTAssertTrue(BrokerQualityOrderPresentation.isCapped(quality: 500, effective: 480))
        XCTAssertFalse(BrokerQualityOrderPresentation.isCapped(quality: 500, effective: 500))
        XCTAssertFalse(BrokerQualityOrderPresentation.isCapped(quality: nil, effective: 480))
        XCTAssertFalse(BrokerQualityOrderPresentation.isCapped(quality: 500, effective: nil))
    }

    // MARK: - Summary line

    func test_summary_matchesEachCopyExactly() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.summary(pricing: "off", moved: 0),
            "\u{201C}Spend expiring quota first\u{201D} is off, so this is the chain order."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.summary(pricing: "unconfident", moved: 3),
            "Quota prices are not reliable yet, so this is the chain order."
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.summary(pricing: "active", moved: 0), "Same as the chain order.")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.summary(pricing: "active", moved: 1),
            "Quota price moved 1 route."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.summary(pricing: "active", moved: 4),
            "Quota price moved 4 routes."
        )
    }

    // MARK: - Stale guard

    func test_isStale_comparesSnapshotChainModelsAgainstVisibleChain() throws {
        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertFalse(
            BrokerQualityOrderPresentation.isStale(snapshot: snapshot, visibleChainModels: ["gpt-6-astra"])
        )
        XCTAssertTrue(
            BrokerQualityOrderPresentation.isStale(snapshot: snapshot, visibleChainModels: ["claude-sonnet-5-5"])
        )
    }

    /// `chainModels` must come from the POLICY chain, not from `scored.rows`:
    /// `ghost-model` has no agent alias, no ChatGPT lane and no T3 instance
    /// reporting it, so `expandingModelChoices` drops it before scoring and
    /// it never appears in a scored row at all. If `chainModels` were built
    /// from those rows (the pre-fix behavior), it would silently lose
    /// `ghost-model`, `isStale` would never match the editor's full chain,
    /// and the section would spin on "Updating order…" forever even though
    /// the chain has not changed — review fix (a).
    func test_snapshot_chainModelsIncludesAnUnroutedModelAndIsNotStale() throws {
        let policy = BrokerFixture.policy(roles: ["review": ["auto/claude-opus-5", "auto/ghost-model"]])
        let oracle = BrokerFixture.oracle()
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: nil, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertEqual(snapshot.chainModels, ["claude-opus-5", "ghost-model"])
        XCTAssertFalse(
            BrokerQualityOrderPresentation.isStale(
                snapshot: snapshot, visibleChainModels: ["claude-opus-5", "ghost-model"]
            )
        )
        // Only the routed model produces an order row; the unrouted model is
        // silently absent from the expansion, not an empty "no routes" state.
        XCTAssertEqual(snapshot.orderRows.map(\.model), ["claude-opus-5"])
    }

    /// When every model in a non-empty chain has no route, the expansion is
    /// empty but the chain itself is not stale — the view must show the "No
    /// routes" text, never the "Updating order…" spinner — review fix (b).
    func test_snapshot_chainWhereNoModelHasARouteIsNotStaleAndHasNoOrderRows() throws {
        let policy = BrokerFixture.policy(roles: ["review": ["auto/ghost-model-1", "auto/ghost-model-2"]])
        let oracle = BrokerFixture.oracle()
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: nil, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertEqual(snapshot.chainModels, ["ghost-model-1", "ghost-model-2"])
        XCTAssertFalse(
            BrokerQualityOrderPresentation.isStale(
                snapshot: snapshot, visibleChainModels: ["ghost-model-1", "ghost-model-2"]
            ),
            "an empty expansion of a non-empty chain is the 'No routes' state, not staleness"
        )
        XCTAssertTrue(snapshot.orderRows.isEmpty)
    }

    /// A reordered chain (same model set, different order) must be detected
    /// as stale — `isStale` compares an ORDERED list, not a set — review fix.
    func test_isStale_detectsAReorderedChainWithTheSameModelSet() throws {
        let policy = BrokerFixture.policy(roles: ["review": ["auto/claude-opus-5", "auto/claude-sonnet-5"]])
        let oracle = BrokerFixture.oracle()
        let scored = try BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: nil, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        XCTAssertEqual(snapshot.chainModels, ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertTrue(
            BrokerQualityOrderPresentation.isStale(
                snapshot: snapshot, visibleChainModels: ["claude-sonnet-5", "claude-opus-5"]
            ),
            "same two models, reversed order, must count as stale"
        )
        XCTAssertFalse(
            BrokerQualityOrderPresentation.isStale(
                snapshot: snapshot, visibleChainModels: ["claude-opus-5", "claude-sonnet-5"]
            ),
            "identical order must not count as stale"
        )
    }

    // MARK: - Accessibility labels

    func test_modelHeaderAccessibilityLabel_appendsNoEstimateOnlyWhenMissing() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHeaderAccessibilityLabel(
                model: "gpt-6-astra", chainRank: 1, hasBaseEstimate: true
            ),
            "gpt-6-astra, chain rank 1"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHeaderAccessibilityLabel(
                model: "gpt-6-astra", chainRank: 2, hasBaseEstimate: false
            ),
            "gpt-6-astra, chain rank 2, no estimate"
        )
    }

    func test_qualityRowAccessibilityLabel_unknownAndCappedWording() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.qualityRowAccessibilityLabel(
                effortLabel: "Medium", quality: 496, effective: 496, latency: 15, isBase: true, capped: false
            ),
            "Medium, quality 49.6, effective 49.6, latency 15 seconds, Base"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.qualityRowAccessibilityLabel(
                effortLabel: "High", quality: 509, effective: nil, latency: nil, isBase: false, capped: false
            ),
            "High, quality 50.9, effective unknown, latency unknown, Raise"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.qualityRowAccessibilityLabel(
                effortLabel: "Medium", quality: 496, effective: 480, latency: 15, isBase: true, capped: true
            ),
            "Medium, quality 49.6, effective 48.0, latency 15 seconds, Base, capped"
        )
    }

    func test_orderRowAccessibilityLabel_appendsChipTextOnlyWhenPresent() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowAccessibilityLabel(
                position: 1, candidate: "codex/gpt-6-astra", level: 2, score: 496, chipText: nil
            ),
            "Position 1, codex/gpt-6-astra, price 2, score 49.6"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowAccessibilityLabel(
                position: 2, candidate: "native/claude-opus-5-5", level: nil, score: nil, chipText: "No estimate"
            ),
            "Position 2, native/claude-opus-5-5, price unknown, score unknown, No estimate"
        )
    }

    // MARK: - BrokerQualityOrderModel

    @MainActor
    func test_model_firstLoadThenPopulated() async {
        let model = BrokerQualityOrderModel()
        XCTAssertTrue(model.isLoadingFirstTime)
        XCTAssertNil(model.snapshot)

        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try! BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        await model.load(role: "review") { _ in snapshot }
        XCTAssertFalse(model.isLoadingFirstTime)
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.snapshot, snapshot)
    }

    @MainActor
    func test_model_nilResultOnFirstLoadSetsLoadFailed() async {
        let model = BrokerQualityOrderModel()
        await model.load(role: "review") { _ in nil }
        XCTAssertFalse(model.isLoadingFirstTime)
        XCTAssertTrue(model.loadFailed)
        XCTAssertNil(model.snapshot)
    }

    @MainActor
    func test_model_reloadKeepsPreviousSnapshotVisibleWhenTheNextLoadFails() async {
        let model = BrokerQualityOrderModel()
        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try! BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)

        await model.load(role: "review") { _ in snapshot }
        await model.load(role: "review") { _ in nil }

        XCTAssertFalse(model.loadFailed, "a reload failure must not replace an already-loaded snapshot")
        XCTAssertEqual(model.snapshot, snapshot)
    }

    @MainActor
    func test_model_reset_returnsToThePreLoadState() async {
        let model = BrokerQualityOrderModel()
        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try! BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)
        await model.load(role: "review") { _ in snapshot }

        model.reset()

        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.isLoadingFirstTime)
        XCTAssertFalse(model.loadFailed)
    }

    // MARK: - State-machine copy (Task 2)

    func test_stateMachineCopy_matchesUISpecCopywritingContractExactly() {
        XCTAssertEqual(BrokerQualityOrderPresentation.loadingText, "Loading order\u{2026}")
        XCTAssertEqual(BrokerQualityOrderPresentation.updatingText, "Updating order\u{2026}")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.noRoutesText,
            "No account or instance can run these models yet. Add one in Instances."
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.brokerOffTitle, "The broker is off")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.brokerOffHint,
            "Turn the broker on with the switch above to see quality estimates and the current order."
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.loadFailedTitle, "Quality data could not be loaded")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.loadFailedHint,
            "Use Reload order to try again. Routing still works."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.derivedNoteText,
            "This role has no quality table. Pinemeter keeps the chain order, and quota price moves "
                + "only models a preset marked as equal in quality."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.gatesNote,
            "Pinemeter tries these in order and picks the first one with quota left."
        )
    }

    func test_chipCopy_matchesUISpecCopywritingContractExactly() {
        XCTAssertEqual(BrokerQualityOrderPresentation.baseChip.text, "Base")
        XCTAssertEqual(BrokerQualityOrderPresentation.baseChip.tooltip, "The effort this chain entry sends.")
        XCTAssertEqual(BrokerQualityOrderPresentation.raiseChip.text, "Raise")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.raiseChip.tooltip,
            "Pinemeter can send this effort instead when this model's quota would otherwise expire unused."
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.derivedChip.text, "Derived from chain order")
        XCTAssertEqual(BrokerQualityOrderPresentation.derivedChip.tooltip, "Saved before quality tables existed.")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.cappedTooltip,
            "Capped at the effective quality of the model above it, so neutral prices keep the chain order."
        )
    }

    // MARK: - Help topic (Task 2)

    func test_qualityAndOrderHelpTopic_hasTheUISpecTerms() {
        let topic = BrokerHelpTopic.qualityAndOrder
        XCTAssertEqual(topic.title, "Quality and order")
        XCTAssertEqual(topic.summary, "How Pinemeter ranks the models in this role when quota prices change.")
        XCTAssertEqual(
            topic.terms.map(\.name),
            [
                "Quality", "Effective", "Floor", "Latency limit", "Raise", "Price", "Score",
                "Demoted", "Sources", "Derived from chain order",
            ]
        )
        let quality = try? XCTUnwrap(topic.terms.first { $0.name == "Quality" })
        XCTAssertTrue(quality?.definition.contains("Artificial Analysis") ?? false)
    }

    func test_rolesAndChainsHelpTopic_accountAndRouteTermNamesQuotaPriceAndTheSection() {
        let term = try! XCTUnwrap(BrokerHelpTopic.rolesAndChains.terms.first { $0.name == "Account and route" })
        XCTAssertTrue(term.definition.hasSuffix(
            "Quota price can also move a model ahead of one of nearly the same quality, so quota that "
                + "would otherwise expire unused is spent first. Quality and order, under each chain, "
                + "shows the result."
        ))
    }

    @MainActor
    func test_model_initialSnapshotCountsAsAlreadyLoaded() {
        let (policy, oracle, demand) = BrokerScoringTests.raiseWorld()
        let scored = try! BrokerScoringEngine.scoredRole(
            role: "review", policy: policy, oracle: oracle, demand: demand, now: now
        )
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy)
        let model = BrokerQualityOrderModel(initialSnapshot: snapshot)

        XCTAssertFalse(model.isLoadingFirstTime)
        XCTAssertEqual(model.snapshot, snapshot)
    }
}
