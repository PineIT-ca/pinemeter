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
    private(set) var evaluateThresholdsCallCount: Int = 0
    var hasPermission: Bool = true
    private(set) var requestAuthorizationCallCount: Int = 0
    private(set) var sentThresholdPercentage: Double?
    private(set) var sentThresholdType: UsageThresholdType?
    private(set) var sentUpdateVersions: [String] = []
    private(set) var sentRoutingUpdates: [RoutingUpdateNotice] = []
    private(set) var sentRecheckReasons: [InstructionRecheck.Reason] = []
    private(set) var sentRecheckNotices: [BrokerAgentSetupNotice?] = []
    struct SentHostLoginAlert: Equatable {
        let alert: HostLoginAlert
        let hostID: UUID
        let hostName: String
    }
    private(set) var sentHostLoginAlerts: [SentHostLoginAlert] = []
    private(set) var removedHostLoginIdentifiers: [[String]] = []
    var hostLoginAlertResult = true
    var beforeHostLoginAlertDelivery: (() async -> Void)?
    var hostLoginAlertError: Error?
    private(set) var sentReconnectedProviders: [CredentialProvider] = []
    var routingUpdateError: Error?
    var recheckReminderError: Error?

    func setupDelegate() {}

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        return true
    }

    func evaluateThresholds(usageData: UsageData, settings: AppSettings) async {
        evaluateThresholdsCallCount += 1
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

    func sendProviderReconnectedNotification(_ provider: CredentialProvider) async throws {
        sentReconnectedProviders.append(provider)
    }

    func sendRoutingUpdateNotification(_ update: RoutingUpdateNotice) async throws {
        if let routingUpdateError { throw routingUpdateError }
        sentRoutingUpdates.append(update)
    }

    func sendInstructionRecheckReminder(
        reason: InstructionRecheck.Reason,
        setupNotice: BrokerAgentSetupNotice?
    ) async throws {
        if let recheckReminderError { throw recheckReminderError }
        sentRecheckReasons.append(reason)
        sentRecheckNotices.append(setupNotice)
    }

    @discardableResult
    func sendHostLoginAlert(_ alert: HostLoginAlert, hostID: UUID, hostName: String) async throws -> Bool {
        if let hostLoginAlertError { throw hostLoginAlertError }
        guard hostLoginAlertResult else { return false }
        await beforeHostLoginAlertDelivery?()
        sentHostLoginAlerts.append(SentHostLoginAlert(alert: alert, hostID: hostID, hostName: hostName))
        return true
    }

    func removeHostLoginAlerts(identifiers: [String]) {
        removedHostLoginIdentifiers.append(identifiers)
    }

    func checkNotificationPermissions() async -> Bool {
        hasPermission
    }
}
