import Foundation
import XCTest
@testable import Pinemeter

final class FableCampaignStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let locale = Locale(identifier: "en_CA")

    private func pick(_ offset: TimeInterval, role: String, candidate: String) -> RecentPick {
        RecentPick(
            timestamp: now.addingTimeInterval(offset), role: role, caller: "claude-code",
            candidate: candidate, route: "native", degraded: false, reason: "top of chain"
        )
    }

    private func campaign(expiresIn seconds: TimeInterval) -> FableCampaign {
        FableCampaign(expiresAt: now.addingTimeInterval(seconds), accountDeadlines: [:])
    }

    func testStoppedHasNoEvidenceAndExplainsStart() {
        let status = FableCampaignStatus(
            campaign: nil, startedAt: now, picks: [pick(1, role: "review", candidate: "native/claude-fable-5-2")], now: now
        )
        XCTAssertEqual(status.state, .stopped)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.runningUntil)
        XCTAssertNil(status.evidence)
        XCTAssertNil(status.pickCountText)
        XCTAssertNil(status.latestPickText)
        XCTAssertEqual(status.headline, "Stopped")
        XCTAssertEqual(
            status.detail(timeZone: utc, locale: locale),
            "Start puts Fable 5.2 first in every role until the last reset waiver ends."
        )
    }

    func testRunningUntilTheDeadlineThenExpired() {
        let saved = campaign(expiresIn: 60)
        let running = FableCampaignStatus(campaign: saved, startedAt: now, picks: [], now: now.addingTimeInterval(59))
        XCTAssertEqual(running.state, .running(until: saved.expiresAt))
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.runningUntil, saved.expiresAt)
        XCTAssertEqual(running.headline, "Running")

        // The deadline itself is already expired, as in `FableCampaign.applying`.
        let expired = FableCampaignStatus(
            campaign: saved, startedAt: now,
            picks: [pick(1, role: "review", candidate: "native/claude-fable-5-2")],
            now: saved.expiresAt
        )
        XCTAssertEqual(expired.state, .expired(at: saved.expiresAt))
        XCTAssertFalse(expired.isRunning)
        XCTAssertNil(expired.runningUntil)
        XCTAssertNil(expired.evidence)
        XCTAssertNil(expired.pickCountText)
        XCTAssertEqual(expired.headline, "Expired")
    }

    func testStatusAgreesWithTheRoutingOverlayAtEveryInstant() {
        var settings = BrokerSettings.default
        settings.fableCampaign = campaign(expiresIn: 60)
        for offset in [-1.0, 0, 59, 60, 61] {
            let at = now.addingTimeInterval(offset)
            let overlayApplied = settings.effectivePolicy(now: at) != settings.policy
            XCTAssertEqual(
                FableCampaignStatus(campaign: settings.fableCampaign, startedAt: nil, picks: [], now: at).isRunning,
                overlayApplied, "offset \(offset)"
            )
        }
    }

    func testNonFiniteDeadlineIsNotRunning() {
        let saved = FableCampaign(expiresAt: Date(timeIntervalSince1970: .infinity), accountDeadlines: [:])
        XCTAssertFalse(FableCampaignStatus(campaign: saved, startedAt: nil, picks: [], now: now).isRunning)
    }

    func testCountsOnlyPicksAfterStartAndReportsTheLatest() {
        let picks = [
            // Newest first, as the broker serves them.
            pick(300, role: "execution", candidate: "t3/gpt-6.1-sol"),
            pick(200, role: "standard", candidate: "t3/claudeAgent/claude-fable-5-2"),
            pick(100, role: "review", candidate: "native/claude-fable-5-2"),
            pick(0, role: "explore", candidate: "native/claude-fable-5-2"),
            pick(-1, role: "planning", candidate: "native/claude-fable-5-2"),
            pick(-500, role: "heavy", candidate: "native/claude-fable-5-2"),
        ]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: now, picks: picks, now: now.addingTimeInterval(400))
        XCTAssertEqual(status.evidence, FableCampaignStatus.Evidence(
            fablePicks: 3, totalPicks: 4, latestRole: "execution", latestModel: "gpt-6.1-sol", sinceStart: true
        ))
        XCTAssertEqual(status.pickCountText, "3 of 4 recent picks went to Fable 5.2 since Start")
        XCTAssertEqual(status.latestPickText, "Latest pick: execution, gpt-6.1-sol")
    }

    func testLatestPickDoesNotDependOnListOrder() {
        let picks = [
            pick(10, role: "review", candidate: "native/claude-fable-5-2"),
            pick(30, role: "standard", candidate: "native/claude-fable-5-2"),
            pick(20, role: "execution", candidate: "t3/gpt-6.1-sol"),
        ]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: now, picks: picks, now: now.addingTimeInterval(40))
        XCTAssertEqual(status.evidence?.latestRole, "standard")
        XCTAssertEqual(status.evidence?.latestModel, FableCampaign.model)
    }

    func testOtherFableModelsAreNotCountedAsCampaignPicks() {
        let picks = [
            pick(10, role: "review", candidate: "native/claude-fable-5"),
            pick(20, role: "review", candidate: "native/claude-fable-5-2-preview"),
        ]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: now, picks: picks, now: now.addingTimeInterval(40))
        XCTAssertEqual(status.evidence?.fablePicks, 0)
        XCTAssertEqual(status.evidence?.totalPicks, 2)
    }

    func testInstanceQualifiedCandidateCountsAsFable() {
        XCTAssertEqual(FableCampaignStatus.model(of: "t3:claudeAgent/claude-fable-5-2"), FableCampaign.model)
        let picks = [
            pick(10, role: "execution", candidate: "t3:claudeAgent/claude-fable-5-2"),
            pick(20, role: "review", candidate: "t3:claudeAgent/gpt-6.1-sol"),
        ]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: now, picks: picks, now: now.addingTimeInterval(40))
        XCTAssertEqual(status.evidence?.fablePicks, 1)
        XCTAssertEqual(status.evidence?.totalPicks, 2)
    }

    func testExpiredWithPlaceholderDeadlinePrintsNoDate() {
        for placeholder in [Date.distantPast, FableCampaignStatus.earliestPrintableDeadline] {
            let status = FableCampaignStatus(
                campaign: FableCampaign(expiresAt: placeholder, accountDeadlines: [:]), startedAt: nil, picks: [], now: now
            )
            XCTAssertEqual(status.state, .expired(at: placeholder))
            XCTAssertEqual(
                status.detail(timeZone: utc, locale: locale),
                "No eligible resets remain. Routing is back to the base rules."
            )
        }
        let real = FableCampaignStatus(campaign: campaign(expiresIn: -60), startedAt: nil, picks: [], now: now)
        let text = real.detail(timeZone: utc, locale: locale)
        XCTAssertTrue(text.hasPrefix("Ended "), text)
        XCTAssertTrue(text.hasSuffix(". Routing is back to the base rules."), text)
        XCTAssertTrue(text.contains("2027"), text)
    }

    func testNoPicksSinceStart() {
        let picks = [pick(-5, role: "review", candidate: "native/claude-fable-5-2")]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: now, picks: picks, now: now.addingTimeInterval(1))
        XCTAssertEqual(status.evidence?.totalPicks, 0)
        XCTAssertEqual(status.pickCountText, "No picks yet since Start")
        XCTAssertNil(status.latestPickText)
    }

    func testUnknownStartCountsEveryHeldPickAndSaysSo() {
        let picks = [pick(-5, role: "review", candidate: "native/claude-fable-5-2")]
        let status = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: nil, picks: picks, now: now)
        XCTAssertEqual(status.evidence?.fablePicks, 1)
        XCTAssertEqual(status.evidence?.sinceStart, false)
        XCTAssertEqual(status.pickCountText, "1 of 1 recent pick went to Fable 5.2 since Pinemeter launched")
        let none = FableCampaignStatus(campaign: campaign(expiresIn: 3600), startedAt: nil, picks: [], now: now)
        XCTAssertEqual(none.pickCountText, "No picks yet since Pinemeter launched")
    }

    func testDateTextFollowsTheGivenTimeZone() {
        // 2027-01-15 03:30 UTC is still 14 January eight hours west. A fixed offset keeps tzdata rule changes out of the test.
        let date = Date(timeIntervalSince1970: 1_799_983_800)
        let inUTC = FableCampaignStatus.dateText(date, timeZone: utc, locale: locale)
        let eightWest = FableCampaignStatus.dateText(date, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!, locale: locale)
        XCTAssertTrue(inUTC.contains("15"), inUTC)
        XCTAssertTrue(inUTC.contains("3:30"), inUTC)
        XCTAssertTrue(eightWest.contains("14"), eightWest)
        XCTAssertTrue(eightWest.contains("7:30"), eightWest)
        XCTAssertNotEqual(inUTC, eightWest)
        let running = FableCampaignStatus(
            campaign: FableCampaign(expiresAt: date, accountDeadlines: [:]), startedAt: nil, picks: [],
            now: date.addingTimeInterval(-60)
        )
        XCTAssertEqual(running.detail(timeZone: utc, locale: locale), "Until \(inUTC)")
    }

    @MainActor
    func testStartRecordsARuntimeStartTimeAndStopClearsIt() async throws {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            notificationService: NotificationServiceSpy(), brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() }, t3InstanceDiscovery: T3InstanceDiscoveryFake())
        XCTAssertFalse(model.fableCampaignStatus().isRunning)
        await model.editFableInventory(accountID: "account-a", count: 1, expiry: Date().addingTimeInterval(86_400), provenance: "Fixture UTC")
        let before = Date()
        await model.startFableCampaign()
        XCTAssertTrue(model.fableCampaignStatus().isRunning)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.fableCampaignStartedAt), before)
        await model.stopFableCampaign()
        XCTAssertNil(model.fableCampaignStartedAt)
        XCTAssertEqual(model.fableCampaignStatus().state, .stopped)
    }

    @MainActor
    func testInventoryEditThatRevivesAnExpiredCampaignSetsTheStartTime() async throws {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            notificationService: NotificationServiceSpy(), brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() }, t3InstanceDiscovery: T3InstanceDiscoveryFake())
        let expiry = Date().addingTimeInterval(86_400)
        await model.editFableInventory(accountID: "account-a", count: 1, expiry: expiry, provenance: "Fixture UTC")
        await model.startFableCampaign()
        // A relaunch: the saved campaign survives, the runtime start time does not.
        model.fableCampaignStartedAt = nil

        // An edit that keeps the campaign running leaves the start unknown.
        await model.editFableInventory(accountID: "account-a", count: 2, expiry: expiry.addingTimeInterval(3600), provenance: "Fixture UTC")
        XCTAssertTrue(model.fableCampaignStatus().isRunning)
        XCTAssertNil(model.fableCampaignStartedAt)

        // No eligible reset: the campaign stays saved but no longer applies.
        await model.editFableInventory(accountID: "account-a", count: 0, expiry: expiry, provenance: "Fixture UTC")
        XCTAssertEqual(model.fableCampaignStatus().state, .expired(at: .distantPast))
        XCTAssertNil(model.fableCampaignStartedAt)

        let revived = Date()
        await model.editFableInventory(accountID: "account-a", count: 1, expiry: expiry, provenance: "Fixture UTC")
        XCTAssertTrue(model.fableCampaignStatus().isRunning)
        let started = try XCTUnwrap(model.fableCampaignStartedAt)
        XCTAssertGreaterThanOrEqual(started, revived)

        // Picks made under the base rules before the revival are not evidence.
        let before = RecentPick(
            timestamp: revived.addingTimeInterval(-60), role: "review", caller: "claude-code",
            candidate: "native/claude-fable-5-2", route: "native", degraded: false, reason: "top of chain"
        )
        XCTAssertEqual(model.fableCampaignStatus(picks: [before]).pickCountText, "No picks yet since Start")
    }
}
