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
        settings.menuBarColorScheme = .sunset
        settings.isChatGPTUsageShown = true

        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(loaded, settings)
    }

    func test_subscriptionResetAnnouncementModePersistsThroughFreshRepository() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        settings.refreshInterval = 600
        settings.hasNotificationsEnabled = false
        settings.menuBarColorScheme = .forest
        settings.subscriptionResetAnnouncementMode = .both

        let savingRepository = SettingsRepository(userDefaults: userDefaults)
        try await savingRepository.save(settings)

        let relaunchedRepository = SettingsRepository(userDefaults: userDefaults)
        let loaded = await relaunchedRepository.load()

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.subscriptionResetAnnouncementMode, .both)
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
        XCTAssertEqual(settings.menuBarColorScheme, .spectrum)
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

    // MARK: - T3 discovery decode compatibility (260814-pz4, R-06)

    func test_legacyT3InstancesJSON_withoutNewFields_decodesWithManualOriginAndEmptyDefaults() throws {
        let json = """
        {
          "broker": {
            "policy": {
              "t3_instances": [
                {"id": "claudeAgent", "name": "Claude Agent"},
                {"id": "codex", "name": "Codex", "base_url_override": "http://127.0.0.1:9999"}
              ]
            }
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.broker.policy.t3Instances.count, 2)
        for instance in settings.broker.policy.t3Instances {
            XCTAssertEqual(instance.origin, .manual, "a pre-discovery row must default to manual, the fail-safe origin")
            XCTAssertNil(instance.driver)
            XCTAssertEqual(instance.detectedModels, [])
            XCTAssertNil(instance.lastSeenAt)
        }
    }

    func test_unknownOriginValueOnOneRow_decodesWholePolicyWithThatRowFallingBackToManual() throws {
        let json = """
        {
          "broker": {
            "policy": {
              "t3_instances": [
                {"id": "claudeAgent", "name": "Claude Agent", "origin": "someFutureValue"},
                {"id": "codex", "name": "Codex", "origin": "detected"}
              ]
            }
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.broker.policy.t3Instances.count, 2, "an unknown origin value must not fail the whole policy decode")
        XCTAssertEqual(
            settings.broker.policy.t3Instances.first { $0.id == "claudeAgent" }?.origin, .manual
        )
        XCTAssertEqual(
            settings.broker.policy.t3Instances.first { $0.id == "codex" }?.origin, .detected
        )
    }

    func test_detectedT3InstanceRow_survivesSettingsRepositorySaveLoadRoundTrip() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        let checkedAt = Date()
        settings.broker.policy.t3Instances = [
            T3InstanceConfig(
                id: "codex",
                name: "Codex",
                origin: .detected,
                driver: "codex",
                detectedModels: ["gpt-5.6-sol", "gpt-5.6-terra"],
                lastSeenAt: checkedAt
            )
        ]

        let repository = SettingsRepository(userDefaults: userDefaults)
        try await repository.save(settings)
        let loaded = await repository.load()

        let row = try XCTUnwrap(loaded.broker.policy.t3Instances.first { $0.id == "codex" })
        XCTAssertEqual(row.origin, .detected)
        XCTAssertEqual(row.driver, "codex")
        XCTAssertEqual(row.detectedModels, ["gpt-5.6-sol", "gpt-5.6-terra"])
        let lastSeenAt = try XCTUnwrap(row.lastSeenAt)
        // SettingsRepository's `.iso8601` strategy truncates fractional
        // seconds, so the round-tripped value may be up to 1s earlier.
        XCTAssertLessThan(
            abs(lastSeenAt.timeIntervalSince1970 - checkedAt.timeIntervalSince1970), 1
        )
    }

    func test_legacyT3ConfigJSON_withoutIgnoredInstances_decodesToEmptyIgnoreList() throws {
        let json = """
        {
          "broker": {
            "policy": {
              "t3": {"instance_by_model": {}, "default_instance": "claudeAgent"}
            }
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.broker.policy.t3.ignoredInstances, [])
    }

    func test_ignoredInstances_surviveSettingsSaveLoadRoundTrip() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        settings.broker.policy.t3.ignoredInstances = ["cursor", "grok"]

        let repository = SettingsRepository(userDefaults: userDefaults)
        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(
            loaded.broker.policy.t3.ignoredInstances, ["cursor", "grok"],
            "the ignore list is what makes deleting a detected row durable across relaunches (WR-01)"
        )
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
