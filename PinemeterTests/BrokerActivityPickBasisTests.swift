//
//  BrokerActivityPickBasisTests.swift
//  PinemeterTests
//
//  The Activity pane's pick reason chip (OUTC-01 made visible): pure
//  coverage for the label/tooltip mapping, the filter extension and the
//  accessibility label, mirroring `BrokerActivityPane.filter`'s own test
//  pattern — no rendering required.
//

import XCTest
@testable import Pinemeter

final class BrokerActivityPickBasisTests: XCTestCase {
    func test_controlledOnlyFilterMatchesDisplayedChip() {
        let pick = RecentPick(timestamp: Date(), role: "verification", caller: "codex",
            candidate: "t3:pi/lab/qwen-27b", route: "t3", degraded: false, reason: "top of chain",
            residency: "controlled", routeClass: "controlled")
        XCTAssertEqual(BrokerActivityPane.filter([pick], query: "Controlled only", degradedOnly: false).count, 1)
        XCTAssertTrue(BrokerActivityPane.rowAccessibilityLabel(pick).hasSuffix(", controlled only"))
    }

    private func residencyPick(_ requirement: String?, _ routeClass: String?) -> RecentPick {
        RecentPick(timestamp: Date(), role: "verification", caller: "codex", candidate: "t3:pi/lab/qwen-27b",
                   route: "t3", degraded: false, reason: "top of chain", residency: requirement, routeClass: routeClass)
    }
    func test_residencyChipRestrictedTakesPrecedence() {
        for routeClass in [nil, "controlled", "vendor"] {
            let pick = residencyPick("controlled", routeClass)
            XCTAssertEqual(BrokerActivityPane.residencyLabel(pick), "Controlled only")
            XCTAssertEqual(BrokerActivityPane.residencyTooltip(pick), "This pick required controlled infrastructure. Prompts and code stayed on hosts you control.")
        }
    }
    func test_residencyChipUnrestrictedControlled() {
        let pick = residencyPick(nil, "controlled")
        XCTAssertEqual(BrokerActivityPane.residencyLabel(pick), "Controlled")
        XCTAssertEqual(BrokerActivityPane.residencyTooltip(pick), "This model runs on a host you control. The pick did not require it.")
        XCTAssertTrue(BrokerActivityPane.rowAccessibilityLabel(pick).hasSuffix(", controlled"))
        XCTAssertEqual(BrokerActivityPane.filter([pick], query: "CONTROLLED", degradedOnly: false).count, 1)
    }
    func test_residencyChipVendorAndOldPicksHaveNone() {
        for pick in [residencyPick(nil, nil), residencyPick(nil, "vendor"), residencyPick("vendor", "controlled")] {
            XCTAssertNil(BrokerActivityPane.residencyLabel(pick)); XCTAssertNil(BrokerActivityPane.residencyTooltip(pick))
            XCTAssertFalse(BrokerActivityPane.rowAccessibilityLabel(pick).contains(", controlled"))
            XCTAssertTrue(BrokerActivityPane.filter([pick], query: "Controlled", degradedOnly: false).isEmpty)
        }
    }
    func test_residencyHelpTermsMatchContract() {
        let terms = Array(BrokerHelpTopic.activity.terms.suffix(2))
        XCTAssertEqual(terms.map(\.name), ["Controlled only", "Controlled"])
        XCTAssertEqual(terms.map(\.definition), [
            "The agent or the role required controlled infrastructure, and the pick stayed on a host you control.",
            "The pick landed on a host you control without being required to."
        ])
    }

    // MARK: - pickBasisLabel

    func test_pickBasisLabel_quotaIsQuota() {
        XCTAssertEqual(BrokerActivityPane.pickBasisLabel(.quota), "Quota")
    }

    func test_pickBasisLabel_humanOverrideIsOverride() {
        XCTAssertEqual(BrokerActivityPane.pickBasisLabel(.humanOverride), "Override")
    }

    func test_pickBasisLabel_driftIsDrift() {
        XCTAssertEqual(BrokerActivityPane.pickBasisLabel(.drift), "Drift")
    }

    func test_pickBasisLabel_qualityShowsNoChip() {
        XCTAssertNil(BrokerActivityPane.pickBasisLabel(.quality))
    }

    func test_pickBasisLabel_nilShowsNoChip() {
        XCTAssertNil(BrokerActivityPane.pickBasisLabel(nil))
    }

    // MARK: - pickBasisTooltip

    func test_pickBasisTooltip_matchesTheUISpecTableExactly() {
        XCTAssertEqual(
            BrokerActivityPane.pickBasisTooltip(.quota),
            "A higher-ranked model was held back by quota pacing or because its quota could not be verified, or quota price picked a model of nearly the same quality or raised the effort to spend quota that would otherwise expire."
        )
        XCTAssertEqual(
            BrokerActivityPane.pickBasisTooltip(.humanOverride),
            "You asked for this model by name for this one dispatch."
        )
        XCTAssertEqual(
            BrokerActivityPane.pickBasisTooltip(.drift),
            "A higher-ranked model was moved behind the others because model health reports a quality drop for it."
        )
        XCTAssertNil(BrokerActivityPane.pickBasisTooltip(.quality))
        XCTAssertNil(BrokerActivityPane.pickBasisTooltip(nil))
    }

    // MARK: - filter

    func test_filter_queryQuotaMatchesAQuotaPick() {
        let picks = [
            makePick(role: "execution", pickBasis: .quota),
            makePick(role: "planning", pickBasis: .quality),
        ]
        let filtered = BrokerActivityPane.filter(picks, query: "quota", degradedOnly: false)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.role, "execution")
    }

    func test_filter_queryOverrideMatchesAnOverridePick() {
        let picks = [
            makePick(role: "execution", pickBasis: .humanOverride),
            makePick(role: "planning", pickBasis: .quality),
        ]
        let filtered = BrokerActivityPane.filter(picks, query: "override", degradedOnly: false)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.role, "execution")
    }

    func test_filter_queryDriftMatchesADriftPick() {
        let picks = [
            makePick(role: "execution", pickBasis: .drift),
            makePick(role: "planning", pickBasis: .quality),
        ]
        let filtered = BrokerActivityPane.filter(picks, query: "drift", degradedOnly: false)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.role, "execution")
    }

    // MARK: - rowAccessibilityLabel

    func test_rowAccessibilityLabel_appendsTheChipLabelOnlyWhenTheChipShows() {
        let withChip = makePick(role: "execution", pickBasis: .quota)
        XCTAssertEqual(
            BrokerActivityPane.rowAccessibilityLabel(withChip),
            "execution routed to native/claude-fable-5. top of chain, Quota"
        )

        let withoutChip = makePick(role: "execution", pickBasis: .quality)
        XCTAssertEqual(
            BrokerActivityPane.rowAccessibilityLabel(withoutChip),
            "execution routed to native/claude-fable-5. top of chain"
        )

        let noBasis = makePick(role: "execution", pickBasis: nil)
        XCTAssertEqual(
            BrokerActivityPane.rowAccessibilityLabel(noBasis),
            "execution routed to native/claude-fable-5. top of chain"
        )
    }

    // MARK: - Helpers

    private func makePick(
        role: String,
        pickBasis: BrokerPickBasis?
    ) -> RecentPick {
        RecentPick(
            timestamp: Date(), role: role, caller: "claude-code", candidate: "native/claude-fable-5",
            route: "native", degraded: false, reason: "top of chain", pickBasis: pickBasis
        )
    }
}
