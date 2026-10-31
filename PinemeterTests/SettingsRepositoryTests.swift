//
//  SettingsRepositoryTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
@testable import Pinemeter

final class SettingsRepositoryTests: XCTestCase {
    func testInstructionDispatchProvenancePersistsAndLegacySettingsDecode() async throws {
        let suite = "SettingsRepositoryTests.dispatchProvenance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        let data = Data(#"{"broker":{"instruction_dispatch":{"automatic_dispatch_enabled":true,"last_dispatch_thread_id":"thread-1","last_dispatch_provenance":{"version":"1.2.0","setup_revision":2},"last_automatic_dispatch_provenance":{"version":"1.1.0","setup_revision":1}}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        try await repository.save(settings)
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(loaded.broker.instructionDispatch)
        ) as? [String: Any])
        let dispatch = encoded["last_dispatch_provenance"] as? [String: Any]
        let automatic = encoded["last_automatic_dispatch_provenance"] as? [String: Any]
        XCTAssertEqual(dispatch?["version"] as? String, "1.2.0")
        XCTAssertEqual(dispatch?["setup_revision"] as? Int, 2)
        XCTAssertEqual(automatic?["version"] as? String, "1.1.0")
        XCTAssertEqual(automatic?["setup_revision"] as? Int, 1)
        let legacy = try JSONDecoder().decode(
            BrokerInstructionDispatchSettings.self,
            from: Data(#"{"last_dispatch_thread_id":"legacy-thread"}"#.utf8)
        )
        XCTAssertEqual(legacy.lastDispatchThreadID, "legacy-thread")
        XCTAssertFalse(legacy.isAutomaticDispatchEnabled)
    }

    func testUnreadableSettingsRefuseWritesAndKeepBackup() async throws {
        let suite = "SettingsRepositoryTests.unreadable.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        let absent = await repository.load()
        let absentUnreadable = await repository.storedSettingsUnreadable()
        XCTAssertEqual(absent, .default)
        XCTAssertFalse(absentUnreadable)
        XCTAssertNil(defaults.object(forKey: "app_settings_unreadable_backup"))

        var settings = AppSettings.default
        settings.refreshInterval = 599
        settings.broker.remoteHosts = [roundTripHost(), roundTripHost(host: "other.example.com"), roundTripHost()]
        settings.broker.pushGeneration = 41
        try await repository.save(settings)
        let healthyMain = try XCTUnwrap(defaults.data(forKey: "app_settings"))
        let sidecar = try XCTUnwrap(defaults.data(forKey: "remote_push_state"))
        let corrupt = Data(#"{"settings_revision":1,"broker":{"remote_hosts":[{"host":42}]}}"#.utf8)
        defaults.set(corrupt, forKey: "app_settings")

        // Guard mutations even when this instance has never loaded the corruption.
        for instance in [repository, SettingsRepository(userDefaults: defaults)] {
            do {
                try await instance.save(.default)
                XCTFail("Unreadable settings must reject saves")
            } catch { XCTAssertEqual(error as? SettingsRepositoryError, .storedSettingsUnreadable) }
            do {
                _ = try await instance.reservePushGeneration()
                XCTFail("Unreadable settings must reject reservations")
            } catch { XCTAssertEqual(error as? SettingsRepositoryError, .storedSettingsUnreadable) }
            do {
                _ = try await instance.reservePushGeneration(after: 100)
                XCTFail("Unreadable settings must reject floor reservations")
            } catch { XCTAssertEqual(error as? SettingsRepositoryError, .storedSettingsUnreadable) }
            for _ in 0..<2 {
                let fallback = await instance.load()
                let unreadable = await instance.storedSettingsUnreadable()
                XCTAssertTrue(unreadable)
                XCTAssertEqual(fallback.refreshInterval, AppSettings.default.refreshInterval)
                XCTAssertEqual(fallback.broker.remoteHosts, settings.broker.remoteHosts)
                XCTAssertEqual(fallback.broker.pushGeneration, 41)
            }
            XCTAssertEqual(defaults.data(forKey: "app_settings"), corrupt)
            XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecar)
            XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), corrupt)
        }

