//
//  ClaudeMultiAccountTests.swift
//  PinemeterTests
//
//  Coverage for connecting multiple Claude subscriptions across browser
//  profiles: model persistence, multi-account import, per-account usage,
//  popover sections, and teardown.
//

import XCTest
@testable import Pinemeter

@MainActor
final class ClaudeMultiAccountTests: XCTestCase {

    // MARK: - Fixtures

    private static let key1 = "sk-ant-primary-000000000001"
    private static let key2 = "sk-ant-secondary-00000000002"
    private static let org1UUIDString = "11111111-1111-1111-1111-111111111111"
    private static let org2UUIDString = "22222222-2222-2222-2222-222222222222"

    private func organization(id: Int, uuid: String, name: String) -> Organization {
        Organization(id: id, uuid: uuid, name: name, capabilities: ["chat"])
    }

    // MARK: - ClaudeAccount model

    func test_claudeAccount_codableRoundTripPreservesIdentityAndPrimaryFlag() throws {
        let primary = ClaudeAccount(
            id: Self.org1UUIDString,
            label: "Acme",
            organizationId: UUID(uuidString: Self.org1UUIDString)!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: "Chrome Profile 1"
        )
        let additional = ClaudeAccount(
            id: Self.org2UUIDString,
            label: "Personal",
            organizationId: UUID(uuidString: Self.org2UUIDString)!,
            keychainAccount: Self.org2UUIDString,
            profileLabel: "Chrome Profile 15"
        )

        let encoded = try JSONEncoder().encode([primary, additional])
        let decoded = try JSONDecoder().decode([ClaudeAccount].self, from: encoded)

        XCTAssertEqual(decoded, [primary, additional])
        XCTAssertTrue(decoded[0].isPrimary)
        XCTAssertFalse(decoded[1].isPrimary)
    }

