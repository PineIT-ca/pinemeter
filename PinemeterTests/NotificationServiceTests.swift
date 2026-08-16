//
//  NotificationServiceTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
@testable import Pinemeter

@MainActor
final class NotificationServiceTests: XCTestCase {
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
