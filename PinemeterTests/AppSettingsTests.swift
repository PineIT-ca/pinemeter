import XCTest
@testable import Pinemeter

final class AppSettingsTests: XCTestCase {
    func test_defaultRefreshInterval_isTenMinutes() {
        XCTAssertEqual(AppSettings.default.refreshInterval, 600)
    }

    func test_setRefreshInterval_clampsBelowMinimumToRefreshMinimum() {
        var settings = AppSettings.default

        settings.setRefreshInterval(Constants.Refresh.minimum - 1)

        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.minimum)
    }

    func test_setRefreshInterval_clampsAboveMaximumToRefreshMaximum() {
        var settings = AppSettings.default

        settings.setRefreshInterval(Constants.Refresh.maximum + 1)

        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.maximum)
    }

    func test_setRefreshInterval_keepsInRangeValue() {
        var settings = AppSettings.default
        let inRangeInterval = (Constants.Refresh.minimum + Constants.Refresh.maximum) / 2

        settings.setRefreshInterval(inRangeInterval)

        XCTAssertEqual(settings.refreshInterval, inRangeInterval)
    }

    func test_setRefreshInterval_clampsNonFiniteValues() {
        var settings = AppSettings.default

        settings.setRefreshInterval(.infinity)
        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.maximum)
        settings.setRefreshInterval(-.infinity)
        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.minimum)
        settings.setRefreshInterval(.nan)
        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.minimum)
    }

    func test_decodingOutOfRangeRefreshIntervals_clampsSafely() throws {
        let cases: [(String, TimeInterval)] = [
            ("0", Constants.Refresh.minimum),
            ("-1", Constants.Refresh.minimum),
            ("1e300", Constants.Refresh.maximum),
        ]

        for (value, expected) in cases {
            let settings = try JSONDecoder().decode(
                AppSettings.self,
                from: Data(#"{"refresh_interval":\#(value)}"#.utf8)
            )
            XCTAssertEqual(settings.refreshInterval, expected)
        }
    }

    func test_decodingNonFiniteRefreshIntervals_clampsSafely() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        for (value, expected) in [
            ("Infinity", Constants.Refresh.maximum),
            ("-Infinity", Constants.Refresh.minimum),
            ("NaN", Constants.Refresh.minimum),
        ] {
            let settings = try decoder.decode(
                AppSettings.self,
                from: Data(#"{"refresh_interval":"\#(value)"}"#.utf8)
            )
            XCTAssertEqual(settings.refreshInterval, expected)
        }
    }

    func test_decodingLegacySettingsWithoutNewKeys_usesSafeDefaults() throws {
        // A settings blob saved before the provider-label and reset-celebration
        // keys existed must still decode, defaulting the new fields.
        let legacyJSON = """
        {
            "refresh_interval": 300,
            "notifications_enabled": true,
            "is_first_launch": false,
            "show_sonnet_usage": false,
            "show_chatgpt_usage": false
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(settings.chatGPTCustomLabel)
        XCTAssertNil(settings.geminiCustomLabel)
        XCTAssertNil(settings.codexWorkspaceAccountIdOverride)
        XCTAssertTrue(settings.isFableUsageShown)
        XCTAssertTrue(settings.isChatGPTSparkUsageShown)
        XCTAssertTrue(settings.isChatGPTReserveUsageShown)
        XCTAssertTrue(settings.isResetCelebrationEnabled)
        XCTAssertTrue(settings.scanExcludedAccounts.isEmpty)
        XCTAssertNil(settings.lastUpdateCheckAt)
        XCTAssertNil(settings.lastNotifiedUpdateVersion)
        XCTAssertNil(settings.availableUpdateVersion)
        XCTAssertEqual(settings.subscriptionResetAnnouncementMode, .timeRemaining)
        XCTAssertFalse(settings.includeBetaUpdates)
    }

    func test_chatGPTQuotaDisplaySettings_roundTripAndFilterOnlySelectedRows() throws {
        var settings = AppSettings.default
        settings.isChatGPTSparkUsageShown = false
        settings.isChatGPTReserveUsageShown = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        let rows = [
            ChatGPTUsageData.LimitRow(label: "Codex weekly", usedPercent: 1, resetAt: nil, sourceLabel: "rate_limit"),
            ChatGPTUsageData.LimitRow(label: "Spark 5h", usedPercent: 2, resetAt: nil, sourceLabel: "GPT-Codex-Spark", menuBarRole: .chatGPTCodexSpark),
            ChatGPTUsageData.LimitRow(label: "Spark weekly", usedPercent: 3, resetAt: nil, sourceLabel: "GPT-Codex-Spark.secondary_window"),
            ChatGPTUsageData.LimitRow(label: "GPT Reserve", usedPercent: 4, resetAt: nil, sourceLabel: "gpt-reserve"),
        ]

        XCTAssertFalse(decoded.isChatGPTSparkUsageShown)
        XCTAssertFalse(decoded.isChatGPTReserveUsageShown)
        XCTAssertEqual(rows.filter(decoded.isChatGPTRowShown).map(\.sourceLabel), ["rate_limit"])
    }

    func test_includeBetaUpdates_roundTripsThroughSettingsRepository() async throws {
        let suiteName = "AppSettingsTests.betaUpdates.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let repository = SettingsRepository(userDefaults: userDefaults)

        var settings = AppSettings.default
        settings.includeBetaUpdates = true

        try await repository.save(settings)

        let loaded = await SettingsRepository(userDefaults: userDefaults).load()
        XCTAssertTrue(loaded.includeBetaUpdates)
    }

    @MainActor
    func test_appUpdaterBetaPreference_startsOnceAndTracksAllowedChannels() {
        var startCount = 0
        var resetCount = 0
        let updater = AppUpdater(
            startUpdater: { startCount += 1 },
            resetUpdateCycle: { resetCount += 1 }
        )

        XCTAssertEqual(updater.allowedChannels, [])
        updater.start()
        updater.start()
        XCTAssertEqual(startCount, 1)
        updater.setBetaUpdatesEnabled(false)
        XCTAssertEqual(resetCount, 0)

        updater.setBetaUpdatesEnabled(true)
        XCTAssertEqual(updater.allowedChannels, ["beta"])
        XCTAssertEqual(resetCount, 1)
        updater.setBetaUpdatesEnabled(true)
        XCTAssertEqual(resetCount, 1)

        updater.setBetaUpdatesEnabled(false)
        XCTAssertEqual(updater.allowedChannels, [])
        XCTAssertEqual(resetCount, 2)
        updater.setBetaUpdatesEnabled(false)
        XCTAssertEqual(resetCount, 2)

        updater.setBetaUpdatesEnabled(true)
        XCTAssertEqual(updater.allowedChannels, ["beta"])
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resetCount, 3)
    }

    func test_decodingUnknownSubscriptionResetAnnouncementMode_preservesOtherSettings() throws {
        let json = """
        {
            "refresh_interval": 600,
            "notifications_enabled": false,
            "is_first_launch": false,
            "show_chatgpt_usage": true,
            "subscription_reset_announcement_mode": "future_mode"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.refreshInterval, 600)
        XCTAssertFalse(settings.hasNotificationsEnabled)
        XCTAssertFalse(settings.isFirstLaunch)
        XCTAssertTrue(settings.isChatGPTUsageShown)
        XCTAssertEqual(settings.subscriptionResetAnnouncementMode, .timeRemaining)
    }

    func test_subscriptionResetAnnouncementModes_roundTripAndFormatResetText() throws {
        let now = Date(timeIntervalSince1970: 1_786_384_800)
        let resetAt = now.addingTimeInterval(90 * 60)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.allCases.map(\.rawValue),
            ["local_reset_time", "time_remaining", "both"]
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.allCases.map(\.title),
            ["Local Reset Time", "Time Remaining", "Both"]
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.localResetTime.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Mon at 7:30pm"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.timeRemaining.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "in 1h 30m"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.both.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Mon at 7:30pm\nin 1h 30m"
        )

        for mode in SubscriptionResetAnnouncementMode.allCases {
            var settings = AppSettings.default
            settings.subscriptionResetAnnouncementMode = mode

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.subscriptionResetAnnouncementMode, mode)
        }
    }

    func test_encodeDecodeRoundTrip_preservesNewLabelAndCelebrationFields() throws {
        var settings = AppSettings.default
        settings.chatGPTCustomLabel = "Work GPT"
        settings.geminiCustomLabel = "Personal Gemini"
        settings.isFableUsageShown = false
        settings.isResetCelebrationEnabled = false
        settings.scanExcludedAccounts = [
            ScanExcludedAccount(provider: .claude, accountId: "org-1", displayLabel: "Old account")
        ]
        settings.lastUpdateCheckAt = Date(timeIntervalSince1970: 1_700_000_000)
        settings.lastNotifiedUpdateVersion = "1.2.3"
        settings.availableUpdateVersion = "1.3.0"
        settings.subscriptionResetAnnouncementMode = .both

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.chatGPTCustomLabel, "Work GPT")
        XCTAssertEqual(decoded.geminiCustomLabel, "Personal Gemini")
        XCTAssertFalse(decoded.isFableUsageShown)
        XCTAssertFalse(decoded.isResetCelebrationEnabled)
        XCTAssertEqual(decoded.scanExcludedAccounts, settings.scanExcludedAccounts)
        XCTAssertEqual(decoded.lastUpdateCheckAt, settings.lastUpdateCheckAt)
        XCTAssertEqual(decoded.lastNotifiedUpdateVersion, "1.2.3")
        XCTAssertEqual(decoded.availableUpdateVersion, "1.3.0")
        XCTAssertEqual(decoded.subscriptionResetAnnouncementMode, .both)
    }

    /// pinemeter-private#126/#127: the manual Codex workspace override must
    /// survive an encode/decode round trip (via `SettingsRepository`'s
    /// underlying `AppSettings` Codable conformance) both when set and when
    /// left nil, and a settings blob saved before this key existed must
    /// still decode with it defaulting to nil.
    func test_encodeDecodeRoundTrip_preservesCodexWorkspaceAccountIdOverride() throws {
        var settings = AppSettings.default
        settings.codexWorkspaceAccountIdOverride = "00000000-0000-0000-0000-000000000009"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.codexWorkspaceAccountIdOverride, "00000000-0000-0000-0000-000000000009")

        var clearedSettings = AppSettings.default
        clearedSettings.codexWorkspaceAccountIdOverride = nil
        let clearedData = try JSONEncoder().encode(clearedSettings)
        let clearedDecoded = try JSONDecoder().decode(AppSettings.self, from: clearedData)

        XCTAssertNil(clearedDecoded.codexWorkspaceAccountIdOverride)

        let legacyJSON = """
        {
            "refresh_interval": 300,
            "notifications_enabled": true,
            "is_first_launch": false,
            "show_chatgpt_usage": false
        }
        """
        let legacyDecoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacyDecoded.codexWorkspaceAccountIdOverride)
    }

    // MARK: - Broker settings decode-safety (07-04, D-04, D-07, ACC-4)

    func test_decodingPreBrokerSettings_defaultsBrokerToBundledPolicy() throws {
        // A settings blob saved before the broker key existed (i.e. a
        // pre-phase-07 save) must still decode, with settings.broker
        // defaulting to BrokerSettings.default (the bundled policy seed).
        let preBrokerJSON = """
        {
            "refresh_interval": 300,
            "notifications_enabled": true,
            "is_first_launch": false,
            "show_chatgpt_usage": false
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(preBrokerJSON.utf8))

        XCTAssertEqual(settings.broker, BrokerSettings.default)
    }

    func test_prePhase8SettingsDecodeWithoutTelemetryConfiguration() throws {
        let prePhase8JSON = """
        {
            "refresh_interval": 300,
            "notifications_enabled": false,
            "is_first_launch": false,
            "show_fable_usage": false,
            "show_chatgpt_usage": true,
            "broker": {
                "is_enabled": true,
                "port": 43117
            }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(prePhase8JSON.utf8))

        XCTAssertEqual(settings.refreshInterval, 300)
        XCTAssertFalse(settings.hasNotificationsEnabled)
        XCTAssertFalse(settings.isFirstLaunch)
        XCTAssertFalse(settings.isFableUsageShown)
        XCTAssertTrue(settings.isChatGPTUsageShown)
        XCTAssertTrue(settings.broker.isEnabled)
        XCTAssertEqual(settings.broker.port, 43117)

        let reencoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertFalse(object.keys.contains { key in
            key.contains("telemetry") || key.contains("audit") || key.contains("lifecycle")
        })
    }

    func test_brokerSettingsDefault_isDisabledOnPort43117WithBundledPolicy() {
        XCTAssertFalse(BrokerSettings.default.isEnabled)
        XCTAssertEqual(BrokerSettings.default.port, 43117)
        XCTAssertEqual(BrokerSettings.default.policy, BrokerPolicy.bundledDefault)
    }

    func test_brokerRoutingNotificationSettingsDecodeDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(
            BrokerSettings.self,
            from: Data(#"{"is_enabled":true}"#.utf8)
        )
        XCTAssertTrue(old.routingUpdateNotificationsEnabled)
        XCTAssertTrue(old.autoApplyPublishedRoutingUpdates)
        XCTAssertTrue(BrokerSettings.default.autoApplyPublishedRoutingUpdates)
        XCTAssertNil(old.suppressedAutomaticRoutingUpdateFingerprint)
        XCTAssertTrue(old.seenRemotePresetIDs.isEmpty)
        XCTAssertNil(old.lastRoutingUpdateNotifiedFingerprint)

        var settings = BrokerSettings.default
        let presetID = UUID()
        settings.routingUpdateNotificationsEnabled = false
        settings.autoApplyPublishedRoutingUpdates = true
        settings.suppressedAutomaticRoutingUpdateFingerprint = "undone"
        settings.seenRemotePresetIDs = [presetID]
        settings.lastRoutingUpdateNotifiedFingerprint = "fingerprint"

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["routing_update_notifications_enabled"] as? Bool, false)
        XCTAssertEqual(object["auto_apply_published_routing_updates"] as? Bool, true)
        XCTAssertEqual(object["suppressed_automatic_routing_update_fingerprint"] as? String, "undone")
        XCTAssertEqual(object["last_routing_update_notified_fingerprint"] as? String, "fingerprint")
        XCTAssertEqual(object["seen_remote_preset_ids"] as? [String], [presetID.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(BrokerSettings.self, from: data), settings)
    }

    // MARK: - Network access and API key mode (network exposure)

    func test_brokerSettingsDefault_isLoopbackOnlyAndRequiresKeyOffThisMac() {
        XCTAssertEqual(BrokerSettings.default.networkAccess, .loopback)
        XCTAssertEqual(BrokerSettings.default.apiKeyMode, .nonLoopback)
    }

    func test_brokerSettingsSavedBeforeNetworkKeys_decodesToLoopbackDefaults() throws {
        // A save written before network exposure existed carries neither key.
        // It must keep behaving exactly as it did: loopback-bound, and — since
        // nothing can reach it off this Mac — no key is ever demanded.
        let json = """
        {
            "is_enabled": true,
            "port": 43117
        }
        """
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.networkAccess, .loopback)
        XCTAssertEqual(settings.apiKeyMode, .nonLoopback)
        XCTAssertTrue(settings.isEnabled)
    }

    func test_brokerSettingsWithUnknownNetworkAndKeyRawValues_fallsBackToDefaults() throws {
        // A value this build doesn't know (a newer Pinemeter's save, or a
        // hand-edited file) must not throw and take every other broker
        // setting down with it.
        let json = """
        {
            "is_enabled": true,
            "port": 50000,
            "network_access": "tailscale",
            "api_key_mode": "mtls"
        }
        """
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.networkAccess, .loopback)
        XCTAssertEqual(settings.apiKeyMode, .nonLoopback)
        XCTAssertEqual(settings.port, 50000)
    }

    func test_brokerSettingsNetworkAndKeyMode_roundTripThroughCodable() throws {
        var settings = BrokerSettings.default
        settings.networkAccess = .network
        settings.apiKeyMode = .all

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["network_access"] as? String, "network")
        XCTAssertEqual(object["api_key_mode"] as? String, "all")

        let decoded = try JSONDecoder().decode(BrokerSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
    }

    func test_brokerSettingsEncoding_neverCarriesAPIKeyMaterial() throws {
        // The key lives in the Keychain and nowhere else: no settings key may
        // ever hold it, whatever the mode.
        var settings = BrokerSettings.default
        settings.apiKeyMode = .all
        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertFalse(object.keys.contains("api_key"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("pm_"))
    }

    func test_customizedBrokerSettings_roundTripsThroughSettingsRepositoryUnchanged() async throws {
        let suiteName = "AppSettingsTests.broker.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)
        defer { userDefaults?.removePersistentDomain(forName: suiteName) }
        let repository = SettingsRepository(userDefaults: userDefaults ?? .standard)

        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.port = 50000
        var policy = BrokerPolicy.bundledDefault
        policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5"),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol"),
            BrokerCandidate(
                route: .codex,
                model: "gpt-future",
                effort: BrokerEffort(rawValue: "ultra")
            ),
        ]
        policy.models["gpt-future"] = BrokerModelSpec(
            quota: .chatGPT(labelContains: "codex weekly"),
            effort: BrokerEffortCapability(
                levels: [.low, BrokerEffort(rawValue: "ultra")!],
                nilLabel: "Default (ultra)"
            )
        )
        settings.broker.policy = policy

        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(loaded.broker, settings.broker)
        XCTAssertTrue(loaded.broker.isEnabled)
        XCTAssertEqual(loaded.broker.port, 50000)
        XCTAssertEqual(loaded.broker.policy.roles["planning"], policy.roles["planning"])
        XCTAssertEqual(loaded.broker.policy.models["gpt-future"], policy.models["gpt-future"])
    }

    // MARK: - Instruction dispatch settings (Phase 10, D-05/D-08)

    func test_decodingSettingsWithoutInstructionDispatch_usesSafeDefaults() throws {
        let stored = Data("""
        {
            "broker": {
                "is_enabled": true,
                "port": 43117
            }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: stored)

        XCTAssertEqual(settings.broker.instructionDispatch, .default)
        XCTAssertFalse(settings.broker.instructionDispatch.isAutomaticDispatchEnabled)
        XCTAssertNil(settings.broker.instructionDispatch.t3ProjectID)
    }

    func test_decodingUnknownInstructionDispatchHarness_fallsBackToT3() throws {
        let stored = Data("""
        {
            "broker": {
                "instruction_dispatch": {
                    "harness": "future-harness",
                    "t3_project_id": "project-1",
                    "automatic_dispatch_enabled": true
                }
            }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: stored)

        XCTAssertEqual(settings.broker.instructionDispatch.harness, .t3)
        XCTAssertEqual(settings.broker.instructionDispatch.t3ProjectID, "project-1")
        XCTAssertTrue(settings.broker.instructionDispatch.isAutomaticDispatchEnabled)
    }

    func test_instructionDispatchSettings_roundTripPreservesAllEightFields() async throws {
        let repository = SettingsRepositoryFake()
        let lastDispatchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let lastAutomaticDispatchAt = Date(timeIntervalSince1970: 1_800_000_100)
        var settings = AppSettings.default
        settings.broker.instructionDispatch = BrokerInstructionDispatchSettings(
            harness: .t3,
            t3ProjectID: "project-1",
            t3ProjectTitle: "Project One",
            isAutomaticDispatchEnabled: true,
            lastDispatchedAt: lastDispatchedAt,
            lastDispatchThreadID: "thread-1",
            lastAutomaticDispatchAt: lastAutomaticDispatchAt,
            lastDispatchFailure: "synthetic failure"
        )
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        try await repository.save(decoded)
        let loadedSettings = await repository.load()
        let loaded = loadedSettings.broker.instructionDispatch

        XCTAssertEqual(loaded.harness, .t3)
        XCTAssertEqual(loaded.t3ProjectID, "project-1")
        XCTAssertEqual(loaded.t3ProjectTitle, "Project One")
        XCTAssertTrue(loaded.isAutomaticDispatchEnabled)
        XCTAssertEqual(loaded.lastDispatchedAt, lastDispatchedAt)
        XCTAssertEqual(loaded.lastDispatchThreadID, "thread-1")
        XCTAssertEqual(loaded.lastAutomaticDispatchAt, lastAutomaticDispatchAt)
        XCTAssertEqual(loaded.lastDispatchFailure, "synthetic failure")
    }

    func test_instructionDispatchSettingsEncoding_neverCarriesCredentialMaterial() throws {
        var settings = AppSettings.default
        settings.broker.instructionDispatch = BrokerInstructionDispatchSettings(
            t3ProjectID: "project-1",
            t3ProjectTitle: "Project One",
            isAutomaticDispatchEnabled: true,
            lastDispatchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastDispatchThreadID: "thread-1",
            lastAutomaticDispatchAt: Date(timeIntervalSince1970: 1_800_000_100),
            lastDispatchFailure: "synthetic failure"
        )
        let payload = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)

        for forbiddenKey in ["access_token", "expires_at", "scope"] {
            XCTAssertFalse(
                payload.contains("\"\(forbiddenKey)\""),
                "AppSettings must not persist T3 credential key: \(forbiddenKey)"
            )
        }
    }

    func test_oldSaveWithoutModels_gainsTerraCodexRouteAndKeepsLocalLanes() throws {
        var stored = BrokerSettings.default
        stored.policy.usageLanes = [
            "codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly"),
            "t3/local": .claudeAccount(
                accountId: "local-account", labelContains: nil, isPrimary: nil
            ),
        ]
        stored.policy.roles["standard"] = [
            BrokerCandidate(route: .auto, model: "gpt-5.6-terra")
        ]
        stored.policy.t3Instances = [
            T3InstanceConfig(
                id: "codex", name: "Codex", driver: "codex",
                detectedModels: ["gpt-5.6-terra"]
            )
        ]
        stored.activeProfileRules = stored.policy.ruleSet
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        )
        var policy = try XCTUnwrap(object["policy"] as? [String: Any])
        policy.removeValue(forKey: "models")
        object["policy"] = policy
        var pinned = try XCTUnwrap(object["active_profile_rules"] as? [String: Any])
        pinned.removeValue(forKey: "models")
        object["active_profile_rules"] = pinned

        let decoded = try JSONDecoder().decode(
            BrokerSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let expanded = BrokerEngine.expandingModelChoices(
            [BrokerCandidate(route: .auto, model: "gpt-5.6-terra")],
            policy: decoded.policy,
            oracle: nil,
            now: BrokerFixture.now
        )

        XCTAssertTrue(expanded.contains { $0.id == "codex/gpt-5.6-terra" })
        XCTAssertEqual(decoded.policy.models, BrokerPolicy.default.models)
        XCTAssertEqual(decoded.activeProfileRules?.models, BrokerPolicy.default.models)
        XCTAssertEqual(decoded.policy.usageLanes, stored.policy.usageLanes)
        XCTAssertFalse(decoded.hasUnsavedProfileEdits)
        let decision = try recordedDecide(
            role: "standard",
            caller: "claude-code",
            policy: decoded.policy,
            oracle: BrokerFixture.oracle(
                chatGPTRows: [.init(label: "Codex Weekly", usedPercent: 20)],
                chatGPTConfigured: true
            ),
            cooldowns: [:],
            now: BrokerFixture.now,
            t3: ["codex": T3Liveness(reachable: true, why: "http 401")]
        )
        XCTAssertEqual(decision.model, "codex/gpt-5.6-terra")
        XCTAssertFalse(decision.degraded)
        let roundTrip = try JSONDecoder().decode(
            BrokerSettings.self, from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(roundTrip.policy.usageLanes, stored.policy.usageLanes)
    }

    func test_brokerSettingsMissingPortAndPolicy_decodesPerFieldDefaults() throws {
        // BrokerSettings never uses synthesized Codable: each field falls
        // back independently, so a persisted blob missing a newly-added key
        // still decodes safely rather than failing the whole struct.
        let json = """
        {
            "is_enabled": true
        }
        """
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: Data(json.utf8))

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.port, 43117)
        XCTAssertEqual(settings.policy, BrokerPolicy.bundledDefault)
    }

    func test_brokerSettingsOutOfRangePort_clampsToTheValidRangeOnDecode() throws {
        // Regression for review WR-02: a corrupted persisted port (e.g. from
        // a downgrade or a hand-edited file) must clamp to the valid
        // 1024...65535 range at the model layer rather than silently
        // becoming 0 (an OS-assigned ephemeral port) downstream via
        // `UInt16(clamping:)`.
        let negativeJSON = #"{ "is_enabled": true, "port": -5 }"#
        let negative = try JSONDecoder().decode(BrokerSettings.self, from: Data(negativeJSON.utf8))
        XCTAssertEqual(negative.port, BrokerSettings.portRange.lowerBound)

        let tooLowJSON = #"{ "is_enabled": true, "port": 80 }"#
        let tooLow = try JSONDecoder().decode(BrokerSettings.self, from: Data(tooLowJSON.utf8))
        XCTAssertEqual(tooLow.port, BrokerSettings.portRange.lowerBound)

        let tooHighJSON = #"{ "is_enabled": true, "port": 999999 }"#
        let tooHigh = try JSONDecoder().decode(BrokerSettings.self, from: Data(tooHighJSON.utf8))
        XCTAssertEqual(tooHigh.port, BrokerSettings.portRange.upperBound)
    }

    func test_decodingPreEffortBrokerPolicy_decodesEveryCandidateWithoutAnEffort() throws {
        // A policy saved before candidate efforts existed stores every
        // candidate as a bare id string. It must still decode, with every
        // candidate carrying no effort (the provider default).
        let preEffortJSON = """
        {
            "is_enabled": true,
            "policy": {
                "roles": {
                    "planning": ["native/claude-fable-5", "t3:claude_secondary/claude-fable-5"],
                    "execution": ["t3/gpt-5.6-sol", "codex/gpt-5.6-sol"]
                },
                "callers": {
                    "codex": { "routes": ["t3"], "deny_candidates": ["native/claude-opus-5"] }
                }
            }
        }
        """
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: Data(preEffortJSON.utf8))

        XCTAssertEqual(
            settings.policy.roles["planning"]?.map(\.id),
            ["auto/claude-fable-5"]
        )
        for role in ["planning", "execution"] {
            XCTAssertTrue(
                settings.policy.roles[role, default: []].allSatisfy { $0.effort == nil },
                "legacy candidates for \(role) must keep an unset effort"
            )
        }
        XCTAssertEqual(
            settings.policy.roles["explore"]?.map(\.effort),
            BrokerPolicy.bundledDefault.roles["explore"]?.map(\.effort)
        )
        XCTAssertEqual(
            settings.policy.roles["verification"]?.map(\.effort),
            BrokerPolicy.bundledDefault.roles["verification"]?.map(\.effort)
        )
        XCTAssertEqual(settings.policy.callers["codex"]?.denyCandidates.first?.effort, .none)
        XCTAssertTrue(
            settings.appliedRoutingMigrations.contains(BrokerSettings.automaticModelRoutingMigrationID)
        )
    }

    // MARK: - Routing migrations

    /// JSON for a saved install sitting on the old Fable-led review chain.
    private func savedSettingsJSON(
        reviewChain: String,
        appliedMigrations: String? = nil
    ) -> Data {
        let migrations = appliedMigrations.map { ",\n            \"applied_routing_migrations\": \($0)" } ?? ""
        return Data("""
        {
            "is_enabled": true,
            "policy": {
                "roles": {
                    "review": \(reviewChain),
                    "execution": ["t3/gpt-5.6-sol"]
                }
            }\(migrations)
        }
        """.utf8)
    }

    private let oldFableReviewChain = """
    ["native/claude-fable-5", "t3/claude-fable-5", "native/claude-sonnet-5"]
    """

    func test_decodingSavedCodexCallerPolicy_allowsInHarnessCodexExecutionWithoutT3Redispatch() throws {
        let stored = Data("""
        {
            "policy": {
                "roles": {
                    "execution": ["t3/gpt-5.6-sol", "codex/gpt-5.6-sol"]
                },
                "callers": {
                    "codex": { "routes": ["t3"] }
                },
                "usage_lanes": {
                    "codex/gpt-5.6-sol": {
                        "provider": "chatgpt",
                        "label_contains": "codex weekly"
                    }
                }
            },
            "applied_routing_migrations": ["\(BrokerSettings.reviewOpusMigrationID)"]
        }
        """.utf8)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: stored)
        let decision = try recordedDecide(
            role: "execution",
            caller: "codex",
            policy: settings.policy,
            oracle: BrokerFixture.oracle(chatGPTRows: [
                .init(label: "Codex weekly", usedPercent: 10),
            ]),
            cooldowns: [:],
            now: BrokerFixture.now,
            t3: [:]
        )

        XCTAssertEqual(decision.route, .codex)
        XCTAssertEqual(decision.invocation, .agent(model: "gpt-5.6-sol"))
        XCTAssertFalse(
            try XCTUnwrap(
                decision.candidatesTried.first { $0.candidate == "codex/gpt-5.6-sol" }
            ).callerFiltered
        )
    }

    func test_decodingSavedNativeOnlyStandardRole_addsCodexRoutesOnce() throws {
        var stored = BrokerSettings.default
        stored.policy.roles["standard"] = [
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
        ]
        stored.activeProfileRules = stored.policy.ruleSet
        stored.appliedRoutingMigrations.remove(BrokerSettings.standardCodexRouteMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)
        let routes = settings.policy.roles["standard"]?.map(\.route)

        XCTAssertEqual(routes, [.auto, .auto])
        XCTAssertEqual(settings.policy.roles["standard"]?.last?.model, "gpt-6-sol")
        XCTAssertEqual(settings.activeProfileRules?.roles["standard"]?.map(\.route), routes)
        XCTAssertTrue(settings.appliedRoutingMigrations.contains(BrokerSettings.standardCodexRouteMigrationID))
    }

    /// A save old enough to need a migration also predates the models that
    /// migration injects, so its alias and model maps can be missing entries
    /// the injected chain needs. `BrokerEngine` grants the native route only
    /// to a model that has an alias, so a missing alias silently costs the
    /// injected candidate its native lane.
    func test_newRolesMigration_backfillsAliasesAndSpecsForTheModelsItInjects() throws {
        var stored = BrokerSettings.default
        let injected = Set(
            (BrokerPolicy.bundledDefault.roles["explore"] ?? []).map(\.model)
                + (BrokerPolicy.bundledDefault.roles["verification"] ?? []).map(\.model)
        )
        let sonnet55 = "claude-sonnet-5-5"
        XCTAssertTrue(
            injected.contains(sonnet55),
            "fixture assumes the shipped explore/verification chains name \(sonnet55)"
        )

        stored.policy.roles.removeValue(forKey: "explore")
        stored.policy.roles.removeValue(forKey: "verification")
        // The shape of a pre-Sonnet-5.5 save: the model is absent from both
        // maps, exactly as a policy written before that model shipped.
        for model in injected {
            stored.policy.agentModelAliases.removeValue(forKey: model)
            stored.policy.models.removeValue(forKey: model)
        }
        var savedProfile = BrokerAgentProfile(
            id: UUID(), name: "Saved", detail: "", symbolName: "leaf",
            isBuiltIn: false, rules: stored.policy.ruleSet
        )
        savedProfile.rules.roles.removeValue(forKey: "explore")
        savedProfile.rules.roles.removeValue(forKey: "verification")
        // The profile already defines the injected model itself, with its own
        // value. The migration injects a chain naming that model into this
        // profile, so backfill visits the key; it must keep the user's entry.
        let keptAlias = "deliberately-custom"
        savedProfile.rules.agentModelAliases[sonnet55] = keptAlias
        stored.profiles = [savedProfile]
        stored.activeProfileRules = stored.policy.ruleSet
        stored.appliedRoutingMigrations.remove(BrokerSettings.newRolesMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)

        // The injected chain's models are routable natively again.
        XCTAssertEqual(
            settings.policy.agentModelAliases[sonnet55],
            BrokerPolicy.bundledDefault.agentModelAliases[sonnet55]
        )
        XCTAssertNotNil(settings.policy.models[sonnet55])
        XCTAssertEqual(
            settings.activeProfileRules?.agentModelAliases[sonnet55],
            BrokerPolicy.bundledDefault.agentModelAliases[sonnet55]
        )
        let migratedProfile = try XCTUnwrap(settings.profiles.first)
        XCTAssertEqual(migratedProfile.rules.roles["explore"], BrokerPolicy.bundledDefault.roles["explore"])
        // Backfill is additive only: a user's existing entry is not replaced.
        XCTAssertEqual(migratedProfile.rules.agentModelAliases[sonnet55], keptAlias)
        XCTAssertNotNil(migratedProfile.rules.models[sonnet55])
    }

    /// A migration can record a model it did not inject into every store. A
    /// store whose chains never name that model must not gain an entry for it.
    func test_migrationBackfill_skipsAStoreWhoseChainsNeverNameTheModel() throws {
        var stored = BrokerSettings.default
        let sonnet55 = "claude-sonnet-5-5"
        // The policy and pin already have both new roles, with chains that do
        // not name Sonnet 5.5, so `new-roles` injects nothing into them.
        let custom = [BrokerCandidate(route: .auto, model: "gpt-6-sol", effort: .medium)]
        for role in ["explore", "verification"] {
            stored.policy.roles[role] = custom
        }
        for role in stored.policy.roles.keys {
            stored.policy.roles[role] = stored.policy.roles[role]?.filter { $0.model != sonnet55 }
        }
        stored.policy.agentModelAliases.removeValue(forKey: sonnet55)
        stored.policy.models.removeValue(forKey: sonnet55)
        stored.activeProfileRules = stored.policy.ruleSet
        // A saved profile lacks the roles, so the migration does inject there.
        var savedProfile = BrokerAgentProfile(
            id: UUID(), name: "Saved", detail: "", symbolName: "leaf",
            isBuiltIn: false, rules: stored.policy.ruleSet
        )
        savedProfile.rules.roles.removeValue(forKey: "explore")
        savedProfile.rules.roles.removeValue(forKey: "verification")
        stored.profiles = [savedProfile]
        stored.appliedRoutingMigrations.remove(BrokerSettings.newRolesMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)

        XCTAssertNil(settings.policy.agentModelAliases[sonnet55])
        XCTAssertNil(settings.policy.models[sonnet55])
        XCTAssertNil(settings.activeProfileRules?.agentModelAliases[sonnet55])
        let migratedProfile = try XCTUnwrap(settings.profiles.first)
        XCTAssertEqual(
            migratedProfile.rules.agentModelAliases[sonnet55],
            BrokerPolicy.bundledDefault.agentModelAliases[sonnet55]
        )
        XCTAssertNotNil(migratedProfile.rules.models[sonnet55])
    }

    func test_routingMigrations_neverBackfillAModelNoMigrationInjected() throws {
        var stored = BrokerSettings.default
        // `standard-codex-route` injects gpt-6-sol and nothing else. A model
        // absent from every chain must stay absent: backfill is scoped to what
        // a migration actually added, not to the whole shipped catalog.
        stored.policy.roles["standard"] = [
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
        ]
        let untouched = "claude-fable-5-1"
        stored.policy.agentModelAliases.removeValue(forKey: untouched)
        stored.policy.models.removeValue(forKey: untouched)
        stored.policy.models.removeValue(forKey: "gpt-6-sol")
        stored.activeProfileRules = stored.policy.ruleSet
        stored.appliedRoutingMigrations.remove(BrokerSettings.standardCodexRouteMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)

        // The injected model gets its spec back, so its quota lane resolves.
        XCTAssertNotNil(settings.policy.models["gpt-6-sol"])
        // Aliases are Claude-only, so an OpenAI model gains none. Backfill
        // copies what the shipped defaults define and invents nothing.
        XCTAssertNil(BrokerPolicy.bundledDefault.agentModelAliases["gpt-6-sol"])
        XCTAssertNil(settings.policy.agentModelAliases["gpt-6-sol"])
        // A model no migration injected stays exactly as the user left it.
        XCTAssertNil(settings.policy.agentModelAliases[untouched])
        XCTAssertNil(settings.policy.models[untouched])
    }

    func test_decodingSavedPolicy_addsNewRolesWithoutOverwritingOrRemovingRoles() throws {
        let customExplore = [BrokerCandidate(route: .auto, model: "custom-explore")]
        let customVerification = [BrokerCandidate(route: .auto, model: "custom-verification")]
        let architecture = [BrokerCandidate(route: .auto, model: "legacy-architecture")]
        var stored = BrokerSettings.default
        stored.policy.roles["explore"] = customExplore
        stored.policy.roles.removeValue(forKey: "verification")
        stored.policy.roles["architecture"] = architecture
        stored.activeProfileRules = stored.policy.ruleSet
        stored.activeProfileRules?.roles.removeValue(forKey: "explore")
        stored.activeProfileRules?.roles["verification"] = customVerification
        // A user-authored profile saved before these roles existed is applied
        // wholesale on its next pick, so it must be seeded too.
        var savedProfile = BrokerAgentProfile(
            id: UUID(), name: "Saved", detail: "", symbolName: "leaf",
            isBuiltIn: false, rules: stored.policy.ruleSet
        )
        savedProfile.rules.roles.removeValue(forKey: "explore")
        savedProfile.rules.roles.removeValue(forKey: "verification")
        stored.profiles = [savedProfile]
        stored.appliedRoutingMigrations.remove(BrokerSettings.newRolesMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)

        let migratedProfile = try XCTUnwrap(settings.profiles.first)
        XCTAssertEqual(migratedProfile.rules.roles["explore"], BrokerPolicy.bundledDefault.roles["explore"])
        XCTAssertEqual(
            migratedProfile.rules.roles["verification"],
            BrokerPolicy.bundledDefault.roles["verification"]
        )
        XCTAssertEqual(migratedProfile.rules.roles["architecture"], architecture)
        XCTAssertEqual(settings.policy.roles["explore"], customExplore)
        XCTAssertEqual(
            settings.policy.roles["verification"],
            BrokerPolicy.bundledDefault.roles["verification"]
        )
        XCTAssertEqual(
            settings.activeProfileRules?.roles["explore"],
            BrokerPolicy.bundledDefault.roles["explore"]
        )
        XCTAssertEqual(settings.activeProfileRules?.roles["verification"], customVerification)
        XCTAssertEqual(settings.policy.roles["architecture"], architecture)
        XCTAssertEqual(settings.activeProfileRules?.roles["architecture"], architecture)
        XCTAssertTrue(settings.appliedRoutingMigrations.contains(BrokerSettings.newRolesMigrationID))
    }

    func test_legalReviewMigration_respectsEachProfilesModelsAndStaleCache() throws {
        let url = try XCTUnwrap(BrokerPresetManifestTests.bundledManifestURL())
        let manifest = try BrokerPresetManifest.decode(from: Data(contentsOf: url))
        for preset in manifest.presets {
            var old = preset
            old.rules.roles.removeValue(forKey: "legal-review")
            let allowed = Set(old.rules.roles.values.flatMap { $0 }.map(\.model))
            let expected = BrokerPolicy.bundledDefault.roles["legal-review"]!.filter {
                allowed.contains($0.model)
            }
            var stored = BrokerSettings.default
            stored.policy.apply(old.rules)
            stored.activeProfileID = old.id
            stored.activeProfileRules = old.rules
            stored.remotePresets = [old]
            stored.profiles = [BrokerAgentProfile(
                id: UUID(), name: "Saved", detail: "", symbolName: "leaf",
                isBuiltIn: false, rules: old.rules)]
            stored.appliedRoutingMigrations.remove(BrokerSettings.legalReviewMigrationID)
            var migrated = try JSONDecoder().decode(BrokerSettings.self,
                from: JSONEncoder().encode(stored))
            XCTAssertFalse(expected.isEmpty, preset.name)
            XCTAssertEqual(migrated.policy.roles["legal-review"], expected, preset.name)
            XCTAssertEqual(migrated.activeProfileRules?.roles["legal-review"], expected, preset.name)
            XCTAssertEqual(migrated.profiles[0].rules.roles["legal-review"], expected, preset.name)
            XCTAssertFalse(migrated.activeProfileHasUpdatedRules, preset.name)
            migrated.updateRemotePresets([old])
            XCTAssertFalse(migrated.activeProfileHasUpdatedRules, preset.name)
            migrated.applyProfile(id: old.id)
            XCTAssertEqual(migrated.policy.roles["legal-review"], expected, preset.name)
            migrated.updateRemotePresets([preset])
            migrated.applyProfile(id: preset.id)
            XCTAssertEqual(migrated.policy.roles["legal-review"], preset.rules.roles["legal-review"])
        }
    }

    func test_stalePreset_preservesCustomAndEmptyLegalChains() {
        for chain in [[], [BrokerCandidate(route: .auto, model: "custom-legal")]] {
            var settings = BrokerSettings.default
            settings.policy.roles["legal-review"] = chain
            settings.activeProfileRules = settings.policy.ruleSet
            var stale = BrokerAgentProfile.balanced
            stale.rules = settings.policy.ruleSet
            stale.rules.roles.removeValue(forKey: "legal-review")
            settings.updateRemotePresets([stale])
            XCTAssertFalse(settings.activeProfileHasUpdatedRules)
            settings.applyProfile(id: stale.id)
            XCTAssertEqual(settings.policy.roles["legal-review"], chain)
        }
    }

    func test_legalReviewMigration_preservesEditsAndRunsOnlyOnce() throws {
        var stored = BrokerSettings.default
        stored.appliedRoutingMigrations.remove(BrokerSettings.legalReviewMigrationID)
        stored.policy.roles.removeValue(forKey: "legal-review")
        stored.activeProfileRules = stored.policy.ruleSet
        stored.profiles = [BrokerAgentProfile(
            id: UUID(), name: "Saved", detail: "", symbolName: "leaf",
            isBuiltIn: false, rules: stored.policy.ruleSet
        )]
        func reload(_ value: BrokerSettings) throws -> BrokerSettings {
            try JSONDecoder().decode(BrokerSettings.self, from: JSONEncoder().encode(value))
        }
        var migrated = try reload(stored)
        let expected = BrokerPolicy.bundledDefault.roles["legal-review"]
        XCTAssertEqual(migrated.policy.roles["legal-review"], expected)
        XCTAssertEqual(migrated.activeProfileRules?.roles["legal-review"], expected)
        XCTAssertEqual(migrated.profiles.first?.rules.roles["legal-review"], expected)
        migrated.policy.roles.removeValue(forKey: "legal-review")
        XCTAssertNil(try reload(migrated).policy.roles["legal-review"])
        let custom = [BrokerCandidate(route: .auto, model: "custom-legal")]
        stored.policy.roles["legal-review"] = custom
        stored.activeProfileRules?.roles["legal-review"] = []
        stored.profiles[0].rules.roles["legal-review"] = custom
        let preserved = try reload(stored)
        XCTAssertEqual(preserved.policy.roles["legal-review"], custom)
        XCTAssertEqual(preserved.activeProfileRules?.roles["legal-review"], [])
        XCTAssertEqual(preserved.profiles.first?.rules.roles["legal-review"], custom)
    }

    func test_decodingSaveWithoutSeenRemotePresetIDs_seedsThemFromTheCachedPresets() throws {
        // A save from before routing-update notifications existed has cached
        // presets but no seen-set. Those presets are old news; an empty set
        // would announce all of them as new on the first refresh.
        var stored = BrokerSettings.default
        let preset = BrokerAgentProfile(
            id: UUID(), name: "Remote", detail: "", symbolName: "leaf", rules: .default
        )
        stored.updateRemotePresets([preset])

        let data = try JSONEncoder().encode(stored)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "seen_remote_preset_ids")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: legacyData)

        XCTAssertEqual(settings.seenRemotePresetIDs, [preset.id])

        // Present and empty stays empty: that is a real value, not a gap.
        var emptied = stored
        emptied.seenRemotePresetIDs = []
        let roundTrip = try JSONDecoder().decode(BrokerSettings.self, from: JSONEncoder().encode(emptied))
        XCTAssertTrue(roundTrip.seenRemotePresetIDs.isEmpty)
    }

    func test_decodingSavedNativeOnlyHeavyRole_addsCodexRoutesOnce() throws {
        var stored = BrokerSettings.default
        stored.policy.roles["heavy"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
        ]
        stored.activeProfileRules = stored.policy.ruleSet
        stored.appliedRoutingMigrations.remove(BrokerSettings.heavyCodexRouteMigrationID)

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)
        let routes = settings.policy.roles["heavy"]?.map(\.route)

        XCTAssertEqual(routes, [.auto, .auto])
        XCTAssertEqual(settings.policy.roles["heavy"]?.last?.model, "gpt-6-sol")
        XCTAssertEqual(settings.activeProfileRules?.roles["heavy"]?.map(\.route), routes)
        XCTAssertTrue(settings.appliedRoutingMigrations.contains(BrokerSettings.heavyCodexRouteMigrationID))
    }

    func test_decodingSaveWithoutMigrationRecord_movesReviewOntoTheOpusChain() throws {
        let settings = try JSONDecoder().decode(
            BrokerSettings.self, from: savedSettingsJSON(reviewChain: oldFableReviewChain)
        )

        XCTAssertEqual(
            settings.policy.roles["review"]?.map(\.id),
            BrokerPolicy.bundledDefault.roles["review"]?.map(\.id)
        )
        XCTAssertEqual(settings.policy.roles["review"]?.first?.id, "auto/claude-opus-5-5")
        XCTAssertEqual(settings.policy.roles["review"]?.first?.effort, .high)
        XCTAssertTrue(
            settings.appliedRoutingMigrations.contains(BrokerSettings.reviewOpusMigrationID),
            "the migration must record itself so it cannot run twice"
        )
        // Untouched: the migration is scoped to the one role it names.
        XCTAssertEqual(settings.policy.roles["execution"]?.map(\.id), ["auto/gpt-5.6-sol"])
    }

    func test_decodingSaveWithMigrationAlreadyRecorded_leavesAUserEditedReviewChainAlone() throws {
        // The whole point of recording the migration: a user who edits review
        // *after* being migrated must keep that edit across every later launch.
        let edited = """
        ["native/claude-haiku-4-5-20251001"]
        """
        let settings = try JSONDecoder().decode(
            BrokerSettings.self,
            from: savedSettingsJSON(
                reviewChain: edited,
                appliedMigrations: "[\"\(BrokerSettings.reviewOpusMigrationID)\"]"
            )
        )

        XCTAssertEqual(settings.policy.roles["review"]?.map(\.id), ["auto/claude-haiku-4-5-20251001"])
    }

    func test_migration_doesNotCreateAReviewRoleThatWasDeleted() throws {
        let json = Data("""
        {
            "is_enabled": true,
            "policy": { "roles": { "execution": ["t3/gpt-5.6-sol"] } }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(BrokerSettings.self, from: json)

        XCTAssertNil(
            settings.policy.roles["review"],
            "a deleted role stays deleted; the migration rewrites, it does not resurrect"
        )
        XCTAssertTrue(settings.appliedRoutingMigrations.contains(BrokerSettings.reviewOpusMigrationID))
    }

    func test_migration_movesThePinSoItDoesNotLookLikeAUserEdit() throws {
        var stored = BrokerSettings.default
        stored.policy.roles["review"] = [
            BrokerCandidate(route: .native, model: "claude-fable-5"),
        ]
        stored.activeProfileID = BrokerAgentProfile.balancedID
        stored.activeProfileRules = stored.policy.ruleSet
        stored.appliedRoutingMigrations = []

        let data = try JSONEncoder().encode(stored)
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: data)

        XCTAssertEqual(settings.policy.roles["review"]?.first?.id, "auto/claude-opus-5-5")
        XCTAssertFalse(
            settings.hasUnsavedProfileEdits,
            "the pin must move with the policy, or the bar blames the user for the migration"
        )
    }

    func test_migrationRecord_survivesARoundTripThroughSettingsRepository() async throws {
        let suiteName = "AppSettingsTests.broker.migrations.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)
        defer { userDefaults?.removePersistentDomain(forName: suiteName) }
        let repository = SettingsRepository(userDefaults: userDefaults ?? .standard)

        var settings = AppSettings.default
        settings.broker.policy.roles["review"] = [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
        ]
        try await repository.save(settings)

        let loaded = await repository.load()

        XCTAssertEqual(
            loaded.broker.policy.roles["review"]?.map(\.id),
            ["native/claude-haiku-4-5-20251001"],
            "a save made after migrating must not be re-migrated on load"
        )
    }

    func test_brokerPolicyWithEfforts_roundTripsThroughSettingsRepository() async throws {
        let suiteName = "AppSettingsTests.broker.effort.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)
        defer { userDefaults?.removePersistentDomain(forName: suiteName) }
        let repository = SettingsRepository(userDefaults: userDefaults ?? .standard)

        var settings = AppSettings.default
        settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol"),
        ]

        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(loaded.broker.policy.roles["planning"]?.map(\.effort), [.xhigh, nil])
    }

    func test_brokerSettingsInit_clampsAnOutOfRangePort() {
        let clamped = BrokerSettings(isEnabled: false, port: -1, policy: .bundledDefault)
        XCTAssertEqual(clamped.port, BrokerSettings.portRange.lowerBound)
    }

    // MARK: - Instruction re-check reminder

    /// A save written before the reminder existed must arrive with it on: an
    /// upgrade that silently opted every existing user out of the nudge would
    /// leave exactly the machines with the oldest checks unnudged.
    func test_decodingSettingsWithoutTheRecheckKeys_defaultsToAnArmedReminder() throws {
        let json = """
        {
            "refresh_interval": 300,
            "notifications_enabled": true,
            "is_first_launch": false,
            "broker": { "is_enabled": true, "port": 43117 }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertTrue(settings.broker.recheckReminderEnabled)
        XCTAssertNil(settings.lastInstructionRecheckNotifiedAt)
    }

    func test_recheckReminderSettings_roundTripThroughEncoding() throws {
        var settings = AppSettings.default
        settings.broker.recheckReminderEnabled = false
        settings.lastInstructionRecheckNotifiedAt = Date(timeIntervalSince1970: 1_760_000_000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(decoded.broker.recheckReminderEnabled)
        XCTAssertEqual(decoded.lastInstructionRecheckNotifiedAt, settings.lastInstructionRecheckNotifiedAt)
    }

    func test_brokerSettingsDefault_armsTheRecheckReminder() {
        XCTAssertTrue(BrokerSettings.default.recheckReminderEnabled)
    }
}
