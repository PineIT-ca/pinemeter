//
//  NotificationServiceTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
import UserNotifications
@testable import Pinemeter

@MainActor
final class NotificationServiceTests: XCTestCase {
    func test_setupRegistersRoutingUpdateActions() throws {
        let center = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: SettingsRepositoryFake(),
            notificationCenter: center
        )

        service.setupDelegate()

        let category = try XCTUnwrap(center.categories.first {
            $0.identifier == "broker.routingUpdate"
        })
        XCTAssertEqual(category.actions.map(\.identifier), [
            "broker.routingUpdate.apply", "broker.routingUpdate.review",
        ])
        XCTAssertEqual(category.actions.map(\.title), ["Apply", "Review"])
    }

    func test_routingUpdateNotificationContentForEachBody() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        try await settingsRepository.save(settings)
        let center = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: center
        )
        let profileID = UUID()

        try await service.sendRoutingUpdateNotification(RoutingUpdateNotice(
            profileName: "Balanced",
            newPresetCount: 0,
            profileID: profileID,
            fingerprint: "abcdefghijklmnopqrst"
        ))
        try await service.sendRoutingUpdateNotification(RoutingUpdateNotice(
            profileName: "Balanced",
            newPresetCount: 2,
            profileID: profileID,
            fingerprint: "bbbbbbbbbbbbbbbb"
        ))
        try await service.sendRoutingUpdateNotification(RoutingUpdateNotice(
            profileName: nil,
            newPresetCount: 1,
            profileID: nil,
            fingerprint: "cccccccccccccccc"
        ))

        XCTAssertEqual(center.addedRequests.map(\.content.title), [
            "Routing update available", "Routing update available", "Routing update available",
        ])
        XCTAssertEqual(center.addedRequests.map(\.content.body), [
            "Balanced has updated routing rules. Review and apply them in Broker settings.",
            "Balanced has updated routing rules. Review and apply them in Broker settings. 2 new presets added.",
            "1 new routing preset arrived from the manifest. Review them in Broker settings.",
        ])
        XCTAssertEqual(center.addedRequests.map(\.content.categoryIdentifier), [
            "broker.routingUpdate", "broker.routingUpdate", "broker.routingUpdate",
        ])
        XCTAssertEqual(center.addedRequests.map(\.identifier), [
            "routing-update.abcdefghijkl", "routing-update.bbbbbbbbbbbb", "routing-update.cccccccccccc",
        ])
        XCTAssertEqual(center.addedRequests.first?.content.userInfo["profile_id"] as? String, profileID.uuidString)
        XCTAssertTrue(center.addedRequests.last?.content.userInfo.isEmpty == true)
    }

    func test_notificationResponseRoutesApplyReviewAndOtherCategories() {
        let service = NotificationService(
            settingsRepository: SettingsRepositoryFake(),
            notificationCenter: NotificationCenterSpy()
        )
        let profileID = UUID()
        var appliedID: UUID?
        var brokerSettingsCount = 0
        var usagePopoverCount = 0
        let apply = NotificationCenter.default.addObserver(
            forName: .applyRoutingUpdate, object: nil, queue: nil
        ) { appliedID = $0.object as? UUID }
        let review = NotificationCenter.default.addObserver(
            forName: .openBrokerSettings, object: nil, queue: nil
        ) { _ in brokerSettingsCount += 1 }
        let other = NotificationCenter.default.addObserver(
            forName: .openUsagePopover, object: nil, queue: nil
        ) { _ in usagePopoverCount += 1 }
        defer {
            NotificationCenter.default.removeObserver(apply)
            NotificationCenter.default.removeObserver(review)
            NotificationCenter.default.removeObserver(other)
        }

        service.handleNotificationResponse(
            categoryIdentifier: "broker.routingUpdate",
            actionIdentifier: "broker.routingUpdate.apply",
            userInfo: ["profile_id": profileID.uuidString]
        )
        XCTAssertEqual(appliedID, profileID)

        service.handleNotificationResponse(
            categoryIdentifier: "broker.routingUpdate",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )
        service.handleNotificationResponse(
            categoryIdentifier: "broker.routingUpdate",
            actionIdentifier: "broker.routingUpdate.review",
            userInfo: [:]
        )
        service.handleNotificationResponse(
            categoryIdentifier: "broker.routingUpdate",
            actionIdentifier: "broker.routingUpdate.apply",
            userInfo: [:]
        )
        XCTAssertEqual(brokerSettingsCount, 3)

        service.handleNotificationResponse(
            categoryIdentifier: "usage.threshold",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )
        XCTAssertEqual(usagePopoverCount, 1)
    }

    func test_setupContractReminderIncludesRevisionAndSummary() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        try await settingsRepository.save(settings)
        let center = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: center
        )

        try await service.sendInstructionRecheckReminder(
            reason: .setupContractChanged,
            setupNotice: BrokerAgentSetupNotice(
                revision: 4, changedAt: nil, summary: "Roles changed."
            )
        )

        XCTAssertEqual(
            center.addedRequests.first?.content.body,
            "Agent setup instructions changed (revision 4). Run the broker's configure prompt in an agent. Roles changed."
        )
        XCTAssertEqual(
            center.addedRequests.first?.identifier,
            "instruction-recheck.setupContractChanged"
        )
    }

    func test_userReceivesWarningNotificationWhenUsageCrossesThreshold() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.warningThreshold = 75
        settings.notificationThresholds.criticalThreshold = 90

        let usageData = makeUsageData(percentage: 80)

        await service.evaluateThresholds(usageData: usageData, settings: settings)

        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
        XCTAssertEqual(notificationCenter.addedRequests.first?.content.userInfo["threshold"] as? String, "warning")
    }

    func test_userWithNotificationsDisabled_doesNotReceiveThresholdNotification() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = false
        settings.notificationThresholds.warningThreshold = 75

        let usageData = makeUsageData(percentage: 80)

        await service.evaluateThresholds(usageData: usageData, settings: settings)

        XCTAssertTrue(notificationCenter.addedRequests.isEmpty)
    }

    func test_userWithoutSystemPermission_doesNotReceiveNotification() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        notificationCenter.authorizationStatus = .denied

        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.warningThreshold = 75

        let usageData = makeUsageData(percentage: 80)

        await service.evaluateThresholds(usageData: usageData, settings: settings)

        XCTAssertTrue(notificationCenter.addedRequests.isEmpty)
    }

    func test_userDoesNotReceiveDuplicateWarningWithoutDroppingBelowThreshold() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.warningThreshold = 75
        settings.notificationThresholds.criticalThreshold = 90

        let usageData = makeUsageData(percentage: 80)

        await service.evaluateThresholds(usageData: usageData, settings: settings)
        await service.evaluateThresholds(usageData: usageData, settings: settings)

        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
    }

    func test_userCrossesCriticalThreshold_receivesCriticalNotification() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.warningThreshold = 75
        settings.notificationThresholds.criticalThreshold = 90

        let usageData = makeUsageData(percentage: 95)

        await service.evaluateThresholds(usageData: usageData, settings: settings)

        let sentCritical = notificationCenter.addedRequests.contains { request in
            request.content.userInfo["threshold"] as? String == "critical"
        }
        XCTAssertTrue(sentCritical)
    }

    func test_userReceivesWarningAgainAfterDroppingBelowThreshold() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.warningThreshold = 75
        settings.notificationThresholds.criticalThreshold = 90

        await service.evaluateThresholds(usageData: makeUsageData(percentage: 80), settings: settings)
        await service.evaluateThresholds(usageData: makeUsageData(percentage: 50), settings: settings)
        await service.evaluateThresholds(usageData: makeUsageData(percentage: 80), settings: settings)

        XCTAssertEqual(notificationCenter.addedRequests.count, 2)
    }

    func test_userReceivesResetNotificationWhenUsageResets() async {
        let settingsRepository = SettingsRepositoryFake()
        let notificationCenter = NotificationCenterSpy()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: notificationCenter
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.notificationThresholds.isNotifiedOnReset = true

        var state = NotificationState()
        state.lastPercentage = 50
        try? await settingsRepository.saveNotificationState(state)

        await service.evaluateThresholds(usageData: makeUsageData(percentage: 0), settings: settings)

        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
        XCTAssertEqual(notificationCenter.addedRequests.first?.content.categoryIdentifier, "usage.reset")
    }

    func test_warningThreshold_postsUsageAlertOverlayEvent() async {
        let service = NotificationService(
            settingsRepository: SettingsRepositoryFake(),
            notificationCenter: NotificationCenterSpy()
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true

        var received: UsageAlertPayload?
        let token = NotificationCenter.default.addObserver(forName: .usageAlert, object: nil, queue: nil) { note in
            received = note.object as? UsageAlertPayload
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await service.evaluateThresholds(usageData: makeUsageData(percentage: 80), settings: settings)

        XCTAssertEqual(received?.severity, .warning)
    }

    func test_usageAlertsDisabled_postsNoOverlayEvent() async {
        let service = NotificationService(
            settingsRepository: SettingsRepositoryFake(),
            notificationCenter: NotificationCenterSpy()
        )

        var settings = AppSettings.default
        settings.hasNotificationsEnabled = false

        var didPost = false
        let token = NotificationCenter.default.addObserver(forName: .usageAlert, object: nil, queue: nil) { _ in
            didPost = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await service.evaluateThresholds(usageData: makeUsageData(percentage: 95), settings: settings)

        XCTAssertFalse(didPost)
    }

    func test_usageReset_postsCelebrationEventWhenEnabled() async {
        let settingsRepository = SettingsRepositoryFake()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: NotificationCenterSpy()
        )

        var settings = AppSettings.default
        settings.isResetCelebrationEnabled = true

        var state = NotificationState()
        state.lastPercentage = 50
        try? await settingsRepository.saveNotificationState(state)

        let expectation = expectation(forNotification: .usageDidReset, object: nil, handler: nil)
        await service.evaluateThresholds(usageData: makeUsageData(percentage: 0), settings: settings)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_usageReset_doesNotPostCelebrationEventWhenDisabled() async {
        let settingsRepository = SettingsRepositoryFake()
        let service = NotificationService(
            settingsRepository: settingsRepository,
            notificationCenter: NotificationCenterSpy()
        )

        var settings = AppSettings.default
        settings.isResetCelebrationEnabled = false

        var state = NotificationState()
        state.lastPercentage = 50
        try? await settingsRepository.saveNotificationState(state)

        var didPost = false
        let token = NotificationCenter.default.addObserver(forName: .usageDidReset, object: nil, queue: nil) { _ in
            didPost = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await service.evaluateThresholds(usageData: makeUsageData(percentage: 0), settings: settings)
        XCTAssertFalse(didPost)
    }
}

// MARK: - Helpers

@MainActor
private func makeUsageData(percentage: Double) -> UsageData {
    let resetDate = Date().addingTimeInterval(TestConstants.oneHourInterval)
    let sessionUsage = UsageLimit(utilization: percentage, resetAt: resetDate)
    let weeklyUsage = UsageLimit(utilization: TestConstants.weeklyPercentage, resetAt: resetDate)

    return UsageData(
        sessionUsage: sessionUsage,
        weeklyUsage: weeklyUsage,
        sonnetUsage: nil,
        lastUpdated: Date()
    )
}
