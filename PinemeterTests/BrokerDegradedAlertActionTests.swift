//
//  BrokerDegradedAlertActionTests.swift
//  PinemeterTests
//
//  The degraded-pick alert's action choice. `pick` already spends the
//  refresh-and-re-pick retry before posting `.brokerDegradedPick`, so a
//  cooldown reset is the only remaining action that can change the next
//  pick's outcome. When no cooldown is set, the alert must offer the
//  Broker window instead of an action that provably does nothing.
//

import XCTest
@testable import Pinemeter

final class BrokerDegradedAlertActionTests: XCTestCase {
    func test_forDecision_withActiveCooldown_offersClearCooldowns() {
        XCTAssertEqual(
            BrokerDegradedAlertAction.forDecision(fault: nil, hasActiveCooldowns: true),
            .clearCooldowns
        )
    }

    func test_forDecision_withNoActiveCooldown_offersBrokerSettings() {
        XCTAssertEqual(
            BrokerDegradedAlertAction.forDecision(fault: nil, hasActiveCooldowns: false),
            .openBrokerSettings
        )
    }

    func test_buttonTitle_namesTheActionItPerforms() {
        XCTAssertEqual(BrokerDegradedAlertAction.clearCooldowns.buttonTitle, "Clear Cooldowns")
        XCTAssertEqual(BrokerDegradedAlertAction.openBrokerSettings.buttonTitle, "Open Broker Window")
        XCTAssertEqual(BrokerDegradedAlertAction.openAccountsSettings.buttonTitle, "Open Accounts Settings")
    }

    // MARK: - A provider fault outranks the cooldown question

    func test_providerFault_sendsTheOperatorToAccountsEvenWithACooldownSet() {
        XCTAssertEqual(
            BrokerDegradedAlertAction.forDecision(fault: .chatGPTDisconnected, hasActiveCooldowns: true),
            .openAccountsSettings,
            "clearing cooldowns cannot make a dead poll answer; the account is what needs repairing"
        )
    }

    func test_providerFault_sendsTheOperatorToAccountsWithNoCooldown() {
        XCTAssertEqual(
            BrokerDegradedAlertAction.forDecision(
                fault: .claudeAccountDisconnected(label: "work-account"),
                hasActiveCooldowns: false
            ),
            .openAccountsSettings
        )
    }

    func test_alertTitle_leadsWithTheCauseWhenThereIsOne() {
        XCTAssertEqual(BrokerProviderFault.chatGPTDisconnected.alertTitle, "ChatGPT Usage Disconnected")
        XCTAssertEqual(
            BrokerProviderFault.claudeAccountDisconnected(label: "work-account").alertTitle,
            "Claude Usage Disconnected"
        )
    }
}