        // Actor serialization must not let mixed reads and mutations erase the main blob.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = await repository.load() }
                group.addTask {
                    do {
                        try await repository.save(.default)
                        XCTFail("Concurrent save must refuse unreadable settings")
                    } catch { XCTAssertEqual(error as? SettingsRepositoryError, .storedSettingsUnreadable) }
                }
                group.addTask {
                    do {
                        _ = try await repository.reservePushGeneration(after: 100)
                        XCTFail("Concurrent reservation must refuse unreadable settings")
                    } catch { XCTAssertEqual(error as? SettingsRepositoryError, .storedSettingsUnreadable) }
                }
            }
        }
        XCTAssertEqual(defaults.data(forKey: "app_settings"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecar)

        // Repair by another repository or writer unblocks the same instance without a reset.
        defaults.set(healthyMain, forKey: "app_settings")
        let repaired = await repository.load()
        let repairedUnreadable = await repository.storedSettingsUnreadable()
        XCTAssertEqual(repaired, settings)
        XCTAssertFalse(repairedUnreadable)
        let next = try await repository.reservePushGeneration()
        XCTAssertEqual(next, 42)
        try await SettingsRepository(userDefaults: defaults).save(settings)
        let fresh = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(fresh.broker.pushGeneration, 42)

        // Keep the memory high-water mark even if an older sidecar reappears.
        defaults.set(Data("broken again".utf8), forKey: "app_settings")
        defaults.set(sidecar, forKey: "remote_push_state")
        let fallback = await repository.load()
        XCTAssertEqual(fallback.broker.pushGeneration, 42)
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), corrupt)
        try await repository.replaceUnreadableSettings(with: fallback)
        let replacement = await SettingsRepository(userDefaults: defaults).load()
        let replacementUnreadable = await repository.storedSettingsUnreadable()
        XCTAssertFalse(replacementUnreadable)
        XCTAssertEqual(replacement.broker.remoteHosts, settings.broker.remoteHosts)
        XCTAssertEqual(replacement.broker.pushGeneration, 42)
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), Data("broken again".utf8))
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup_previous"), corrupt)
        let replacementSidecar = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: "remote_push_state"))
        ) as? [String: Any])
        XCTAssertEqual(replacementSidecar["push_generation"] as? UInt64, 42)
    }

    func testReplacementAfterRepairKeepsReadableSettings() async throws {
        let suite = "SettingsRepositoryTests.replaceAfterRepair.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings.default
        settings.refreshInterval = 300
        try await SettingsRepository(userDefaults: defaults).save(settings)
        let healthyMain = try XCTUnwrap(defaults.data(forKey: "app_settings"))
        defaults.set(Data("broken".utf8), forKey: "app_settings")
        let repository = SettingsRepository(userDefaults: defaults)
        let fallback = await repository.load()
        let unreadable = await repository.storedSettingsUnreadable()
        XCTAssertTrue(unreadable)

        // Another writer repairs the blob before the user confirms the replacement.
        defaults.set(healthyMain, forKey: "app_settings")
        try await repository.replaceUnreadableSettings(with: fallback)
        XCTAssertEqual(defaults.data(forKey: "app_settings"), healthyMain)
        let reloaded = await repository.load()
        let stillUnreadable = await repository.storedSettingsUnreadable()
        XCTAssertEqual(reloaded.refreshInterval, 300)
        XCTAssertFalse(stillUnreadable)
    }

    func testUnreadableReplacementEncodingFailurePreservesStores() async throws {
        let suite = "SettingsRepositoryTests.replaceFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        try await repository.save(.default)
        let sidecar = defaults.data(forKey: "remote_push_state")
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: "app_settings")
        _ = await repository.load()
        var replacement = AppSettings.default
        replacement.refreshInterval = .infinity
        do {
            try await repository.replaceUnreadableSettings(with: replacement)
            XCTFail("Unencodable replacement must fail before either write")
        } catch {}
        let unreadable = await repository.storedSettingsUnreadable()
        XCTAssertTrue(unreadable)
        XCTAssertEqual(defaults.data(forKey: "app_settings"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecar)
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), corrupt)
    }

    func testBetaRewriteRestoresRemotePushState() async throws {
        // Betas 44-46 wrote neither remote_hosts nor push_generation.
        let betaPayloads = [
            #"{"refresh_interval":300,"broker":{"is_enabled":true}}"#,
            #"{"refresh_interval":300,"broker":{"is_enabled":false,"port":43117}}"#,
            #"{"refresh_interval":300,"broker":{"remote_hosts":[]}}"#
        ]
        for payload in betaPayloads {
            let suite = "SettingsRepositoryTests.beta.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var settings = AppSettings.default
            settings.broker.remoteHosts = [roundTripHost()]
            settings.broker.pushGeneration = 7
            try await SettingsRepository(userDefaults: defaults).save(settings)

            let betaData = Data(payload.utf8)
            defaults.set(betaData, forKey: "app_settings")
            let sidecarBefore = defaults.data(forKey: "remote_push_state")
            let repository = SettingsRepository(userDefaults: defaults)
            for _ in 0..<2 {
                let restored = await repository.load()
                XCTAssertEqual(restored.broker.remoteHosts, settings.broker.remoteHosts)
                XCTAssertEqual(restored.broker.pushGeneration, 7)
                XCTAssertEqual(restored.refreshInterval, 300)
                XCTAssertEqual(defaults.data(forKey: "app_settings"), betaData)
                XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)
            }
            let reserved = try await repository.reservePushGeneration()
            XCTAssertEqual(reserved, 8)
            let relaunched = await SettingsRepository(userDefaults: defaults).load()
            XCTAssertEqual(relaunched.broker.remoteHosts, settings.broker.remoteHosts)
            XCTAssertEqual(relaunched.broker.pushGeneration, 8)
            let main = try JSONDecoder().decode(AppSettings.self, from: XCTUnwrap(defaults.data(forKey: "app_settings")))
            XCTAssertEqual(main.broker.pushGeneration, 8)
            let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: "remote_push_state"))
            ) as? [String: Any])
            XCTAssertEqual(sidecar["version"] as? Int, 1)
            XCTAssertEqual(sidecar["push_generation"] as? UInt64, 8)
        }
    }

    func testRemoteHostPresenceAndRevisionControlSidecarRestore() async throws {
        for marked in [false, true] {
            for hostList in ["missing", "empty", "nonempty"] {
                let suite = "SettingsRepositoryTests.presence.\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                var settings = AppSettings.default
                settings.broker.remoteHosts = [roundTripHost()]
                settings.broker.pushGeneration = 7
                try await SettingsRepository(userDefaults: defaults).save(settings)
                var main = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: XCTUnwrap(defaults.data(forKey: "app_settings"))
                ) as? [String: Any])
                if !marked { main.removeValue(forKey: "settings_revision") }
                var broker = try XCTUnwrap(main["broker"] as? [String: Any])
                var expected = settings.broker.remoteHosts
                switch hostList {
                case "missing": broker.removeValue(forKey: "remote_hosts")
                case "empty":
                    broker["remote_hosts"] = []
                    if marked { expected = [] }
                default:
                    expected = [roundTripHost(host: "other.example.com")]
                    broker["remote_hosts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
                }
                main["broker"] = broker
                defaults.set(try JSONSerialization.data(withJSONObject: main), forKey: "app_settings")
                let repository = SettingsRepository(userDefaults: defaults)
                let loaded = await repository.load()
                XCTAssertEqual(loaded.broker.remoteHosts, expected, "marked=\(marked), hosts=\(hostList)")
                try await repository.save(loaded)
                // Removing main proves the save updated the sidecar, including intentional clears.
                defaults.removeObject(forKey: "app_settings")
                let sidecarOnly = await SettingsRepository(userDefaults: defaults).load()
                XCTAssertEqual(sidecarOnly.broker.remoteHosts, expected)
            }
        }
    }

    func testMissingMainReservationPreservesHostOrderDuplicatesAndDates() async throws {
        let suite = "SettingsRepositoryTests.missingMain.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings.default
        var host = roundTripHost()
        host.lastPushAt = Date(timeIntervalSince1970: 1_700_000_000)
        settings.broker.remoteHosts = [host, roundTripHost(host: "other.example.com"), host]
        settings.broker.pushGeneration = 7
        let repository = SettingsRepository(userDefaults: defaults)
        for _ in 0..<2 { try await repository.save(settings) }
        defaults.removeObject(forKey: "app_settings")
        let restoredRepository = SettingsRepository(userDefaults: defaults)
        let restored = await restoredRepository.load()
        XCTAssertEqual(restored.broker.remoteHosts, settings.broker.remoteHosts)
        let reserved = try await restoredRepository.reservePushGeneration()
        XCTAssertEqual(reserved, 8)
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(loaded.broker.remoteHosts, settings.broker.remoteHosts)
        XCTAssertEqual(loaded.broker.pushGeneration, 8)
    }

    func testInvalidSidecarBehavesAsAbsentWithoutWriting() async throws {
        let suite = "SettingsRepositoryTests.invalidSidecar.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for payload in ["not JSON", #"{"version":1,"remote_hosts":[],"push_generation":"invalid"}"#] {
            let bytes = Data(payload.utf8)
            defaults.set(bytes, forKey: "remote_push_state")
            let loaded = await SettingsRepository(userDefaults: defaults).load()
            XCTAssertEqual(loaded, .default)
            XCTAssertNil(defaults.data(forKey: "app_settings"))
            XCTAssertEqual(defaults.data(forKey: "remote_push_state"), bytes)
        }
    }

    private func roundTripHost(host: String = "host.example.com") -> RemoteHost {
        RemoteHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: host, sshUser: "pinemeter", keyPath: "~/.ssh/pinemeter",
            secretReference: "fixture-reference", pinnedHostKeyFingerprint: "SHA256:fixture"
        )
    }

    func testUnknownKeysPreservedAndCredentialsScrubbed() async throws {
        let suite = "SettingsRepositoryTests.unknown.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let payload = Data("""
        {
          "future_top": {
            "count": 18446744073709551615,
            "signed": -9223372036854775808,
            "fraction": 0.12345678901234568,
            "items": [{"label":"kept", "SeSsIoN_CoOkIe":"discard-cookie"},
                      [{"nested":true,"api_key_value":"discard-key"}]],
            "null_value": null
          },
          "broker": {
            "future_broker": {"label":"kept", "deep":[{"BearerValue":"discard-bearer"}]},
            "policy": {"future_owned_policy_field":"discard-owned-extra"},
            "push_generation": 18446744073709551615
          }
        }
        """.utf8)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let credentialFragments = [
            "credential", "session_key", "session_cookie", "cookie", "token",
            "secret", "password", "api_key", "bearer"
        ]
        let unseparatedCredentialKeys = [
            "futureApiKey", "futureSessionKey", "futurePrivateKey", "future-api-key",
            "futurePassphrase", "futureAuthorization"
        ]
        var broker = try XCTUnwrap(raw["broker"] as? [String: Any])
        for fragment in credentialFragments {
            raw["future_\(fragment.uppercased())_field"] = "discard-top"
            broker["future_\(fragment.uppercased())_field"] = "discard-broker"
        }
        for key in unseparatedCredentialKeys {
            raw[key] = "discard-top"
            broker[key] = "discard-broker"
        }
        raw["broker"] = broker
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "app_settings")
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = await repository.load()
        settings.refreshInterval = 300
        settings.broker.remoteHosts = [roundTripHost(), roundTripHost(host: "other.example.com"), roundTripHost()]
        for _ in 0..<2 {
            try await repository.save(settings)
            let saved = try XCTUnwrap(defaults.data(forKey: "app_settings"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            let future = try XCTUnwrap(object["future_top"] as? [String: Any])
            XCTAssertEqual((future["count"] as? NSNumber)?.stringValue, "18446744073709551615")
            XCTAssertEqual((future["signed"] as? NSNumber)?.stringValue, "-9223372036854775808")
            XCTAssertEqual(future["fraction"] as? Double, 0.12345678901234568)
            XCTAssertTrue(future["null_value"] is NSNull)
            let items = try XCTUnwrap(future["items"] as? [Any])
            let first = try XCTUnwrap(items.first as? [String: Any])
            XCTAssertEqual(first["label"] as? String, "kept")
            XCTAssertNil(first["SeSsIoN_CoOkIe"])
            let nested = try XCTUnwrap(items[1] as? [[String: Any]])
            XCTAssertEqual(nested.first?["nested"] as? Bool, true)
            XCTAssertNil(nested.first?["api_key_value"])
            let savedBroker = try XCTUnwrap(object["broker"] as? [String: Any])
            XCTAssertNotNil(savedBroker["api_key_mode"], "Owned keys are not credential-scrubbed")
            let futureBroker = try XCTUnwrap(savedBroker["future_broker"] as? [String: Any])
            XCTAssertEqual(futureBroker["label"] as? String, "kept")
            let deep = try XCTUnwrap(futureBroker["deep"] as? [[String: Any]])
            XCTAssertTrue(try XCTUnwrap(deep.first).isEmpty)
            let policy = try XCTUnwrap(savedBroker["policy"] as? [String: Any])
            XCTAssertNil(policy["future_owned_policy_field"], "Deeper owned structures are replaced, not merged")
            for fragment in credentialFragments {
                XCTAssertNil(object["future_\(fragment.uppercased())_field"])
                XCTAssertNil(savedBroker["future_\(fragment.uppercased())_field"])
            }
            for key in unseparatedCredentialKeys {
                XCTAssertNil(object[key], key)
                XCTAssertNil(savedBroker[key], key)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(AppSettings.self, from: saved)
            XCTAssertEqual(decoded.broker.pushGeneration, .max)
            XCTAssertEqual(decoded.broker.remoteHosts, settings.broker.remoteHosts)
            XCTAssertEqual(decoded.refreshInterval, 300)
        }
        let mainBefore = defaults.data(forKey: "app_settings")
        let sidecarBefore = defaults.data(forKey: "remote_push_state")
        do {
            _ = try await repository.reservePushGeneration()
            XCTFail("Expected exhaustion on the unknown-key merge path")
        } catch {
            XCTAssertEqual(error as? SettingsRepositoryError, .pushGenerationExhausted)
        }
        XCTAssertEqual(defaults.data(forKey: "app_settings"), mainBefore)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)
    }

    func testClearedOptionalsStayCleared() async throws {
        let suite = "SettingsRepositoryTests.cleared.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID()
        settings.broker.activeProfileRules = BrokerAgentProfile.balanced.rules
        try await repository.save(settings)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: "app_settings"))
        ) as? [String: Any])
        raw["future_top"] = "keep"
        raw["show_openai_usage"] = true
        var broker = try XCTUnwrap(raw["broker"] as? [String: Any])
        broker["future_broker"] = "keep"
        raw["broker"] = broker
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "app_settings")
        settings.cachedOrganizationId = nil
        settings.broker.activeProfileID = nil
        settings.broker.activeProfileRules = nil
        for _ in 0..<2 {
            try await repository.save(settings)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: "app_settings"))
            ) as? [String: Any])
            XCTAssertNil(saved["cached_organization_id"])
            XCTAssertNil(saved["show_openai_usage"])
            XCTAssertEqual(saved["future_top"] as? String, "keep")
            let savedBroker = try XCTUnwrap(saved["broker"] as? [String: Any])
            XCTAssertNil(savedBroker["active_profile_rules"])
            XCTAssertEqual(savedBroker["future_broker"] as? String, "keep")
            let reloaded = await SettingsRepository(userDefaults: defaults).load()
            XCTAssertNil(reloaded.cachedOrganizationId)
            XCTAssertNil(reloaded.broker.activeProfileRules)
        }
    }

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

    /// pinemeter-private#126/#127: the manual Codex workspace override
    /// persists through `SettingsRepository`'s real save/load round trip
    /// (`UserDefaults`-backed, not just `AppSettings`' own `Codable`
    /// conformance), and a settings blob saved before this key existed
    /// still loads it as nil.
    func test_codexWorkspaceAccountIdOverridePersistsThroughFreshRepository() async throws {
        let suiteName = "SettingsRepositoryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        settings.codexWorkspaceAccountIdOverride = "00000000-0000-0000-0000-00000000000a"

        let savingRepository = SettingsRepository(userDefaults: userDefaults)
        try await savingRepository.save(settings)

        let relaunchedRepository = SettingsRepository(userDefaults: userDefaults)
        let loaded = await relaunchedRepository.load()

        XCTAssertEqual(loaded.codexWorkspaceAccountIdOverride, "00000000-0000-0000-0000-00000000000a")
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

    func test_releaseUpgradePreservesMultiProviderBetaSettingsAndBindings() async throws {
        let suiteName = "SettingsRepositoryTests.releaseUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Fixed persisted payload, independent of the current encoder. No credentials.
        let payload = Data("""
        {
          "is_first_launch": false,
          "include_beta_updates": true,
          "show_chatgpt_usage": false,
          "claude_accounts": [
            {"id":"11111111-1111-1111-1111-111111111111","label":"Organization A","organizationId":"11111111-1111-1111-1111-111111111111","keychainAccount":"default","profileLabel":"Chrome Work","customLabel":"Work"},
            {"id":"22222222-2222-2222-2222-222222222222","label":"Organization B","organizationId":"22222222-2222-2222-2222-222222222222","keychainAccount":"22222222-2222-2222-2222-222222222222","customLabel":"Personal"}
          ],
          "chatgpt_accounts": [
            {"id":"test-user-a","label":"Account A","keychain_account":"chatgpt.com","custom_label":"Work GPT"},
            {"id":"test-user-b","label":"Account B","keychain_account":"test-user-b","custom_label":"Personal GPT"}
          ],
          "gemini_accounts": [
            {"id":"gemini.default","label":"Gemini","keychain_account":"generativelanguage.googleapis.com","custom_label":"Project Gemini"}
          ],
          "scan_excluded_accounts": [{"provider":"claude","accountId":"excluded-test-account","displayLabel":"Do not reconnect"}],
          "broker": {
            "profiles": [{"id":"33333333-3333-3333-3333-333333333333","name":"My rules","detail":"Saved beta rules","rules":{"roles":{"custom-role":["codex/gpt-5.6-sol"]}}}],
            "policy": {"t3_instances":[{"id":"codex","name":"Work agent","bound_account_id":"11111111-1111-1111-1111-111111111111"}]}
          }
        }
        """.utf8)
        defaults.set(payload, forKey: "app_settings")
        defaults.set("broker", forKey: "settingsSelectedTab")
        defaults.set("routing", forKey: "brokerSettingsPane")
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertFalse(loaded.isFirstLaunch)
        XCTAssertTrue(loaded.includeBetaUpdates)
        XCTAssertFalse(loaded.isChatGPTUsageShown)
        XCTAssertEqual(loaded.claudeAccounts.map(\.displayLabel), ["Work", "Personal"])
        XCTAssertEqual(loaded.chatGPTAccounts.map(\.displayLabel), ["Work GPT", "Personal GPT"])
        XCTAssertEqual(loaded.geminiAccounts.map(\.displayLabel), ["Project Gemini"])
        XCTAssertEqual(loaded.scanExcludedAccounts.first?.accountId, "excluded-test-account")
        XCTAssertEqual(loaded.broker.profiles.first?.name, "My rules")
        XCTAssertEqual(loaded.broker.profiles.first?.rules.roles["custom-role"]?.count, 1)
        XCTAssertEqual(loaded.broker.policy.t3Instances.first?.boundAccountId, "11111111-1111-1111-1111-111111111111")

        try await SettingsRepository(userDefaults: defaults).save(loaded)
        let relaunched = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(relaunched, loaded)
        XCTAssertEqual(defaults.string(forKey: "settingsSelectedTab"), "broker")
        XCTAssertEqual(defaults.string(forKey: "brokerSettingsPane"), "routing")
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
