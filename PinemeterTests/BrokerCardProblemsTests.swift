//
//  BrokerCardProblemsTests.swift
//  PinemeterTests
//
//  Every warning state the popover's broker card can show must name a cause
//  and offer at least one action, so a "Degraded" pill never appears alone.
//

import XCTest
@testable import Pinemeter

@MainActor
final class BrokerCardProblemsTests: XCTestCase {
    private func freshness(
        present: Bool = true,
        stale: Bool = false,
        age: Double? = 12,
        accounts: [BrokerStatus.AccountFreshness] = []
    ) -> BrokerStatus.OracleFreshness {
        BrokerStatus.OracleFreshness(present: present, stale: stale, ageSeconds: age, accounts: accounts)
    }

    private func state(
        server: BrokerUIState.ServerState = .running(port: 43117),
        degraded: Bool = false,
        degradedReason: String? = nil,
        auditFailed: Bool = false,
        routes: [BrokerStatus.RouteHealth] = [],
        oracle: BrokerStatus.OracleFreshness? = nil
    ) -> BrokerUIState {
        BrokerUIState(
            serverState: server,
            lastPickSummary: degraded ? "planning \u{2192} native/claude-sonnet-5" : nil,
            lastPickDegraded: degraded,
            lastPickDegradedReason: degradedReason,
            auditPersistenceFailed: auditFailed,
            routeHealth: routes,
            oracleFreshness: oracle ?? freshness()
        )
    }

    func test_healthyRunningBrokerHasNoProblems() {
        XCTAssertEqual(BrokerCardView.problems(for: state(), isEnabled: true), [])
    }

    func test_disabledBrokerHasNoProblems() {
        let uiState = state(server: .failed(message: "Port in use"), auditFailed: true)
        XCTAssertEqual(BrokerCardView.problems(for: uiState, isEnabled: false), [])
    }

    func test_everyProblemOffersAnAction() {
        let uiState = state(
            degraded: true,
            degradedReason: "every candidate is over its ceiling",
            auditFailed: true,
            routes: [BrokerStatus.RouteHealth(instanceId: "codex", reachable: false, why: "connection refused")],
            oracle: freshness(stale: true, age: 4000)
        )
        let problems = BrokerCardView.problems(for: uiState, isEnabled: true)
        XCTAssertEqual(problems.map(\.id), ["audit-failed", "oracle-stale", "last-pick-degraded", "instance-codex"])
        for problem in problems {
            XCTAssertFalse(problem.actions.isEmpty, "\(problem.id) has no action")
            XCTAssertFalse(problem.text.isEmpty, "\(problem.id) has no explanation")
        }
    }

    func test_usagePickAndInstanceRowsWaitForRunning() {
        for server in [BrokerUIState.ServerState.starting, .stopped] {
            let uiState = state(
                server: server,
                degraded: true,
                routes: [BrokerStatus.RouteHealth(instanceId: "codex", reachable: false, why: "connection refused")],
                oracle: freshness(stale: true, age: 4000)
            )
            XCTAssertEqual(BrokerCardView.problems(for: uiState, isEnabled: true), [], "\(server)")
        }
    }

    func test_auditFailureShowsWhileServerFailed() {
        let uiState = state(server: .failed(message: "Port 43117 is already in use."), auditFailed: true)
        let problems = BrokerCardView.problems(for: uiState, isEnabled: true)
        XCTAssertEqual(problems.map(\.id), ["server-failed", "audit-failed"])
        XCTAssertEqual(problems.last?.actions, [.showAuditFolder])
    }

    func test_staleUsageOffersRefreshAndAccounts() {
        let problems = BrokerCardView.problems(
            for: state(oracle: freshness(stale: true, age: 4000)),
            isEnabled: true
        )
        XCTAssertEqual(problems.first?.actions, [.refreshUsage, .openAccounts])
    }

    func test_missingUsageOffersOnlyAccounts() {
        let problems = BrokerCardView.problems(
            for: state(oracle: freshness(present: false, age: nil)),
            isEnabled: true
        )
        XCTAssertEqual(problems.first?.actions, [.openAccounts])
    }

    func test_degradedPickCarriesTheEngineReason() {
        let problems = BrokerCardView.problems(
            for: state(degraded: true, degradedReason: "every candidate is over its ceiling"),
            isEnabled: true
        )
        XCTAssertEqual(problems.first?.detail, "every candidate is over its ceiling")
        XCTAssertEqual(problems.first?.actions, [.openActivity])
    }

    func test_failedServerOffersRetry() {
        let problems = BrokerCardView.problems(
            for: state(server: .failed(message: "Port 43117 is already in use.")),
            isEnabled: true
        )
        XCTAssertEqual(problems.map(\.id), ["server-failed"])
        XCTAssertEqual(problems.first?.text, "Port 43117 is already in use.")
        XCTAssertEqual(problems.first?.actions, [.retryServer, .openBroker])
    }

    func test_unreachableInstanceNamesWhyAndLinksToIt() {
        let problems = BrokerCardView.problems(
            for: state(routes: [
                BrokerStatus.RouteHealth(instanceId: "codex", reachable: false, why: "connection refused"),
                BrokerStatus.RouteHealth(instanceId: "claudeAgent", reachable: true, why: "reachable"),
            ]),
            isEnabled: true
        )
        XCTAssertEqual(problems.first?.text, "T3 instance codex is unreachable: connection refused.")
        XCTAssertEqual(problems.first?.actions, [.openInstance("codex")])
    }

    func test_oracleProblemNamesUnhealthyAccounts() {
        let text = BrokerHealthGuidance.oracleProblem(freshness(stale: true, accounts: [
            BrokerStatus.AccountFreshness(id: "a", label: "Work", state: "error"),
            BrokerStatus.AccountFreshness(id: "b", label: "Personal", state: "fresh"),
        ]))
        XCTAssertTrue(text.contains("Work (error)"), text)
        XCTAssertFalse(text.contains("Personal"), text)
    }

    func test_oracleProblemStatesAgeWhenNoAccountIsFlagged() {
        let text = BrokerHealthGuidance.oracleProblem(freshness(stale: true, age: 7200))
        XCTAssertTrue(text.contains("2h old"), text)
    }

    func test_oracleProblemWithoutDataAsksForAnAccount() {
        let text = BrokerHealthGuidance.oracleProblem(freshness(present: false, age: nil))
        XCTAssertTrue(text.hasPrefix("No usage data yet."), text)
    }
}
