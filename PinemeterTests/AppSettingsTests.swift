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
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let localReset = formatter.string(from: resetAt)
        formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        let compactLocalReset = formatter.string(from: resetAt)

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
            "Resets \(localReset)"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.timeRemaining.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Resets in 2 hours"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.both.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "\(compactLocalReset)\nin 2 hours"
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
        XCTAssertTrue(old.seenRemotePresetIDs.isEmpty)
        XCTAssertNil(old.lastRoutingUpdateNotifiedFingerprint)

        var settings = BrokerSettings.default
        let presetID = UUID()
        settings.routingUpdateNotificationsEnabled = false
        settings.seenRemotePresetIDs = [presetID]
        settings.lastRoutingUpdateNotifiedFingerprint = "fingerprint"

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["routing_update_notifications_enabled"] as? Bool, false)
        XCTAssertEqual(object["last_routing_update_notified_fingerprint"] as? String, "fingerprint")
        XCTAssertEqual(object["seen_remote_preset_ids"] as? [String], [presetID.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(BrokerSettings.self, from: data), settings)
    }

    @MainActor
    func test_brokerSettingsDeepLinkSelectsBrokerTab() {
        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.object(forKey: SettingsView.selectedTabDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: SettingsView.selectedTabDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsView.selectedTabDefaultsKey)
            }
        }

        SettingsView.selectBrokerTab()

        XCTAssertEqual(
            defaults.string(forKey: SettingsView.selectedTabDefaultsKey),
            SettingsView.Tab.broker.rawValue
        )
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
        ]
        settings.broker.policy = policy

        try await repository.save(settings)
        let loaded = await repository.load()

        XCTAssertEqual(loaded.broker, settings.broker)
        XCTAssertTrue(loaded.broker.isEnabled)
        XCTAssertEqual(loaded.broker.port, 50000)
        XCTAssertEqual(loaded.broker.policy.roles["planning"], policy.roles["planning"])
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
        let decision = try BrokerEngine.decide(
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
        XCTAssertEqual(settings.activeProfileRules?.roles["standard"]?.map(\.route), routes)
        XCTAssertTrue(settings.appliedRoutingMigrations.contains(BrokerSettings.standardCodexRouteMigrationID))
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
        XCTAssertEqual(settings.policy.roles["review"]?.first?.id, "auto/claude-opus-5")
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

        XCTAssertEqual(settings.policy.roles["review"]?.first?.id, "auto/claude-opus-5")
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