    func test_appSettings_decodesLegacyJSONWithoutClaudeAccounts() throws {
        let legacyJSON = """
        {
          "refresh_interval": 60,
          "notifications_enabled": true,
          "is_first_launch": false,
          "show_chatgpt_usage": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)

        XCTAssertEqual(settings.claudeAccounts, [])
    }

    // MARK: - Multi-account import

    func test_importClaudeAccounts_connectsMultipleDistinctSubscriptions() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let result = try await appModel.importClaudeAccounts(from: .chrome)

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(appModel.settings.claudeAccounts.count, 2)

        let primary = try XCTUnwrap(appModel.settings.claudeAccounts.first(where: { $0.isPrimary }))
        XCTAssertEqual(primary.organizationId, org1.organizationUUID)
        XCTAssertEqual(primary.keychainAccount, "default")

        let additional = try XCTUnwrap(appModel.settings.claudeAccounts.first(where: { !$0.isPrimary }))
        XCTAssertEqual(additional.organizationId, org2.organizationUUID)
        XCTAssertEqual(additional.keychainAccount, Self.org2UUIDString)

        let savedPrimaryKey = try await keychainRepository.retrieve(account: "default")
        let savedAdditionalKey = try await keychainRepository.retrieve(account: Self.org2UUIDString)
        XCTAssertEqual(savedPrimaryKey, Self.key1)
        XCTAssertEqual(savedAdditionalKey, Self.key2)

        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertEqual(appModel.usageData, primaryUsage)
        XCTAssertEqual(appModel.claudeAccountUsage[Self.org2UUIDString], secondaryUsage)

        let sections = appModel.claudeUsageSections
        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(sections[0].usageData != nil)
        XCTAssertEqual(Set(sections.map(\.title)), ["Acme", "Personal"])
    }

    func test_importClaudeAccounts_deduplicatesSameSubscriptionAcrossProfiles() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let primaryUsage = makeUsageData(percentage: 11)

        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 7"),
        ])
        // Both profiles resolve to the same organization.
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org1]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let result = try await appModel.importClaudeAccounts(from: .chrome)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        XCTAssertTrue(appModel.settings.claudeAccounts[0].isPrimary)
        XCTAssertTrue(appModel.claudeAccountUsage.isEmpty)
    }

    func test_scanExcludedClaudeAccount_staysDisconnectedUntilReenabled() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)
        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: MultiAccountUsageServiceStub(
                organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
                usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
                primaryUsage: primaryUsage
            ),
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        try await appModel.excludeClaudeAccountFromScans(id: Self.org2UUIDString)
        _ = try await appModel.importClaudeAccounts(from: .chrome)

        XCTAssertEqual(appModel.settings.claudeAccounts.map(\.id), [Self.org1UUIDString])
        XCTAssertEqual(appModel.settings.scanExcludedAccounts.map(\.accountId), [Self.org2UUIDString])

        let exclusionId = try XCTUnwrap(appModel.settings.scanExcludedAccounts.first?.id)
        appModel.reenableScanAccount(id: exclusionId)
        _ = try await appModel.importClaudeAccounts(from: .chrome)

        XCTAssertEqual(
            Set(appModel.settings.claudeAccounts.map(\.id)),
            Set([Self.org1UUIDString, Self.org2UUIDString])
        )
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.isEmpty)
    }

    func test_singleAccountImport_rendersUnlabeledClaudeSection() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let usage = makeUsageData(percentage: 33)
        let importService = SessionKeyImportServiceStub(result: .success(ImportedSessionKey(
            value: Self.key1,
            sourceDescription: "Chrome Default"
        )))
        let usageService = UsageServiceStub(
            fetchUsageResult: .success(usage),
            organizations: [org1]
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importAndSaveSessionKey()

        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        let sections = appModel.claudeUsageSections
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Claude")
        XCTAssertEqual(sections[0].usageData, usage)
    }

    func test_renameClaudeAccount_overridesSectionTitleAndSurvivesReimport() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Acme")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        appModel.renameClaudeAccount(id: Self.org2UUIDString, customLabel: "Personal Max")

        XCTAssertEqual(Set(appModel.claudeUsageSections.map(\.title)), ["Acme", "Personal Max"])

        // A re-import rebuilds the account list but keeps the custom label.
        _ = try await appModel.importClaudeAccounts(from: .chrome)

        let renamed = try XCTUnwrap(appModel.settings.claudeAccounts.first(where: { $0.id == Self.org2UUIDString }))
        XCTAssertEqual(renamed.customLabel, "Personal Max")
        XCTAssertEqual(renamed.displayLabel, "Personal Max")

        // Clearing the custom label falls back to the organization name.
        appModel.renameClaudeAccount(id: Self.org2UUIDString, customLabel: "")
        XCTAssertEqual(Set(appModel.claudeUsageSections.map(\.title)), ["Acme"])
    }

    func test_clearSessionKey_removesAdditionalAccountsAndKeychain() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        try await appModel.clearSessionKey()

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
        XCTAssertTrue(appModel.claudeAccountUsage.isEmpty)
        XCTAssertTrue(appModel.claudeAccountErrors.isEmpty)
        XCTAssertFalse(appModel.isSetupComplete)

        let primaryExists = await keychainRepository.exists(account: "default")
        let additionalExists = await keychainRepository.exists(account: Self.org2UUIDString)
        XCTAssertFalse(primaryExists)
        XCTAssertFalse(additionalExists)
    }

    // MARK: - Remove account

    func test_removeClaudeAccount_nonPrimary_deletesKeychainAndDropsUsageSection() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        XCTAssertEqual(appModel.claudeAccountUsage[Self.org2UUIDString], secondaryUsage)

        try await appModel.removeClaudeAccount(id: Self.org2UUIDString)

        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        let remaining = try XCTUnwrap(appModel.settings.claudeAccounts.first)
        XCTAssertTrue(remaining.isPrimary)
        XCTAssertEqual(remaining.id, Self.org1UUIDString)

        let additionalExists = await keychainRepository.exists(account: Self.org2UUIDString)
        XCTAssertFalse(additionalExists)
        let primaryExists = await keychainRepository.exists(account: "default")
        XCTAssertTrue(primaryExists)

        XCTAssertNil(appModel.claudeAccountUsage[Self.org2UUIDString])
        XCTAssertNil(appModel.claudeAccountErrors[Self.org2UUIDString])
        XCTAssertEqual(appModel.claudeUsageSections.count, 1)
        XCTAssertTrue(appModel.isSetupComplete)
    }

    func test_removeClaudeAccount_primary_promotesNextAccountPreservingCustomLabel() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = MultiAccountUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        appModel.renameClaudeAccount(id: Self.org2UUIDString, customLabel: "Personal Max")

        try await appModel.removeClaudeAccount(id: Self.org1UUIDString)

        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        let newPrimary = try XCTUnwrap(appModel.settings.claudeAccounts.first)
        XCTAssertTrue(newPrimary.isPrimary)
        XCTAssertEqual(newPrimary.id, Self.org2UUIDString)
        XCTAssertEqual(newPrimary.keychainAccount, "default")
        XCTAssertEqual(newPrimary.customLabel, "Personal Max")
        XCTAssertEqual(newPrimary.profileLabel, "Chrome Profile 15")

        let savedPrimaryKey = try await keychainRepository.retrieve(account: "default")
        XCTAssertEqual(savedPrimaryKey, Self.key2)
        let stalePerOrgExists = await keychainRepository.exists(account: Self.org2UUIDString)
        XCTAssertFalse(stalePerOrgExists)

        XCTAssertNil(appModel.claudeAccountUsage[Self.org2UUIDString])
        XCTAssertNil(appModel.claudeAccountUsage[Self.org1UUIDString])
        XCTAssertEqual(appModel.claudeUsageSections.count, 1)
        XCTAssertTrue(appModel.isSetupComplete)
    }

    func test_removeClaudeAccount_primary_promotionFailureLeavesStateUnchanged() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let org2 = organization(id: 2, uuid: Self.org2UUIDString, name: "Personal")
        let primaryUsage = makeUsageData(percentage: 11)
        let secondaryUsage = makeUsageData(percentage: 22)

        let keychainRepository = KeychainRepositoryFake()
        let importService = MultiAccountImportServiceStub(importedKeys: [
            ImportedSessionKey(value: Self.key1, sourceDescription: "Chrome Profile 1"),
            ImportedSessionKey(value: Self.key2, sourceDescription: "Chrome Profile 15"),
        ])
        let usageService = TogglableUsageServiceStub(
            organizationsByKey: [Self.key1: [org1], Self.key2: [org2]],
            usageByOrganization: [org1.organizationUUID!: primaryUsage, org2.organizationUUID!: secondaryUsage],
            primaryUsage: primaryUsage
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importClaudeAccounts(from: .chrome)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)

        // The to-be-promoted account's session no longer validates.
        await usageService.setFailValidation(true)

        do {
            try await appModel.removeClaudeAccount(id: Self.org1UUIDString)
            XCTFail("Expected promotion failure to throw")
        } catch {
            // Expected.
        }

        // State is unchanged: the old primary is still primary and valid.
        XCTAssertEqual(appModel.settings.claudeAccounts.count, 2)
        let primary = try XCTUnwrap(appModel.settings.claudeAccounts.first(where: { $0.isPrimary }))
        XCTAssertEqual(primary.id, Self.org1UUIDString)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)

        let savedPrimaryKey = try await keychainRepository.retrieve(account: "default")
        XCTAssertEqual(savedPrimaryKey, Self.key1)
        let additionalExists = await keychainRepository.exists(account: Self.org2UUIDString)
        XCTAssertTrue(additionalExists)
    }

    func test_removeClaudeAccount_lastAccount_clearsClaudeEntirely() async throws {
        let org1 = organization(id: 1, uuid: Self.org1UUIDString, name: "Acme")
        let usage = makeUsageData(percentage: 33)

        let keychainRepository = KeychainRepositoryFake()
        let importService = SessionKeyImportServiceStub(result: .success(ImportedSessionKey(
            value: Self.key1,
            sourceDescription: "Chrome Default"
        )))
        let usageService = UsageServiceStub(
            fetchUsageResult: .success(usage),
            organizations: [org1]
        )

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importAndSaveSessionKey()
        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)

        try await appModel.removeClaudeAccount(id: Self.org1UUIDString)

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
        XCTAssertFalse(appModel.isSetupComplete)
        let primaryExists = await keychainRepository.exists(account: "default")
        XCTAssertFalse(primaryExists)
    }

    // MARK: - Menu bar quota bars

    func test_usageQuotaBars_mirrorPopoverContentAndOrderAcrossProviders() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: MultiAccountUsageServiceStub(
                organizationsByKey: [:],
                usageByOrganization: [:],
                primaryUsage: makeUsageData(percentage: 11)
            ),
            notificationService: NotificationServiceSpy()
        )

        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: Self.org1UUIDString,
                label: "Acme",
                organizationId: UUID(uuidString: Self.org1UUIDString)!,
                keychainAccount: ClaudeAccount.primaryKeychainAccount,
                profileLabel: nil
            ),
            ClaudeAccount(
                id: Self.org2UUIDString,
                label: "Personal",
                organizationId: UUID(uuidString: Self.org2UUIDString)!,
                keychainAccount: Self.org2UUIDString,
                profileLabel: nil
            ),
        ]
        appModel.usageData = makeUsageData(percentage: 11)
        appModel.claudeAccountUsage[Self.org2UUIDString] = makeUsageData(percentage: 22)
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.chatGPTUsageData = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 41, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 29,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(appModel.usageQuotaBars.map(\.label), [
            "Acme 5h",
            "Acme weekly",
            "Personal 5h",
            "Personal weekly",
            "ChatGPT Codex Tasks",
            "Gemini",
        ])
        XCTAssertEqual(appModel.usageQuotaBars.map(\.heading), [
            "5h", "Weekly", "5h", "Weekly", "Codex Tasks", "API",
        ])
        XCTAssertEqual(appModel.usageQuotaBars.map(\.owner), [
            "Acme", "Acme", "Personal", "Personal", "ChatGPT", "Gemini",
        ])
        // Multiple Claude accounts are renameable inline in the popover; the
        // account id rides each of that account's bars. Providers carry their
        // own rename target.
        XCTAssertEqual(appModel.usageQuotaBars.map(\.renameTarget), [
            .claudeAccount(id: Self.org1UUIDString), .claudeAccount(id: Self.org1UUIDString),
            .claudeAccount(id: Self.org2UUIDString), .claudeAccount(id: Self.org2UUIDString),
            .provider(.chatGPT), .provider(.gemini),
        ])
    }

    func test_renameProviderAccounts_updateDisplayLabelAndPopoverOwner() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: MultiAccountUsageServiceStub(
                organizationsByKey: [:],
                usageByOrganization: [:],
                primaryUsage: makeUsageData(percentage: 11)
            ),
            notificationService: NotificationServiceSpy()
        )
        appModel.isSetupComplete = true
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.chatGPTUsageData = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 41, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 29,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(appModel.chatGPTDisplayLabel, "ChatGPT")
        XCTAssertEqual(appModel.geminiDisplayLabel, "Gemini")

        appModel.renameChatGPTAccount(customLabel: "Work GPT")
        appModel.renameGeminiAccount(customLabel: "Personal Gemini")

        XCTAssertEqual(appModel.chatGPTDisplayLabel, "Work GPT")
        XCTAssertEqual(appModel.geminiDisplayLabel, "Personal Gemini")
        XCTAssertEqual(appModel.customLabel(for: .provider(.chatGPT)), "Work GPT")
        let owners = appModel.usageQuotaBars.map(\.owner)
        XCTAssertTrue(owners.contains("Work GPT"))
        XCTAssertTrue(owners.contains("Personal Gemini"))

        // Blank reverts to the default provider name.
        appModel.renameUsageOwner(.provider(.chatGPT), customLabel: "   ")
        XCTAssertEqual(appModel.chatGPTDisplayLabel, "ChatGPT")
        XCTAssertNil(appModel.settings.chatGPTCustomLabel)
    }

    func test_usageQuotaBars_singleClaudeAccountIsNotRenameable() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: MultiAccountUsageServiceStub(
                organizationsByKey: [:],
                usageByOrganization: [:],
                primaryUsage: makeUsageData(percentage: 11)
            ),
            notificationService: NotificationServiceSpy()
        )

        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: Self.org1UUIDString,
                label: "Acme",
                organizationId: UUID(uuidString: Self.org1UUIDString)!,
                keychainAccount: ClaudeAccount.primaryKeychainAccount,
                profileLabel: nil
            ),
        ]
        appModel.usageData = makeUsageData(percentage: 11)

        XCTAssertEqual(appModel.usageQuotaBars.map(\.renameTarget), [nil, nil])
    }

    func test_usageQuotaBars_includeFableModelScopedUsage() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: MultiAccountUsageServiceStub(
                organizationsByKey: [:],
                usageByOrganization: [:],
                primaryUsage: makeUsageData(percentage: 11)
            ),
            notificationService: NotificationServiceSpy()
        )
        var usage = makeUsageData(percentage: 11)
        usage.fableUsage = UsageLimit(
            utilization: 31,
            resetAt: Date().addingTimeInterval(TestConstants.oneHourInterval)
        )
        appModel.isSetupComplete = true
        appModel.usageData = usage

        XCTAssertEqual(appModel.usageQuotaBars.map(\.heading), ["5h", "Weekly", "Fable"])
        XCTAssertEqual(appModel.usageQuotaBars.last?.percentage, 31)
    }

    // MARK: - Per-account usage fetch

    func test_usageService_fetchUsageForAccount_usesAccountKeychainAndOrganization() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: TestConstants.sessionResetDateString,
            weeklyResetAt: TestConstants.weeklyResetDateString
        )
        let networkService = NetworkServiceStub(responseData: responseData)
        let keychainRepository = KeychainRepositoryFake()
        let service = UsageService(
            networkService: networkService,
            cacheRepository: CacheRepositoryFake(),
            keychainRepository: keychainRepository,
            settingsRepository: SettingsRepositoryFake()
        )

        let organizationId = UUID(uuidString: Self.org2UUIDString)!
        try await keychainRepository.save(sessionKey: Self.key2, account: Self.org2UUIDString)

        let usage = try await service.fetchUsage(
            account: Self.org2UUIDString,
            organizationId: organizationId,
            forceRefresh: false
        )

        XCTAssertEqual(usage.sessionUsage.utilization, TestConstants.sessionPercentage)
        let lastEndpoint = await networkService.lastEndpoint
        XCTAssertTrue(lastEndpoint?.contains("/organizations/\(organizationId.uuidString)/usage") == true)
    }
}

// MARK: - Test doubles

private actor MultiAccountImportServiceStub: SessionKeyImportServiceProtocol {
    let importedKeys: [ImportedSessionKey]

    init(importedKeys: [ImportedSessionKey]) {
        self.importedKeys = importedKeys
    }

    func importSessionKey() async throws -> ImportedSessionKey {
        try await importSessionKey(from: .defaultBrowser)
    }

    func importSessionKey(from source: BrowserImportSource) async throws -> ImportedSessionKey {
        guard let first = importedKeys.first else {
            throw SessionKeyImportError.noSessionKeyFound
        }
        return first
    }

    func importAllSessionKeys(from source: BrowserImportSource) async throws -> [ImportedSessionKey] {
        guard !importedKeys.isEmpty else {
            throw SessionKeyImportError.noSessionKeyFound
        }
        return importedKeys
    }

    func importChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        throw SessionKeyImportError.noChatGPTSessionCookieFound
    }

    func importChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        throw SessionKeyImportError.noChatGPTSessionCookieFound
    }

    func repairSavedSessionKey(account: String) async -> CredentialState {
        CredentialState(identity: CredentialIdentity(provider: .claude, kind: .sessionKey), health: .valid)
    }
}

private actor MultiAccountUsageServiceStub: UsageServiceProtocol {
    let organizationsByKey: [String: [Organization]]
    let usageByOrganization: [UUID: UsageData]
    let primaryUsage: UsageData

    init(
        organizationsByKey: [String: [Organization]],
        usageByOrganization: [UUID: UsageData],
        primaryUsage: UsageData
    ) {
        self.organizationsByKey = organizationsByKey
        self.usageByOrganization = usageByOrganization
        self.primaryUsage = primaryUsage
    }

    func fetchUsage(forceRefresh: Bool) async throws -> UsageData {
        primaryUsage
    }

    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool) async throws -> UsageData {
        guard let usage = usageByOrganization[organizationId] else {
            throw AppError.noSessionKey
        }
        return usage
    }

    func fetchOrganizations() async throws -> [Organization] {
        organizationsByKey.values.first ?? []
    }

    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] {
        organizationsByKey[sessionKey.value] ?? []
    }

    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool {
        organizationsByKey[sessionKey.value] != nil
    }
}

private actor TogglableUsageServiceStub: UsageServiceProtocol {
    let organizationsByKey: [String: [Organization]]
    let usageByOrganization: [UUID: UsageData]
    let primaryUsage: UsageData
    private var failValidation = false

    init(
        organizationsByKey: [String: [Organization]],
        usageByOrganization: [UUID: UsageData],
        primaryUsage: UsageData
    ) {
        self.organizationsByKey = organizationsByKey
        self.usageByOrganization = usageByOrganization
        self.primaryUsage = primaryUsage
    }

    func setFailValidation(_ value: Bool) {
        failValidation = value
    }

    func fetchUsage(forceRefresh: Bool) async throws -> UsageData {
        primaryUsage
    }

    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool) async throws -> UsageData {
        guard let usage = usageByOrganization[organizationId] else {
            throw AppError.noSessionKey
        }
        return usage
    }

    func fetchOrganizations() async throws -> [Organization] {
        organizationsByKey.values.first ?? []
    }

    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] {
        organizationsByKey[sessionKey.value] ?? []
    }

    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool {
        if failValidation { return false }
        return organizationsByKey[sessionKey.value] != nil
    }
}

// MARK: - Local helpers

private func makeUsageData(percentage: Double) -> UsageData {
    let resetDate = Date().addingTimeInterval(TestConstants.oneHourInterval)
    return UsageData(
        sessionUsage: UsageLimit(utilization: percentage, resetAt: resetDate),
        weeklyUsage: UsageLimit(utilization: TestConstants.weeklyPercentage, resetAt: resetDate),
        sonnetUsage: nil,
        lastUpdated: Date(timeIntervalSince1970: 0)
    )
}

private func makeUsageResponseData(
    sessionUtilization: Double,
    weeklyUtilization: Double,
    sessionResetAt: String?,
    weeklyResetAt: String?
) throws -> Data {
    let response = UsageAPIResponse(
        fiveHour: UsageLimitResponse(utilization: sessionUtilization, resetsAt: sessionResetAt),
        sevenDay: UsageLimitResponse(utilization: weeklyUtilization, resetsAt: weeklyResetAt),
        sevenDaySonnet: nil
    )
    return try JSONEncoder().encode(response)
}
