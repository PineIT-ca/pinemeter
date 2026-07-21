//
//  SettingsRepositoryTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
@testable import Pinemeter

final class SettingsRepositoryTests: XCTestCase {
    func test_settingsPersistAcrossLaunches() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)
        defer { userDefaults?.removePersistentDomain(forName: suiteName) }

        let repository = SettingsRepository(userDefaults: userDefaults ?? .standard)
        var settings = AppSettings.default
        settings.refreshInterval = 300
        settings.hasNotificationsEnabled = false
        settings.isFirstLaunch = false
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        settings.iconStyle = .dualBar
        settings.isColoredIcon = false
        settings.isChatGPTUsageShown = true

        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(loaded, settings)
    }

    func test_settingsDecodingWithoutIsColoredIcon_usesDefault() throws {
        let data = """
        {
          "refresh_interval": 300,
          "notifications_enabled": false,
          "notification_thresholds": {
            "warning_threshold": 70,
            "critical_threshold": 90,
            "notify_on_reset": false
          },
          "is_first_launch": false,
          "cached_organization_id": null,
          "show_sonnet_usage": true,
          "icon_style": "dual_bar"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.isColoredIcon)
        XCTAssertTrue(settings.isFableUsageShown)
    }

    func test_defaultSettings_hideChatGPTUsage() {
        XCTAssertFalse(AppSettings.default.isChatGPTUsageShown)
    }

    func test_loadingLegacyPayloadWithCredentialShapedKeysDropsCredentialMaterialOnSave() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let legacyPayload = """
        {
          "refresh_interval": 300,
          "notifications_enabled": false,
          "notification_thresholds": {
            "warning_threshold": 70,
            "critical_threshold": 90,
            "notify_on_reset": false
          },
          "is_first_launch": false,
          "cached_organization_id": null,
          "show_sonnet_usage": true,
          "show_chatgpt_usage": true,
          "icon_style": "dual_bar",
          "is_colored_icon": false,
          "credential_state": "valid",
          "session_key": "sk-ant-test-synthetic-session-key",
          "session_cookie": "__Secure-next-auth.session-token=synthetic-cookie",
          "access_token": "Bearer synthetic-access-token"
        }
        """.data(using: .utf8)!
        userDefaults.set(legacyPayload, forKey: "app_settings")

        let repository = SettingsRepository(userDefaults: userDefaults)
        let loaded = await repository.load()
        try await repository.save(loaded)

        let persistedData = try XCTUnwrap(userDefaults.data(forKey: "app_settings"))
        let persistedPayload = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
        let forbiddenFragments = [
            "credential_state",
            "session_key",
            "session_cookie",
            "access_token",
            "sk-ant-test-synthetic-session-key",
            "__Secure-next-auth.session-token=synthetic-cookie",
            "Bearer synthetic-access-token"
        ]

        for forbiddenFragment in forbiddenFragments {
            XCTAssertFalse(
                persistedPayload.contains(forbiddenFragment),
                "SettingsRepository must drop credential-shaped legacy payload fragments when re-saving AppSettings: \(forbiddenFragment)"
            )
        }
    }

    func test_notificationStatePersistsAcrossLaunches() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)
        defer { userDefaults?.removePersistentDomain(forName: suiteName) }

        let repository = SettingsRepository(userDefaults: userDefaults ?? .standard)
        var state = NotificationState()
        state.hasWarningBeenNotified = true
        state.hasCriticalBeenNotified = true
        state.lastPercentage = 85

        try await repository.saveNotificationState(state)
        let loaded = await repository.loadNotificationState()

        XCTAssertEqual(loaded, state)
    }
}
