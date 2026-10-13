//
//  ConnectionStatusTests.swift
//  PinemeterTests
//
//  The status strip's wording is the user's only explanation of why an
//  account or instance is not working and what to do about it. These tests
//  pin the state-to-words mapping so a snapshot is not needed to catch a
//  regression in the remedy text or the offered action.
//

import XCTest
@testable import Pinemeter

final class ConnectionStatusTests: XCTestCase {

    // MARK: - Accounts

    func test_connectedAccountShowsUsageAgeAndNoAction() {
        let status = ConnectionStatus.forAccount(
            health: .valid, usageAge: 90, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .healthy)
        XCTAssertEqual(status.title, "Connected")
        XCTAssertEqual(status.detail, "Usage updated 1m ago.")
        XCTAssertNil(status.action)
    }

    func test_monitoringOffWinsOverHealthAndOffersGeneralSettings() {
        let status = ConnectionStatus.forAccount(
            health: .valid, usageAge: 5, monitoringOff: true,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .off)
        XCTAssertEqual(status.action, .openGeneralSettings)
    }

    func test_unknownHealthWaitsForUsageAndOffersRefresh() {
        let status = ConnectionStatus.forAccount(
            health: .unknown, usageAge: nil, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .waiting)
        XCTAssertEqual(status.title, "Waiting for usage")
        XCTAssertEqual(status.action, .refreshUsage)
    }

    func test_refreshRecommendedWarnsAndOffersReconnect() {
        let status = ConnectionStatus.forAccount(
            health: .refreshRecommended, usageAge: 10, monitoringOff: false,
            error: nil, recoverySuggestion: "Reconnect from Chrome.", hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(status.detail, "Reconnect from Chrome.")
        XCTAssertEqual(status.action, .reconnect)
    }

    func test_expiredSessionPrefersErrorTextThenRecoverySuggestion() {
        let withError = ConnectionStatus.forAccount(
            health: .expired, usageAge: nil, monitoringOff: false,
            error: "401 from provider", recoverySuggestion: "Sign in again.", hasRepairAction: false
        )
        XCTAssertEqual(withError.tone, .failure)
        XCTAssertEqual(withError.title, "Session expired")
        XCTAssertEqual(withError.detail, "401 from provider")
        XCTAssertEqual(withError.action, .reconnect)

        let withoutError = ConnectionStatus.forAccount(
            health: .invalid, usageAge: nil, monitoringOff: false,
            error: nil, recoverySuggestion: "Sign in again.", hasRepairAction: true
        )
        XCTAssertEqual(withoutError.title, "Not connected")
        XCTAssertEqual(withoutError.detail, "Sign in again.")
        XCTAssertEqual(withoutError.action, .repair, "A provider repair action outranks a browser rescan")
    }

    func test_missingCredentialIsNotConnectedAndOffersReconnect() {
        let status = ConnectionStatus.forAccount(
            health: .missing, usageAge: 30, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.title, "Not connected")
        XCTAssertEqual(status.detail, "No saved session for this account. Sign in to the provider in your browser, then reconnect.")
        XCTAssertEqual(status.action, .reconnect)
    }

    func test_validatingShowsCheckingWithNoAction() {
        let status = ConnectionStatus.forAccount(
            health: .validating, usageAge: nil, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        )
        XCTAssertEqual(status.tone, .checking)
        XCTAssertNil(status.action)
    }

    // MARK: - T3 instances

    func test_reachableDetectedInstanceIsHealthyWithProbeResult() {
        let status = ConnectionStatus.forInstance(
            reachable: true, why: "http 200", instanceStatus: .detected, staleAge: nil
        )
        XCTAssertEqual(status.tone, .healthy)
        XCTAssertEqual(status.title, "Reachable")
        XCTAssertEqual(status.detail, "Health check answered: http 200.")
        XCTAssertNil(status.action)
    }

    func test_unreachableInstanceExplainsCauseAndRemedy() throws {
        let status = ConnectionStatus.forInstance(
            reachable: false, why: "connect failed", instanceStatus: .detected, staleAge: nil
        )
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.title, "Unreachable")
        XCTAssertEqual(status.action, .probeInstance)
        let detail = try XCTUnwrap(status.detail)
        XCTAssertTrue(detail.contains("Start T3"), "Remedy must name the action: \(detail)")
        XCTAssertTrue(detail.contains("health check address"), "Remedy must point at the override: \(detail)")
        XCTAssertTrue(detail.hasSuffix("Last probe: connect failed."))
    }

    func test_neverProbedInstanceWaits() {
        let status = ConnectionStatus.forInstance(
            reachable: nil, why: nil, instanceStatus: .manual, staleAge: nil
        )
        XCTAssertEqual(status.tone, .waiting)
        XCTAssertEqual(status.title, "Not checked yet")
        XCTAssertEqual(status.action, .probeInstance)
    }

    func test_staleDetectionWarnsWithAgeWhetherOrNotReachable() {
        let reachable = ConnectionStatus.forInstance(
            reachable: true, why: "http 200", instanceStatus: .stale, staleAge: 3 * 3600
        )
        XCTAssertEqual(reachable.tone, .warning)
        XCTAssertEqual(reachable.title, "Reachable, detection stale")
        XCTAssertEqual(reachable.detail, "T3 has not reported this instance for 3h. Start T3 for this instance, then probe again.")

        let unprobed = ConnectionStatus.forInstance(
            reachable: nil, why: nil, instanceStatus: .stale, staleAge: nil
        )
        XCTAssertEqual(unprobed.tone, .warning)
        XCTAssertEqual(unprobed.title, "Detection stale")
        XCTAssertEqual(unprobed.action, .probeInstance)
    }

    // MARK: - Age text

    func test_ageTextRoundsToTheLargestWholeUnit() {
        XCTAssertEqual(ConnectionStatus.ageText(12), "12s")
        XCTAssertEqual(ConnectionStatus.ageText(59.6), "1m")
        XCTAssertEqual(ConnectionStatus.ageText(3599), "59m")
        XCTAssertEqual(ConnectionStatus.ageText(7200), "2h")
        XCTAssertEqual(ConnectionStatus.ageText(2 * 86_400), "2d")
    }
}
