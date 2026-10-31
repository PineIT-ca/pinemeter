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
    func test_hostLoginResponseRouting() throws {
        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.object(forKey: BrokerWindowView.paneDefaultsKey)
        defer { defaults.set(previous, forKey: BrokerWindowView.paneDefaultsKey) }
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: NotificationCenterSpy())
        let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let valid: [AnyHashable: Any] = ["host_id": hostID.uuidString, "provider": "chatgpt", "account_id": "user-fixture"]
        var requests: [HostLoginRequest] = []
        var opened = 0
        var panes: [[String: String]] = []
        let login = NotificationCenter.default.addObserver(forName: .startHostLogin, object: nil, queue: nil) {
            if let request = $0.object as? HostLoginRequest { requests.append(request) }
        }
        let open = NotificationCenter.default.addObserver(forName: .openBrokerSettings, object: nil, queue: nil) { _ in opened += 1 }
        let pane = NotificationCenter.default.addObserver(forName: .showBrokerPane, object: nil, queue: nil) {
            panes.append($0.userInfo as? [String: String] ?? [:])
        }
        defer {
            for observer in [login, open, pane] { NotificationCenter.default.removeObserver(observer) }
        }
        service.handleNotificationResponse(categoryIdentifier: "remote.hostLogin", actionIdentifier: "remote.hostLogin.relogin", userInfo: valid)
        XCTAssertEqual(requests, [HostLoginRequest(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")])
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(panes.isEmpty)
        service.handleNotificationResponse(categoryIdentifier: "remote.hostLogin", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: valid)
        var invalid: [[AnyHashable: Any]] = []
        for (key, value) in [("host_id", "FAKE-invalid-uuid"), ("provider", "gemini"), ("account_id", "x'; id; '"), ("account_id", "legacy-chatgpt"), ("host_name", "host.example.com")] {
            var payload = valid
            payload[key] = value
            invalid.append(payload)
        }
        var missing = valid
        missing.removeValue(forKey: "account_id")
        invalid.append(missing)
        for key in ["host_id", "provider", "account_id"] {
            var payload = valid
            payload[key] = 42
            invalid.append(payload)
        }
        for payload in invalid {
            XCTAssertNil(HostLoginRequest(userInfo: payload))
            service.handleNotificationResponse(categoryIdentifier: "remote.hostLogin", actionIdentifier: "remote.hostLogin.relogin", userInfo: payload)
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(opened, 1 + invalid.count)
        XCTAssertEqual(panes, Array(repeating: ["pane": "remoteHosts"], count: 1 + invalid.count))
        XCTAssertEqual(defaults.string(forKey: BrokerWindowView.paneDefaultsKey), "remoteHosts")
    }

    func test_hostLoginPayloadRoundTrips() async throws {
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: center)
        let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        for (provider, account) in [(HostLoginProvider.chatgpt, "user-fixture"), (.claude, "00000000-0000-4000-8000-000000000003")] {
            let alert = HostLoginAlert(key: "\(provider.rawValue)|\(account)|expired", provider: provider,
                                      accountID: account, accountLabel: "Fixture Account", cause: .expired)
            let delivered = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
            XCTAssertTrue(delivered)
            let request = try XCTUnwrap(center.addedRequests.last)
            XCTAssertEqual(HostLoginRequest(userInfo: request.content.userInfo),
                           HostLoginRequest(hostID: hostID, provider: provider, accountID: account))
        }
    }

    func test_setupRegistersHostLoginCategory() throws {
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: center)
        service.setupDelegate()
        let category = try XCTUnwrap(center.categories.first { $0.identifier == "remote.hostLogin" })
        XCTAssertEqual(category.actions.map(\.identifier), ["remote.hostLogin.relogin"])
        XCTAssertEqual(category.actions.map(\.title), ["Log in again"])
        XCTAssertTrue(category.actions[0].options.contains(.foreground))
        XCTAssertTrue(center.categories.contains { $0.identifier == "broker.routingUpdate" })
    }

    func test_hostLoginAlertContentForEachCause() async throws {
        let repository = SettingsRepositoryFake()
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: repository, notificationCenter: center)
        let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let expiresAt = Date(timeIntervalSince1970: 1_793_361_600)
        let cases: [(HostLoginAlertCause, String, String, String)] = [
            (.expired, "expired", "Host login needs attention",
             "has expired. Choose Log in again to sign in on the host."),
            (.challenged, "challenged", "Host login needs attention",
             "is blocked by a provider check. Choose Log in again to sign in on the host."),
            (.refreshFailed, "refresh_failed", "Host login needs attention",
             "has failed to refresh for more than 24 hours. Choose Log in again to sign in on the host."),
            (.expiryWarning(expiresAt: expiresAt), "expiry|2026-10-30", "Host login expires soon",
             "expires \(expiresAt.formatted(date: .abbreviated, time: .shortened)). Log in again before then."),
        ]
        for (provider, name) in [(HostLoginProvider.claude, "Claude"), (.chatgpt, "Codex")] {
            let accountID = provider == .claude ? "00000000-0000-4000-8000-000000000003" : "user-fixture"
            for (cause, token, title, suffix) in cases {
                let key = "\(provider.rawValue)|\(accountID)|\(token)"
                let alert = HostLoginAlert(key: key, provider: provider, accountID: accountID,
                                           accountLabel: "Fixture Account", cause: cause)
                let delivered = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
                XCTAssertTrue(delivered)
                let request = try XCTUnwrap(center.addedRequests.last)
                XCTAssertEqual(request.identifier, "host-login.00000000-0000-4000-8000-000000000002.\(key)")
                XCTAssertEqual(request.content.categoryIdentifier, "remote.hostLogin")
                XCTAssertEqual(request.content.title, title)
                XCTAssertEqual(request.content.body, "\(name) login \"Fixture Account\" on host.example.com \(suffix)")
                XCTAssertNotNil(request.content.sound)
                XCTAssertNil(request.trigger)
                XCTAssertEqual(Set(request.content.userInfo.keys),
                               ["host_id", "provider", "account_id"])
                XCTAssertEqual(request.content.userInfo["host_id"] as? String, hostID.uuidString)
                XCTAssertEqual(request.content.userInfo["provider"] as? String, provider.rawValue)
                XCTAssertEqual(request.content.userInfo["account_id"] as? String, accountID)
            }
        }
        XCTAssertEqual(center.addedRequests.count, 8)
    }

    func test_nonLoginableHostAlertsHaveNoReloginActionOrInstructions() async throws {
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: center)
        service.setupDelegate()
        let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let expiresAt = Date(timeIntervalSince1970: 1_793_361_600)
        let cases: [(HostLoginAlertCause, String)] = [
            (.expired, "has expired."),
            (.challenged, "is blocked by a provider check."),
            (.refreshFailed, "has failed to refresh for more than 24 hours."),
            (.expiryWarning(expiresAt: expiresAt), "expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))."),
        ]
        for (provider, accountID) in [(HostLoginProvider.chatgpt, "legacy-chatgpt"), (.chatgpt, "invalid"), (.claude, "user-fixture")] {
            for (cause, suffix) in cases {
                let alert = HostLoginAlert(key: "FAKE-alert", provider: provider, accountID: accountID,
                                           accountLabel: "Fixture Account", cause: cause)
                let delivered = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
                XCTAssertTrue(delivered)
                let content = try XCTUnwrap(center.addedRequests.last?.content)
                XCTAssertEqual(content.body, "\(provider.displayName) login \"Fixture Account\" on host.example.com \(suffix)")
                XCTAssertEqual(content.categoryIdentifier, "remote.hostLogin.info")
                let category = try XCTUnwrap(center.categories.first { $0.identifier == content.categoryIdentifier })
                XCTAssertTrue(category.actions.isEmpty)
                XCTAssertEqual(Set(content.userInfo.keys), ["host_id", "provider", "account_id"])
            }
        }
    }

    func test_nonLoginableHostAlertResponseOpensRemoteHostsPane() {
        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.object(forKey: BrokerWindowView.paneDefaultsKey)
        defer { defaults.set(previous, forKey: BrokerWindowView.paneDefaultsKey) }
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: NotificationCenterSpy())
        var pane: String?
        let observer = NotificationCenter.default.addObserver(forName: .showBrokerPane, object: nil, queue: nil) {
            pane = $0.userInfo?["pane"] as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        service.handleNotificationResponse(categoryIdentifier: "remote.hostLogin.info",
                                           actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:])
        XCTAssertEqual(pane, "remoteHosts")
    }

    func test_hostLoginAlertRespectsPermissionAndSetting() async throws {
        let repository = SettingsRepositoryFake()
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: repository, notificationCenter: center)
        let alert = HostLoginAlert(key: "claude|user-fixture|expired", provider: .claude,
                                  accountID: "user-fixture", accountLabel: "Fixture Account", cause: .expired)
        let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        center.authorizationStatus = .denied
        let denied = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
        XCTAssertFalse(denied)
        XCTAssertTrue(center.addedRequests.isEmpty)
        center.authorizationStatus = .authorized
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = false
        try await repository.save(settings)
        let disabled = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
        XCTAssertFalse(disabled)
        XCTAssertTrue(center.addedRequests.isEmpty)
        settings.hasNotificationsEnabled = true
        try await repository.save(settings)
        let allowed = try await service.sendHostLoginAlert(alert, hostID: hostID, hostName: "host.example.com")
        XCTAssertTrue(allowed)
        XCTAssertEqual(center.addedRequests.count, 1)
    }

    func test_removeHostLoginAlertsForwardsIdentifiers() {
        let center = NotificationCenterSpy()
        let service = NotificationService(settingsRepository: SettingsRepositoryFake(), notificationCenter: center)
        let identifiers = [
            "host-login.00000000-0000-4000-8000-000000000002.claude|user-fixture|expired",
            "host-login.00000000-0000-4000-8000-000000000002.chatgpt|user-fixture|challenged",
        ]
        service.removeHostLoginAlerts(identifiers: identifiers)
        service.removeHostLoginAlerts(identifiers: [])
        XCTAssertEqual(center.removedIdentifiers, [identifiers])
    }

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
            "Balanced has updated routing rules. Review and apply them in the Broker window.",
            "Balanced has updated routing rules. Review and apply them in the Broker window. 2 new presets added.",
            "1 new routing preset arrived from the manifest. Review them in the Broker window.",
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

    /// Plans without a 5-hour window alert on the weekly limit, so the text
    /// must not call it a session.
    func test_thresholdBody_namesTheTrackedWindow() {
        let reset = Date().addingTimeInterval(3600)

        XCTAssertTrue(
            UsageThresholdType.warning.body(percentage: 80, resetTime: reset)
                .contains("80% of your 5-hour session")
        )
        XCTAssertTrue(
            UsageThresholdType.critical.body(percentage: 95, resetTime: reset, window: "weekly limit")
                .contains("95% of weekly limit used")
        )
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
