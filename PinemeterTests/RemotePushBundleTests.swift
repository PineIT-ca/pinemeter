//
//  RemotePushBundleTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class RemotePushBundleTests: XCTestCase {
    private static let fixtureTimeZone = "America/Vancouver"

    func testMatchesAllSharedGoFixtures() async throws {
        try await assertFixture(
            "all-accounts",
            generation: 41,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: inventory(accountCount: 2),
            claudeSecrets: ["claude-primary": "fixture-claude-primary", "claude-secondary": "fixture-claude-secondary"],
            chatGPTSecrets: ["chatgpt-primary": "fixture-chatgpt-primary", "chatgpt-secondary": "fixture-chatgpt-secondary"],
            geminiSecrets: ["gemini-primary": "fixture-gemini-primary", "gemini-secondary": "fixture-gemini-secondary"],
            cooldowns: ["codex/gpt-5.6-sol": date("2026-09-22T07:30:00Z")],
            oracleSnapshot: fixtureOracle()
        )
        try await assertFixture(
            "empty-accounts",
            generation: 42,
            pushedAt: date("2026-09-22T06:31:00Z"),
            inventory: inventory(accountCount: 0),
            claudeSecrets: [:],
            chatGPTSecrets: [:],
            geminiSecrets: [:],
            cooldowns: [:],
            oracleSnapshot: nil
        )
        try await assertFixture(
            "removed-account",
            generation: 43,
            pushedAt: date("2026-09-22T06:32:00Z"),
            inventory: inventory(accountCount: 1),
            claudeSecrets: ["claude-primary": "fixture-claude-primary"],
            chatGPTSecrets: ["chatgpt-primary": "fixture-chatgpt-primary"],
            geminiSecrets: ["gemini-primary": "fixture-gemini-primary"],
            cooldowns: [:],
            oracleSnapshot: nil
        )
    }

    func testLegacySlotsFillMissingPrimaryWithoutDuplication() async throws {
        var settings = AppSettings.default
        settings.chatGPTAccounts = [ChatGPTAccount(
            id: "registered-chatgpt",
            label: "private@example.invalid",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount,
            customLabel: "Registered ChatGPT"
        )]
        settings.chatGPTCustomLabel = "Legacy ChatGPT"
        settings.geminiCustomLabel = "Legacy Gemini"

        let inventory = RemotePushAccountInventory(
            settings: settings,
            legacyClaudeConnected: true,
            legacyChatGPTConnected: true,
            legacyGeminiConnected: true
        )
        XCTAssertEqual(inventory.claude.map(\.id), ["claude.default"])
        XCTAssertEqual(inventory.chatGPT.map(\.id), ["registered-chatgpt"])
        XCTAssertEqual(inventory.chatGPT.map(\.label), ["Registered ChatGPT"])
        XCTAssertEqual(inventory.gemini.map(\.id), [GeminiAccount.legacyPrimaryId])
        XCTAssertEqual(inventory.claude.filter(\.isPrimary).count, 1)
        XCTAssertEqual(inventory.chatGPT.filter(\.isPrimary).count, 1)
        XCTAssertEqual(inventory.gemini.filter(\.isPrimary).count, 1)

        let data = try await builder(
            claude: [ClaudeAccount.primaryKeychainAccount: "fixture-claude-legacy"],
            chatGPT: [ChatGPTAccount.primaryKeychainAccount: "fixture-chatgpt-legacy"],
            gemini: [GeminiAccount.primaryKeychainAccount: "fixture-gemini-legacy"]
        ).build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: inventory,
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let document = try dictionary(data)
        let credentials = try XCTUnwrap(document["credentials"] as? [String: Any])
        XCTAssertNil(credentials["broker"])
    }

    func testEveryConnectedAccountIsEnumeratedAndBrokerCredentialIsAbsent() async throws {
        let data = try await builder(
            claude: ["claude-primary": "fixture-claude-primary", "claude-secondary": "fixture-claude-secondary"],
            chatGPT: ["chatgpt-primary": "fixture-chatgpt-primary", "chatgpt-secondary": "fixture-chatgpt-secondary"],
            gemini: ["gemini-primary": "fixture-gemini-primary", "gemini-secondary": "fixture-gemini-secondary"]
        ).build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: inventory(accountCount: 2),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let credentials = try XCTUnwrap(try dictionary(data)["credentials"] as? [String: Any])
        XCTAssertEqual((credentials["claude"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((credentials["chatgpt"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((credentials["gemini"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(credentials["broker"])
    }

    /// pinemeter-private#128: the key is entirely absent (not null) for a
    /// ChatGPT account with no resolved Codex workspace, so an older daemon
    /// and the shared Swift/Go fixtures never observe it; it is present only
    /// for the account it was resolved for.
    func testCodexWorkspaceAccountIdIsPresentOnlyWhenResolved() async throws {
        let data = try await builder(
            claude: [:],
            chatGPT: ["chatgpt-primary": "fixture-chatgpt-primary", "chatgpt-secondary": "fixture-chatgpt-secondary"],
            gemini: [:]
        ).build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: RemotePushAccountInventory(claude: [], chatGPT: inventory(accountCount: 2).chatGPT, gemini: []),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil,
            codexWorkspaceAccountIds: ["chatgpt-primary": "ws-123"]
        )
        let credentials = try XCTUnwrap(try dictionary(data)["credentials"] as? [String: Any])
        let chatGPT = try XCTUnwrap(credentials["chatgpt"] as? [[String: Any]])
        let primary = try XCTUnwrap(chatGPT.first { $0["id"] as? String == "chatgpt-primary" })
        let secondary = try XCTUnwrap(chatGPT.first { $0["id"] as? String == "chatgpt-secondary" })
        XCTAssertEqual(primary["codexWorkspaceAccountId"] as? String, "ws-123")
        XCTAssertNil(secondary["codexWorkspaceAccountId"], "unresolved account must omit the key, not send null")
    }

    func testUnreadableConnectedSecretFailsWithSanitizedError() async throws {
        let account = RemotePushAccountInventory.Account(
            id: "connected",
            label: "Connected",
            isPrimary: true,
            keychainAccount: "sensitive-storage-reference"
        )
        let inventory = RemotePushAccountInventory(claude: [account], chatGPT: [], gemini: [])
        let bundleBuilder = builder(claude: [:], chatGPT: [:], gemini: [:])

        do {
            _ = try await bundleBuilder.build(
                generation: 1,
                pushedAt: date("2026-09-22T06:30:00Z"),
                inventory: inventory,
                policy: fixturePolicy(),
                cooldowns: [:],
                oracleSnapshot: nil
            )
            XCTFail("Expected unreadable credential rejection")
        } catch {
            XCTAssertEqual(error as? RemotePushBundleError, .credentialUnavailable(.claude))
            let text = String(reflecting: error) + (error.localizedDescription)
            XCTAssertFalse(text.contains("sensitive-storage-reference"))
            XCTAssertFalse(text.contains("fixture-"))
        }
    }

    func testPolicyT3FieldsTimezoneAndObservationTimestampsArePreserved() async throws {
        let pushedAt = date("2026-09-22T06:30:00Z")
        let data = try await builder(
            claude: ["claude-primary": "fixture-claude-primary"],
            chatGPT: ["chatgpt-primary": "fixture-chatgpt-primary"],
            gemini: ["gemini-primary": "fixture-gemini-primary"]
        ).build(
            generation: 1,
            pushedAt: pushedAt,
            inventory: inventory(accountCount: 1),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: fixtureOracle()
        )
        let document = try dictionary(data)
        XCTAssertEqual(document["timeZone"] as? String, Self.fixtureTimeZone)
        let snapshot = try XCTUnwrap(document["oracleSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["timeZone"] as? String, Self.fixtureTimeZone)
        let oracle = try XCTUnwrap(snapshot["oracle"] as? [String: Any])
        let accounts = try XCTUnwrap(oracle["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.first?["lastUpdated"] as? String, "2026-09-22T06:24:00Z")
        XCTAssertNotEqual(accounts.first?["lastUpdated"] as? String, "2026-09-22T06:30:00Z")

        let policy = try XCTUnwrap(document["policy"] as? [String: Any])
        let instances = try XCTUnwrap(policy["t3_instances"] as? [[String: Any]])
        let instance = try XCTUnwrap(instances.first)
        XCTAssertEqual(instance["base_url_override"] as? String, "http://127.0.0.1:43118")
        XCTAssertEqual(instance["bound_account_id"] as? String, "claude-primary")
        XCTAssertEqual(instance["driver"] as? String, "claudeAgent")
        XCTAssertEqual(instance["origin"] as? String, "detected")
        XCTAssertEqual(instance["detected_models"] as? [String], ["gpt-5.6-sol"])
        XCTAssertEqual(instance["last_seen_at"] as? String, "2026-09-22T06:20:00Z")
    }

    func testTimezoneIsPresentWithoutSnapshotAndLimitsAreEnforced() async throws {
        let emptyData = try await builder(claude: [:], chatGPT: [:], gemini: [:]).build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: inventory(accountCount: 0),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let emptyDocument = try dictionary(emptyData)
        XCTAssertEqual(emptyDocument["timeZone"] as? String, Self.fixtureTimeZone)
        XCTAssertNil(emptyDocument["oracleSnapshot"])

        let accounts = (0...RemotePushBundleBuilder.maxAccountsPerProvider).map { index in
            RemotePushAccountInventory.Account(
                id: "claude-\(index)",
                label: "Claude \(index)",
                isPrimary: index == 0,
                keychainAccount: "key-\(index)"
            )
        }
        let oversizedInventory = RemotePushAccountInventory(claude: accounts, chatGPT: [], gemini: [])
        do {
            _ = try await builder(claude: [:], chatGPT: [:], gemini: [:]).build(
                generation: 1,
                pushedAt: date("2026-09-22T06:30:00Z"),
                inventory: oversizedInventory,
                policy: fixturePolicy(),
                cooldowns: [:],
                oracleSnapshot: nil
            )
            XCTFail("Expected account cap rejection")
        } catch {
            XCTAssertEqual(error as? RemotePushBundleError, .invalidInventory(.claude))
        }
    }

    private func assertFixture(
        _ name: String,
        generation: UInt64,
        pushedAt: Date,
        inventory: RemotePushAccountInventory,
        claudeSecrets: [String: String],
        chatGPTSecrets: [String: String],
        geminiSecrets: [String: String],
        cooldowns: [String: Date],
        oracleSnapshot: OracleSnapshot?
    ) async throws {
        let actualData = try await builder(
            claude: claudeSecrets,
            chatGPT: chatGPTSecrets,
            gemini: geminiSecrets
        ).build(
            generation: generation,
            pushedAt: pushedAt,
            inventory: inventory,
            policy: fixturePolicy(),
            cooldowns: cooldowns,
            oracleSnapshot: oracleSnapshot
        )
        let expectedData = try Data(contentsOf: fixtureURL(name))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: actualData) as? NSDictionary)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
        XCTAssertTrue(actual.isEqual(expected), "Generated bundle does not match \(name) fixture")
    }

    private func builder(
        claude: [String: String],
        chatGPT: [String: String],
        gemini: [String: String]
    ) -> RemotePushBundleBuilder {
        RemotePushBundleBuilder(
            keychainRepository: RemotePushKeychainFake(values: claude),
            chatGPTRepository: RemotePushChatGPTFake(values: chatGPT),
            geminiRepository: RemotePushGeminiFake(values: gemini),
            timeZoneIdentifier: { Self.fixtureTimeZone }
        )
    }

    private func inventory(accountCount: Int) -> RemotePushAccountInventory {
        let suffixes = accountCount == 2 ? ["primary", "secondary"] : accountCount == 1 ? ["primary"] : []
        return RemotePushAccountInventory(
            claude: suffixes.map { suffix in
                .init(
                    id: "claude-\(suffix)",
                    label: "Claude \(suffix.capitalized)",
                    isPrimary: suffix == "primary",
                    keychainAccount: "claude-\(suffix)"
                )
            },
            chatGPT: suffixes.map { suffix in
                .init(
                    id: "chatgpt-\(suffix)",
                    label: "ChatGPT \(suffix.capitalized)",
                    isPrimary: suffix == "primary",
                    keychainAccount: "chatgpt-\(suffix)"
                )
            },
            gemini: suffixes.map { suffix in
                .init(
                    id: "gemini-\(suffix)",
                    label: "Gemini \(suffix.capitalized)",
                    isPrimary: suffix == "primary",
                    keychainAccount: "gemini-\(suffix)"
                )
            }
        )
    }

    private func fixturePolicy() -> BrokerPolicy {
        BrokerPolicy(
            roles: ["execution": [BrokerCandidate(id: "codex/gpt-5.6-sol")!]],
            thresholds: .default,
            callers: ["codex": BrokerCallerPolicy(routes: [.codex, .t3, .native])],
            t3: BrokerT3Config(
                instanceByModel: ["gpt-5.6-sol": "fixture-t3"],
                defaultInstance: "fixture-t3"
            ),
            t3Instances: [T3InstanceConfig(
                id: "fixture-t3",
                name: "Fixture T3",
                baseURLOverride: "http://127.0.0.1:43118",
                boundAccountId: "claude-primary",
                origin: .detected,
                driver: "claudeAgent",
                detectedModels: ["gpt-5.6-sol"],
                lastSeenAt: date("2026-09-22T06:20:00Z")
            )],
            usageLanes: [:],
            models: [:],
            agentModelAliases: [:],
            allowForcedDegraded: [:]
        )
    }

    private func fixtureOracle() -> OracleSnapshot {
        OracleSnapshot(
            generatedAt: date("2026-09-22T06:25:00Z"),
            accounts: [OracleSnapshot.AccountRow(
                id: "claude-primary",
                label: "Claude Primary",
                isPrimary: true,
                lastUpdated: date("2026-09-22T06:24:00Z"),
                state: .fresh,
                session: 25,
                weekly: 40,
                sonnet: nil,
                fable: nil
            )],
            chatGPTState: .fresh,
            chatGPTRows: [],
            chatGPTLastUpdated: date("2026-09-22T06:23:00Z"),
            chatGPTConfigured: true
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pinemeterd/internal/importbundle/testdata/\(name).json")
    }

    // MARK: - CLI-origin accounts never reach the push (19-04, D-08, D-10, CLI-09)

    func test_cliOrigin_inventoryFromSettings_copiesIsCLIOriginFromAccountOrigin() throws {
        var settings = AppSettings.default
        settings.claudeAccounts = [
            ClaudeAccount(
                id: "org-cli",
                label: "CLI Org",
                organizationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                keychainAccount: "org-cli",
                origin: .cliLogin
            ),
            ClaudeAccount(
                id: "org-cookie",
                label: "Cookie Org",
                organizationId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                keychainAccount: "default"
            ),
        ]

        let inventory = RemotePushAccountInventory(
            settings: settings,
            legacyClaudeConnected: false,
            legacyChatGPTConnected: false,
            legacyGeminiConnected: false
        )

        let cli = try XCTUnwrap(inventory.claude.first { $0.id == "org-cli" })
        let cookie = try XCTUnwrap(inventory.claude.first { $0.id == "org-cookie" })
        XCTAssertTrue(cli.isCLIOrigin)
        XCTAssertFalse(cookie.isCLIOrigin)
    }

    func test_cliOrigin_pushableSkipsNonPrimaryCLIAccountWithEmptyKeychainSlot_keychainFakeNeverReadForIt() async throws {
        let primary = RemotePushAccountInventory.Account(
            id: "claude-primary",
            label: "Claude Primary",
            isPrimary: true,
            keychainAccount: "claude-primary"
        )
        let cliAccount = RemotePushAccountInventory.Account(
            id: "claude-cli",
            label: "Claude CLI",
            isPrimary: false,
            keychainAccount: "claude-cli-empty-slot",
            isCLIOrigin: true
        )
        let keychainFake = RemotePushKeychainFake(values: ["claude-primary": "fixture-claude-primary"])
        let bundleBuilder = RemotePushBundleBuilder(
            keychainRepository: keychainFake,
            chatGPTRepository: RemotePushChatGPTFake(values: [:]),
            geminiRepository: RemotePushGeminiFake(values: [:]),
            timeZoneIdentifier: { Self.fixtureTimeZone }
        )

        let data = try await bundleBuilder.build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: RemotePushAccountInventory(claude: [primary, cliAccount], chatGPT: [], gemini: []),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let credentials = try XCTUnwrap(try dictionary(data)["credentials"] as? [String: Any])
        let claude = try XCTUnwrap(credentials["claude"] as? [[String: Any]])
        XCTAssertEqual(claude.map { $0["id"] as? String }, ["claude-primary"])
        let readAccounts = await keychainFake.readAccounts
        XCTAssertFalse(readAccounts.contains("claude-cli-empty-slot"))
    }

    func test_cliOrigin_onlyCLIOriginChatGPTAccount_succeedsWithEmptyChatGPTArray() async throws {
        let cliAccount = RemotePushAccountInventory.Account(
            id: "chatgpt-cli",
            label: "ChatGPT CLI",
            isPrimary: false,
            keychainAccount: "chatgpt-cli-empty-slot",
            isCLIOrigin: true
        )
        let bundleBuilder = RemotePushBundleBuilder(
            keychainRepository: RemotePushKeychainFake(values: [:]),
            chatGPTRepository: RemotePushChatGPTFake(values: [:]),
            geminiRepository: RemotePushGeminiFake(values: [:]),
            timeZoneIdentifier: { Self.fixtureTimeZone }
        )

        let data = try await bundleBuilder.build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: RemotePushAccountInventory(claude: [], chatGPT: [cliAccount], gemini: []),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let credentials = try XCTUnwrap(try dictionary(data)["credentials"] as? [String: Any])
        XCTAssertEqual((credentials["chatgpt"] as? [[String: Any]])?.count, 0)
    }

    func test_cliOrigin_preservesOrderingWhenCLIOriginAccountIsSkipped() async throws {
        let primary = RemotePushAccountInventory.Account(
            id: "claude-a",
            label: "Claude A",
            isPrimary: true,
            keychainAccount: "claude-a"
        )
        let cliAccount = RemotePushAccountInventory.Account(
            id: "claude-b",
            label: "Claude B (CLI)",
            isPrimary: false,
            keychainAccount: "claude-b-empty-slot",
            isCLIOrigin: true
        )
        let cookieAccount = RemotePushAccountInventory.Account(
            id: "claude-c",
            label: "Claude C",
            isPrimary: false,
            keychainAccount: "claude-c"
        )
        let bundleBuilder = RemotePushBundleBuilder(
            keychainRepository: RemotePushKeychainFake(values: [
                "claude-a": "fixture-claude-a", "claude-c": "fixture-claude-c",
            ]),
            chatGPTRepository: RemotePushChatGPTFake(values: [:]),
            geminiRepository: RemotePushGeminiFake(values: [:]),
            timeZoneIdentifier: { Self.fixtureTimeZone }
        )

        let data = try await bundleBuilder.build(
            generation: 1,
            pushedAt: date("2026-09-22T06:30:00Z"),
            inventory: RemotePushAccountInventory(claude: [primary, cliAccount, cookieAccount], chatGPT: [], gemini: []),
            policy: fixturePolicy(),
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let credentials = try XCTUnwrap(try dictionary(data)["credentials"] as? [String: Any])
        let claude = try XCTUnwrap(credentials["claude"] as? [[String: Any]])
        XCTAssertEqual(claude.map { $0["id"] as? String }, ["claude-a", "claude-c"])
    }

    func test_cliOrigin_nonCLIAccountWithUnreadableSlot_stillThrowsCredentialUnavailable() async throws {
        let account = RemotePushAccountInventory.Account(
            id: "claude-unreadable",
            label: "Claude Unreadable",
            isPrimary: true,
            keychainAccount: "claude-unreadable"
        )
        let bundleBuilder = builder(claude: [:], chatGPT: [:], gemini: [:])

        do {
            _ = try await bundleBuilder.build(
                generation: 1,
                pushedAt: date("2026-09-22T06:30:00Z"),
                inventory: RemotePushAccountInventory(claude: [account], chatGPT: [], gemini: []),
                policy: fixturePolicy(),
                cooldowns: [:],
                oracleSnapshot: nil
            )
            XCTFail("Expected unreadable credential rejection")
        } catch {
            XCTAssertEqual(error as? RemotePushBundleError, .credentialUnavailable(.claude))
        }
    }

    func test_cliOrigin_remotePushBundleSource_referencesNoCLILoginType() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter/Services/Broker/RemotePushBundle.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        for forbidden in ["CLIAccessToken", "CLILoginSnapshot", "CodexCLILogin", "ClaudeCodeLogin"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "RemotePushBundle.swift must never reference a CLI login type: \(forbidden)"
            )
        }
    }
}

private actor RemotePushKeychainFake: KeychainRepositoryProtocol {
    let values: [String: String]
    private(set) var readAccounts: [String] = []

    init(values: [String: String]) {
        self.values = values
    }

    func save(sessionKey: String, account: String) {}
    func repairClaudeSessionKey(_ sessionKey: String, account: String) -> ClaudeCredentialRepairResult { .created }
    func retrieve(account: String) throws -> String {
        readAccounts.append(account)
        guard let value = values[account] else { throw KeychainError.notFound }
        return value
    }
    func update(sessionKey: String, account: String) {}
    func delete(account: String) {}
    func exists(account: String) -> Bool { values[account] != nil }
}

private actor RemotePushChatGPTFake: ChatGPTSessionRepositoryProtocol {
    let values: [String: String]
    private(set) var readAccounts: [String] = []

    init(values: [String: String]) {
        self.values = values
    }

    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession {
        readAccounts.append(account)
        guard let value = values[account] else { throw ChatGPTSessionRepositoryError.notFound }
        return ChatGPTSession(sessionCookie: value)
    }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: values[account] == nil ? .missing : .available, lastErrorCategory: nil)
    }
    func clear(account: String) {}
}

private actor RemotePushGeminiFake: GeminiAPIKeyRepositoryProtocol {
    let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey {
        guard let value = values[account] else { throw GeminiAPIKeyRepositoryError.notFound }
        return try GeminiAPIKey(value)
    }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: values[account] == nil ? .missing : .available, lastErrorCategory: nil)
    }
    func clear(account: String) {}
}
