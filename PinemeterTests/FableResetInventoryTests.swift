import Foundation
import XCTest
@testable import Pinemeter

final class FableResetInventoryTests: XCTestCase {
    let now = BrokerFixture.now
    func evidence(_ fable: Double = 94, at: Date? = nil, reset: Date? = nil) -> FableResetEvidence {
        FableResetEvidence(observedAt: at ?? now, weekly: 60, fable: fable, resetAt: reset ?? now.addingTimeInterval(3 * 86400))
    }
    func inventory(count: Int = 3) -> FableResetInventory {
        FableResetInventory(count: count, expiresAt: now.addingTimeInterval(20 * 86400))
    }
    func testNaturalResetAndOneHundredRefreshesDoNotSpendInventory() {
        var state = inventory()
        for _ in 0..<100 { _ = state.observe(evidence(), now: now, active: true) }
        XCTAssertEqual(state.delivered.filter { $0.hasPrefix("redeem:") }.count, 1)
        XCTAssertEqual(state.count, 3)
        _ = state.observe(evidence(0, at: now.addingTimeInterval(3 * 86400), reset: now.addingTimeInterval(10 * 86400)), now: now.addingTimeInterval(3 * 86400), active: true)
        XCTAssertEqual(state.count, 3)
    }
    func testZeroFableAndStaleOrMissingDataNeverAdviseRedemption() {
        for reading in [evidence(0), evidence(94, at: now.addingTimeInterval(-1000))] {
            var state = inventory()
            XCTAssertFalse(state.observe(reading, now: now, active: true).contains { $0.kind == .redeem })
        }
        var state = inventory()
        XCTAssertFalse(state.observe(nil, now: now, active: true).contains { $0.kind == .redeem })
    }
    func testRepeatedRedemptionsRearmAndDoubleConfirmUndoAreInert() throws {
        var state = inventory()
        for index in 0..<3 {
            let time = now.addingTimeInterval(Double(index * 300))
            let before = evidence(94, at: time)
            let notice = try XCTUnwrap(state.observe(before, now: time, active: true).first { $0.kind == .redeem })
            XCTAssertTrue(state.redeemed(id: notice.id, now: time))
            XCTAssertFalse(state.redeemed(id: notice.id, now: time))
            XCTAssertTrue(state.observe(before, now: time, active: true).isEmpty)
            _ = state.observe(evidence(0, at: time.addingTimeInterval(1), reset: time.addingTimeInterval(7 * 86400)), now: time.addingTimeInterval(1), active: true)
            XCTAssertEqual(state.generation, index + 1)
        }
        XCTAssertEqual(state.count, 0)
        let id = try XCTUnwrap(state.events.last?.id)
        XCTAssertTrue(state.undo(id: id))
        XCTAssertFalse(state.undo(id: id))
        XCTAssertEqual(state.count, 1)
    }
    func testFailedRefreshRequiresConfirmationWithoutExtendingWaiver() throws {
        var state = inventory(count: 1)
        let notice = try XCTUnwrap(state.observe(evidence(), now: now, active: true).first { $0.kind == .redeem })
        XCTAssertTrue(state.redeemed(id: notice.id, now: now))
        for minute in [0, 5, 10, 15, 20] { _ = state.takeRefreshAttempt(now: now.addingTimeInterval(Double(minute * 60))) }
        XCTAssertEqual(state.events.last?.attempts, 3)
        XCTAssertEqual(state.waiverDeadline, state.expiresAt)
        XCTAssertTrue(state.confirmUnverified(id: notice.id))
        XCTAssertFalse(state.confirmUnverified(id: notice.id))
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.waiverDeadline, state.expiresAt)
        XCTAssertTrue(state.observe(evidence(), now: now, active: true).isEmpty)
    }
    func testLastRefillSurvivesZeroCountExpiryAndRestart() throws {
        var state = FableResetInventory(count: 1, expiresAt: now.addingTimeInterval(100))
        let notice = try XCTUnwrap(state.observe(evidence(60), now: now, active: true).first { $0.kind == .redeem })
        XCTAssertTrue(state.redeemed(id: notice.id, now: now))
        let refill = evidence(0, at: now.addingTimeInterval(1), reset: now.addingTimeInterval(7 * 86400))
        _ = state.observe(refill, now: now.addingTimeInterval(1), active: true)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.waiverDeadline, now.addingTimeInterval(7 * 86400))
        let restored = try JSONDecoder().decode(FableResetInventory.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertTrue(restored.waiverDeadline > state.expiresAt)
        XCTAssertEqual(ISO8601DateFormatter().string(from: FableResetInventory.defaultExpiry), "2027-03-09T07:59:00Z")
    }
    func testExpiryBandsUrgencySnoozeAndWindowBoundaries() throws {
        XCTAssertEqual(FableResetInventory.weeklyOpportunities(resetAt: now, expiry: now.addingTimeInterval(7 * 86400 - 1)), 0)
        XCTAssertEqual(FableResetInventory.weeklyOpportunities(resetAt: now, expiry: now.addingTimeInterval(7 * 86400)), 1)
        var state = FableResetInventory(count: 1, expiresAt: now.addingTimeInterval(86400))
        let first = state.observe(evidence(50, reset: now.addingTimeInterval(3600)), now: now, active: true)
        XCTAssertEqual(first.filter { $0.kind == .expiry }.count, 1)
        XCTAssertEqual(first.filter { $0.kind == .redeem }.count, 1)
        state.snooze(until: now.addingTimeInterval(60))
        XCTAssertTrue(state.observe(evidence(50), now: now, active: true).isEmpty)
        let later = now.addingTimeInterval(61)
        let resumed = state.observe(evidence(50, at: later), now: later, active: true)
        XCTAssertEqual(resumed.filter { $0.kind == .redeem }.count, 1)
        XCTAssertTrue(state.observe(evidence(94, at: state.expiresAt), now: state.expiresAt, active: true).isEmpty)
    }
    func testExternalEarlyDropRequiresManualAccountingAndFreshFollowup() throws {
        var state = inventory()
        _ = state.observe(evidence(), now: now, active: true)
        let later = now.addingTimeInterval(60)
        let notices = state.observe(evidence(0, at: later), now: later, active: true)
        let notice = try XCTUnwrap(notices.first { $0.kind == .external })
        XCTAssertEqual(state.count, 3)
        XCTAssertTrue(state.redeemed(id: notice.id, now: later))
        XCTAssertEqual(state.count, 2)
        _ = state.observe(evidence(0, at: later.addingTimeInterval(1)), now: later.addingTimeInterval(1), active: true)
        XCTAssertEqual(state.events.last?.before?.fable, 94)
        XCTAssertEqual(state.events.last?.after?.fable, 0)
        XCTAssertEqual(state.generation, 1)
    }
    func testInventoryRoundTripOldDecodeCorrectionsAndExportIsolation() throws {
        var settings = BrokerSettings.default
        let base = settings.policy
        var state = inventory()
        state.correct(count: -5, expiry: now.addingTimeInterval(100), provenance: "Corrected UTC source", now: now)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.corrections.count, 1)
        settings.fableResets["account-fixture"] = state
        XCTAssertEqual(try JSONDecoder().decode(BrokerSettings.self, from: JSONEncoder().encode(settings)).fableResets, settings.fableResets)
        XCTAssertEqual(settings.policy, base)
        XCTAssertTrue(try JSONDecoder().decode(BrokerSettings.self, from: Data("{}".utf8)).fableResets.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(BrokerSettings.self, from: Data("{\"fable_resets\":false}".utf8)).fableResets.isEmpty)
    }

    @MainActor
    func testStartStopPreserveBaseAndInventoryWithoutRemotePush() async throws {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            notificationService: NotificationServiceSpy(), brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() }, t3InstanceDiscovery: T3InstanceDiscoveryFake())
        let before = model.settings
        await model.editFableInventory(accountID: "account-a", count: 1, expiry: Date().addingTimeInterval(86400), provenance: "Fixture UTC")
        await model.startFableCampaign()
        XCTAssertNotNil(model.settings.broker.fableCampaign)
        XCTAssertEqual(model.settings.broker.effectivePolicy(now: Date()).thresholds.fableWeeklyPct, 95)
        XCTAssertFalse(AppModel.remotePushPayloadChanged(from: before, to: model.settings))
        model.settings.broker.policy.thresholds.weeklyPct = 71
        await model.stopFableCampaign()
        XCTAssertNil(model.settings.broker.fableCampaign)
        XCTAssertEqual(model.settings.broker.effectivePolicy(now: Date()).thresholds.weeklyPct, 71)
        XCTAssertEqual(model.settings.broker.fableResets["account-a"]?.count, 1)
        XCTAssertEqual(model.settings.broker.isEnabled, before.broker.isEnabled)
    }

    func testFreshNaturalResetPrunesOldAdviceAndRejectsItsAction() throws {
        var state = inventory()
        let notice = try XCTUnwrap(state.observe(evidence(), now: now, active: true).first { $0.kind == .redeem })
        let later = now.addingTimeInterval(3 * 86400)
        _ = state.observe(evidence(0, at: later, reset: later.addingTimeInterval(7 * 86400)), now: later, active: true)
        XCTAssertFalse(state.notices.contains { $0.id == notice.id })
        XCTAssertFalse(state.redeemed(id: notice.id, now: later))
        XCTAssertEqual(state.count, 3)
    }
    func testMissingFreshDataPrunesAdviceAndFreshRecoveryRestoresWithoutRenotifying() throws {
        var state = inventory()
        _ = state.observe(evidence(), now: now, active: true)
        _ = state.observe(nil, now: now, active: true)
        XCTAssertFalse(state.notices.contains { $0.kind == .redeem })
        XCTAssertTrue(state.observe(evidence(), now: now, active: true).isEmpty)
        XCTAssertTrue(state.notices.contains { $0.kind == .redeem })
    }
    func testSmallUsageAndResetJitterDoNotClaimExternalRedemption() {
        var state = inventory()
        _ = state.observe(evidence(), now: now, active: true)
        let later = now.addingTimeInterval(60)
        let result = state.observe(evidence(93, at: later, reset: now.addingTimeInterval(3 * 86400 - 1)), now: later, active: true)
        XCTAssertFalse(result.contains { $0.kind == .external })
    }
    func testMalformedAccountDoesNotDropValidInventoryAndOldFieldsDefault() throws {
        let original = inventory()
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["generation", "delivered", "corrections", "notices", "events", "expiryProvenance"] { encoded.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: ["fable_resets": ["good": encoded, "broken": false]])
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)
        XCTAssertEqual(settings.fableResets["good"]?.count, original.count)
        XCTAssertEqual(settings.fableResets["good"]?.expiresAt, original.expiresAt)
        XCTAssertTrue(settings.fableResetLoadWarning)
        XCTAssertNil(settings.fableResets["broken"])
    }
    @MainActor
    func testLegacyAccountInventoryMatchesOracleAndZeroInventoryDoesNotWaive() async {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            notificationService: NotificationServiceSpy(), brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() }, t3InstanceDiscovery: T3InstanceDiscoveryFake())
        model.settings.claudeAccounts = []
        XCTAssertEqual(model.fableResetAccounts.first?.id, ClaudeAccount.primaryKeychainAccount)
        await model.editFableInventory(accountID: ClaudeAccount.primaryKeychainAccount, count: 0, expiry: Date().addingTimeInterval(86400), provenance: "Fixture")
        await model.startFableCampaign()
        XCTAssertNil(model.settings.broker.fableCampaign)
        await model.editFableInventory(accountID: ClaudeAccount.primaryKeychainAccount, count: 1, expiry: Date().addingTimeInterval(86400), provenance: "Fixture")
        await model.startFableCampaign()
        XCTAssertNotNil(model.settings.broker.fableCampaign?.accountDeadlines[ClaudeAccount.primaryKeychainAccount])
    }

    func testExternalAdviceRecoversOnceAfterMissingDataAndDoesNotRepeatAfterConfirmation() throws {
        var state = inventory()
        _ = state.observe(evidence(), now: now, active: true)
        let later = now.addingTimeInterval(60)
        _ = state.observe(evidence(0, at: later), now: later, active: true)
        _ = state.observe(nil, now: later, active: true)
        XCTAssertFalse(state.notices.contains { $0.kind == .external })
        XCTAssertTrue(state.observe(evidence(0, at: later), now: later, active: true).isEmpty)
        let notice = try XCTUnwrap(state.notices.first { $0.kind == .external })
        XCTAssertTrue(state.redeemed(id: notice.id, now: later))
        _ = state.observe(evidence(0, at: later.addingTimeInterval(1)), now: later.addingTimeInterval(1), active: true)
        XCTAssertFalse(state.observe(evidence(0, at: later.addingTimeInterval(2)), now: later.addingTimeInterval(2), active: true).contains { $0.kind == .external })
    }

}
