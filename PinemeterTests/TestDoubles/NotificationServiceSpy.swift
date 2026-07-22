//
//  NotificationServiceSpy.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

@MainActor
final class NotificationServiceSpy: NotificationServiceProtocol {
    private(set) var lastEvaluatedUsageData: UsageData?
    var hasPermission: Bool = true
    private(set) var requestAuthorizationCallCount: Int = 0
    private(set) var sentThresholdPercentage: Double?
    private(set) var sentThresholdType: UsageThresholdType?
    private(set) var sentUpdateVersions: [String] = []

    func setupDelegate() {}

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        return true
    }

    func evaluateThresholds(usageData: UsageData, settings: AppSettings) async {
        lastEvaluatedUsageData = usageData
    }

    func sendThresholdNotification(
        percentage: Double,
        threshold: UsageThresholdType,
        resetTime: Date
    ) async throws {
        sentThresholdPercentage = percentage
        sentThresholdType = threshold
    }

    func sendResetNotification() async throws {}

    func sendUpdateAvailableNotification(version: String) async throws {
        sentUpdateVersions.append(version)
    }

    func checkNotificationPermissions() async -> Bool {
        hasPermission
    }
}
