//
//  BrokerOutcomesPaneTests.swift
//  PinemeterTests
//
//  Pure state-machine, copy and accessibility coverage for the Outcomes
//  pane (OUTC-03). These test the static helpers directly, the same
//  pattern as `BrokerActivityPane.filter` — no rendering required.
//

import XCTest
@testable import Pinemeter

final class BrokerOutcomesPaneTests: XCTestCase {

    // MARK: - taskCountText

    func test_taskCountText_singularPluralAndZero() {
        XCTAssertEqual(BrokerOutcomesPane.taskCountText(1), "1 task in 7 days")
        XCTAssertEqual(BrokerOutcomesPane.taskCountText(2), "2 tasks in 7 days")
        XCTAssertEqual(BrokerOutcomesPane.taskCountText(0), "0 tasks in 7 days")
    }

    // MARK: - noteText

    func test_noteText_brokerOnAlwaysShowsTheOwnHistoryNote() {
        XCTAssertEqual(
            BrokerOutcomesPane.noteText(isEnabled: true, hasData: true),
            "Each model is compared only with its own history in this role. Kept across restarts for 180 days."
        )
        XCTAssertEqual(
            BrokerOutcomesPane.noteText(isEnabled: true, hasData: false),
            "Each model is compared only with its own history in this role. Kept across restarts for 180 days."
        )
    }

    func test_noteText_brokerOffWithDataShowsTheBrokerOffVariant() {
        XCTAssertEqual(
            BrokerOutcomesPane.noteText(isEnabled: false, hasData: true),
            "The broker is off. This is the history recorded while it was on."
        )
    }

    func test_noteText_brokerOffWithNoDataShowsNoNoteLine() {
        XCTAssertNil(BrokerOutcomesPane.noteText(isEnabled: false, hasData: false))
    }

    // MARK: - rowAccessibilityLabel

    func test_rowAccessibilityLabel_emDashReadsAsNotEnoughData() {
        let row = makeRow(label: "Tokens per task", recent: "\u{2014}", baseline: "\u{2014}", change: "\u{2014}")
        XCTAssertEqual(
            BrokerOutcomesPane.rowAccessibilityLabel(row),
            "Tokens per task, last 7 days not enough data, previous 28 days not enough data, change not enough data"
        )
    }

    func test_rowAccessibilityLabel_minusSignReadsAsMinusAndPtsReadsAsPoints() {
        let row = makeRow(label: "Failed", recent: "3%", baseline: "7%", change: "\u{2212}4 pts")
        XCTAssertEqual(
            BrokerOutcomesPane.rowAccessibilityLabel(row),
            "Failed, last 7 days 3%, previous 28 days 7%, change minus 4 points"
        )
    }

    func test_rowAccessibilityLabel_plusSignIsUnchanged() {
        let row = makeRow(label: "Tasks per day", recent: "4.9", baseline: "4.3", change: "+0.6")
        XCTAssertEqual(
            BrokerOutcomesPane.rowAccessibilityLabel(row),
            "Tasks per day, last 7 days 4.9, previous 28 days 4.3, change +0.6"
        )
    }

    // MARK: - groupAccessibilityLabel

    func test_groupAccessibilityLabel_namesModelEffortAndTaskCount() {
        let group = BrokerOutcomeTrend.Group(model: "claude-opus-5-5", effort: "high", recentTasks: 1, rows: [])
        XCTAssertEqual(
            BrokerOutcomesPane.groupAccessibilityLabel(group),
            "claude-opus-5-5, effort high, 1 task in 7 days"
        )
    }

    func test_groupAccessibilityLabel_pluralTaskCount() {
        let group = BrokerOutcomeTrend.Group(model: "claude-opus-5-5", effort: "high", recentTasks: 0, rows: [])
        XCTAssertEqual(
            BrokerOutcomesPane.groupAccessibilityLabel(group),
            "claude-opus-5-5, effort high, 0 tasks in 7 days"
        )
    }

    // MARK: - paneState

    private func makeTrend(role: String?, state: String, roles: [BrokerOutcomeTrend.Role] = []) -> BrokerOutcomeTrend {
        BrokerOutcomeTrend(
            today: "2026-10-09", includeAllReasons: false, role: role, roles: roles, state: state, groups: []
        )
    }

    func test_paneState_firstLoadInFlightIsLoading() {
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: nil, isEnabled: true, hasLoaded: false),
            .loading
        )
    }

    func test_paneState_readFailedTakesPriorityOverTrendState() {
        let view = BrokerOutcomeView(trend: makeTrend(role: nil, state: "no-data"), loadFailed: true)
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: true, hasLoaded: true),
            .readFailed
        )
    }

    func test_paneState_noDataWhileEnabledIsNoData() {
        let view = BrokerOutcomeView(trend: makeTrend(role: nil, state: "no-data"), loadFailed: false)
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: true, hasLoaded: true),
            .noData
        )
    }

    func test_paneState_noDataWhileDisabledIsBrokerOff() {
        let view = BrokerOutcomeView(trend: makeTrend(role: nil, state: "no-data"), loadFailed: false)
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: false, hasLoaded: true),
            .brokerOff
        )
    }

    func test_paneState_filteredEmpty() {
        let roles = [BrokerOutcomeTrend.Role(role: "review", recentPicks: 3)]
        let view = BrokerOutcomeView(
            trend: makeTrend(role: "review", state: "filtered-empty", roles: roles), loadFailed: false
        )
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: true, hasLoaded: true),
            .filteredEmpty
        )
    }

    func test_paneState_populated() {
        let roles = [BrokerOutcomeTrend.Role(role: "review", recentPicks: 3)]
        let view = BrokerOutcomeView(
            trend: makeTrend(role: "review", state: "populated", roles: roles), loadFailed: false
        )
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: true, hasLoaded: true),
            .populated
        )
    }

    func test_paneState_brokerOffWithExistingDataStaysPopulated() {
        // Broker off with data present shows the data (history is still
        // valid); only the note line changes to the broker-off variant.
        let roles = [BrokerOutcomeTrend.Role(role: "review", recentPicks: 3)]
        let view = BrokerOutcomeView(
            trend: makeTrend(role: "review", state: "populated", roles: roles), loadFailed: false
        )
        XCTAssertEqual(
            BrokerOutcomesPane.paneState(view: view, isEnabled: false, hasLoaded: true),
            .populated
        )
    }

    // MARK: - Helpers

    private func makeRow(label: String, recent: String, baseline: String, change: String) -> BrokerOutcomeTrend.Row {
        BrokerOutcomeTrend.Row(
            label: label, recent: recent, baseline: baseline, change: change,
            modelChanged: false, recentSamples: 5, baselineSamples: 5
        )
    }
}
