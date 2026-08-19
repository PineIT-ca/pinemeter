import XCTest
@testable import Pinemeter

final class AppSettingsTests: XCTestCase {
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
        XCTAssertTrue(settings.isResetCelebrationEnabled)
        XCTAssertTrue(settings.scanExcludedAccounts.isEmpty)
        XCTAssertNil(settings.lastUpdateCheckAt)
        XCTAssertNil(settings.lastNotifiedUpdateVersion)
        XCTAssertNil(settings.availableUpdateVersion)
        XCTAssertEqual(settings.subscriptionResetAnnouncementMode, .timeRemaining)
        XCTAssertFalse(settings.includeBetaUpdates)
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
            ["native/claude-fable-5", "t3:claude_secondary/claude-fable-5"]
        )
        XCTAssertTrue(
            settings.policy.roles.values.allSatisfy { chain in chain.allSatisfy { $0.effort == nil } }
        )
        XCTAssertEqual(settings.policy.callers["codex"]?.denyCandidates.first?.effort, .none)
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
