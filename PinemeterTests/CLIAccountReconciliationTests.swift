//
//  CLIAccountReconciliationTests.swift
//  PinemeterTests
//
//  Phase 19 plan 06: `AppModel.reconcileCLILogins(_:)` auto-connects a CLI
//  login for an account Pinemeter does not know about yet (D-01), merges a
//  login into an existing account by identity (D-03), and honors every
//  exclusion form so a removed CLI-backed account stays removed. Every
//  token, cookie, and account id below is synthetic -- no real Keychain,
//  file, or network access happens in this file.
//

import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class CLIAccountReconciliationTests: XCTestCase {
    // MARK: - Fixtures

    private static let orgC1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
    private static let orgC2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
    private static let orgC1LowercaseString = "00000000-0000-0000-0000-0000000000c1"
    private static let orgC2LowercaseString = "00000000-0000-0000-0000-0000000000c2"

    private func makeAppModel(
        cliLoginReader: CLILoginReaderFake,
        claudeAccounts: [ClaudeAccount] = [],
        chatGPTAccounts: [ChatGPTAccount] = [],
        scanExcludedAccounts: [ScanExcludedAccount] = [],
        isSetupComplete: Bool = false,
        cachedOrganizationId: UUID? = nil,
        isChatGPTUsageShown: Bool = false,
        hasChatGPTSessionCookie: Bool = false,
        keychainRepository: KeychainRepositoryFake = KeychainRepositoryFake(),
        chatGPTSessionRepository: ReconciliationChatGPTSessionRepositoryFake = ReconciliationChatGPTSessionRepositoryFake(),
        chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake = ChatGPTUsageCacheRepositoryFake(),
        chatGPTUsageService: any ChatGPTUsageServiceProtocol = ReconciliationChatGPTUsageServiceStub(),
        usageService: UsageServiceStub = UsageServiceStub(fetchUsageResult: .failure(ReconciliationStubError.notConfigured))
    ) -> AppModel {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            chatGPTUsageCacheRepository: chatGPTUsageCacheRepository,
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: ReconciliationClaudeOAuthUsageServiceStub()
        )
        appModel.settings.claudeAccounts = claudeAccounts
        appModel.settings.chatGPTAccounts = chatGPTAccounts
        appModel.settings.scanExcludedAccounts = scanExcludedAccounts
        appModel.settings.cachedOrganizationId = cachedOrganizationId
        appModel.settings.isChatGPTUsageShown = isChatGPTUsageShown
        appModel.isSetupComplete = isSetupComplete
        appModel.hasChatGPTSessionCookie = hasChatGPTSessionCookie
        return appModel
    }

    private static func claudeLogin(
        organizationId: UUID,
        organizationName: String? = "Example Org",
        expiresIn: TimeInterval = 3600
    ) -> ClaudeCodeLogin {
        CLILoginReaderFake.claudeLogin(organizationId: organizationId, organizationName: organizationName, expiresIn: expiresIn)
    }

    private static func codexLogin(
        chatgptUserId: String = "user-synthetic-0002",
        accountId: String = "00000000-0000-0000-0000-0000000000a2",
        expiresIn: TimeInterval = 3600
    ) -> CodexCLILogin {
        CLILoginReaderFake.codexLogin(chatgptUserId: chatgptUserId, accountId: accountId, expiresIn: expiresIn)
    }

    private static func makeChatGPTUsage(percentage: Double = 10) -> ChatGPTUsageData {
        ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: percentage, resetAt: Date(timeIntervalSince1970: 0))],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Claude auto-connect (CLI-07)

    func test_reconcile_unknownClaudeOrgLogin_addsNonPrimaryCLIOriginAccount() async throws {
        let login = Self.claudeLogin(organizationId: Self.orgC1, organizationName: "Example Org")
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let appModel = makeAppModel(cliLoginReader: reader)

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        let account = try XCTUnwrap(appModel.settings.claudeAccounts.first)
        XCTAssertEqual(account.id, Self.orgC1LowercaseString)
        XCTAssertEqual(account.keychainAccount, Self.orgC1LowercaseString)
        XCTAssertEqual(account.label, "Example Org")
        XCTAssertEqual(account.organizationId, Self.orgC1)
        XCTAssertEqual(account.origin, .cliLogin)
        XCTAssertFalse(account.isPrimary)
    }

    func test_reconcile_existingAccountMatchesOrgUUIDRegardlessOfCase_addsNothing() async throws {
        let existing = ClaudeAccount(
            id: "existing-id",
            label: "Already Connected",
            organizationId: Self.orgC1,
            keychainAccount: "existing-id"
        )
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [existing])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.claudeAccounts, [existing])
    }

    func test_reconcile_legacyInstallMatchingCachedOrganizationId_addsNothing() async throws {
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let appModel = makeAppModel(
            cliLoginReader: reader,
            claudeAccounts: [],
            isSetupComplete: true,
            cachedOrganizationId: Self.orgC1
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
    }

    func test_reconcile_claudeExclusionMatchingOrgUUID_blocksAdd() async throws {
        let exclusion = ScanExcludedAccount(
            provider: .claude,
            accountId: "00000000-0000-0000-0000-0000000000C1",
            displayLabel: "Example Org"
        )
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let appModel = makeAppModel(cliLoginReader: reader, scanExcludedAccounts: [exclusion])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
    }

    func test_reconcile_twoClaudeLogins_appendedInSnapshotOrderAfterExistingAccount() async throws {
        let existing = ClaudeAccount(
            id: "existing-id",
            label: "Existing",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b0")!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let loginC1 = Self.claudeLogin(organizationId: Self.orgC1, organizationName: "Org C1")
        let loginC2 = Self.claudeLogin(organizationId: Self.orgC2, organizationName: "Org C2")
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [loginC1, loginC2]))
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [existing])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(
            appModel.settings.claudeAccounts.map(\.id),
            ["existing-id", Self.orgC1LowercaseString, Self.orgC2LowercaseString]
        )
    }

    // MARK: - ChatGPT auto-connect (CLI-07)

    func test_reconcile_unknownCodexLogin_addsNonPrimaryCLIOriginAccount_setsUsageShown() async throws {
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(cliLoginReader: reader, isChatGPTUsageShown: false)

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.count, 1)
        let account = try XCTUnwrap(appModel.settings.chatGPTAccounts.first)
        XCTAssertEqual(account.id, "user-synthetic-0002")
        XCTAssertEqual(account.keychainAccount, "user-synthetic-0002")
        XCTAssertEqual(account.label, "user@example.com")
        XCTAssertEqual(account.planType, "pro")
        XCTAssertEqual(account.origin, .cliLogin)
        XCTAssertFalse(account.isPrimary)
        XCTAssertTrue(appModel.settings.isChatGPTUsageShown)
    }

    func test_reconcile_codexLoginWithExistingChatGPTAccount_addsAccountKeepsUsageShownFalse() async throws {
        let existing = ChatGPTAccount(
            id: "chatgpt.com",
            label: "ChatGPT",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount
        )
        let login = Self.codexLogin(chatgptUserId: "user-synthetic-0003")
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(
            cliLoginReader: reader,
            chatGPTAccounts: [existing],
            isChatGPTUsageShown: false,
            hasChatGPTSessionCookie: true
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.map(\.id), ["chatgpt.com", "user-synthetic-0003"])
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown, "usage-shown must only flip when the list was previously empty")
    }

    func test_reconcile_chatGPTExclusionKeyedUserId_blocksAdd() async throws {
        let exclusion = ScanExcludedAccount(provider: .chatGPT, accountId: "user-synthetic-0002", displayLabel: "ChatGPT")
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(cliLoginReader: reader, scanExcludedAccounts: [exclusion])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
    }

    func test_reconcile_chatGPTExclusionKeyedPrimarySlot_blocksEveryAdd() async throws {
        let exclusion = ScanExcludedAccount(provider: .chatGPT, accountId: "chatgpt.com", displayLabel: "ChatGPT")
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(cliLoginReader: reader, scanExcludedAccounts: [exclusion])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
    }

    func test_reconcile_chatGPTExclusionKeyedLegacyPlaceholder_blocksEveryAdd() async throws {
        let exclusion = ScanExcludedAccount(provider: .chatGPT, accountId: "chatgpt.legacy", displayLabel: "ChatGPT")
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(cliLoginReader: reader, scanExcludedAccounts: [exclusion])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
    }

    func test_reconcile_unresolvedLegacyChatGPTAccountPresent_addsNothingThatCycle() async throws {
        let legacy = ChatGPTAccount.legacyPrimary(customLabel: nil)
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(
            cliLoginReader: reader,
            chatGPTAccounts: [legacy],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.map(\.id), [ChatGPTAccount.unidentifiedId])
    }

    // MARK: - Idempotency and empty snapshot (CLI-08, CLI-07 edges)

    func test_reconcile_sameSnapshotTwice_leavesAccountsUnchanged() async throws {
        let claudeLogin = Self.claudeLogin(organizationId: Self.orgC1)
        let codex = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codex, claude: [claudeLogin]))
        let appModel = makeAppModel(cliLoginReader: reader)

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        let claudeAfterFirst = appModel.settings.claudeAccounts
        let chatGPTAfterFirst = appModel.settings.chatGPTAccounts
        XCTAssertEqual(claudeAfterFirst.count, 1)
        XCTAssertEqual(chatGPTAfterFirst.count, 1)

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.claudeAccounts, claudeAfterFirst)
        XCTAssertEqual(appModel.settings.chatGPTAccounts, chatGPTAfterFirst)
    }

    func test_reconcile_emptySnapshot_existingCLIOriginAccountStays() async throws {
        let existingCLI = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let reader = CLILoginReaderFake(snapshot: .empty)
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [existingCLI])

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.claudeAccounts, [existingCLI])
        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
    }

    // MARK: - D-04 (never touches a stored credential)

    func test_reconcile_neverTouchesKeychainOrChatGPTSessionRepository() async throws {
        let claudeLoginC1 = Self.claudeLogin(organizationId: Self.orgC1)
        let codex = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codex, claude: [claudeLoginC1]))
        let keychain = KeychainRepositoryFake()
        let sessionRepository = ReconciliationChatGPTSessionRepositoryFake()
        let appModel = makeAppModel(
            cliLoginReader: reader,
            keychainRepository: keychain,
            chatGPTSessionRepository: sessionRepository
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        // A second cycle exercises the "already connected" merge path too.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let keychainSaves = await keychain.saveCallCount
        let keychainDeletes = await keychain.deleteCallCount
        let sessionSaves = await sessionRepository.saveCallCount
        let sessionClears = await sessionRepository.clearCallCount
        XCTAssertEqual(keychainSaves, 0)
        XCTAssertEqual(keychainDeletes, 0)
        XCTAssertEqual(sessionSaves, 0)
        XCTAssertEqual(sessionClears, 0)
    }

    // MARK: - Removal stays removed (D-01, CLI-07)

    func test_removeClaudeAccount_loneCLIOriginAccount_doesNotRunClearSessionKeyAndStaysRemoved() async throws {
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "unrelated-default-key", account: "default")
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [cliAccount], keychainRepository: keychain)
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeClaudeAccount(id: cliAccount.id)

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.claude(cliAccount).id })
        let stillHasDefaultKey = await keychain.hasSessionKey
        XCTAssertTrue(stillHasDefaultKey, "clearSessionKey must not run for a lone CLI-origin account")

        // The exclusion must outrank the next reconciliation.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
    }

    func test_removeClaudeAccount_cookieBackedAccountWithMatchingCLILogin_recordsExclusion() async throws {
        let primary = ClaudeAccount(
            id: "primary-org",
            label: "Primary",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b0")!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let cookieAccount = ClaudeAccount(id: "cookie-id", label: "Cookie Org", organizationId: Self.orgC1, keychainAccount: "cookie-id")
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [primary, cookieAccount], isSetupComplete: true)
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeClaudeAccount(id: cookieAccount.id)

        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.claude(cookieAccount).id })
    }

    func test_removeClaudeAccount_cookieBackedAccountWithNoCLILogin_recordsNoExclusion() async throws {
        let primary = ClaudeAccount(
            id: "primary-org",
            label: "Primary",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b0")!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let cookieAccount = ClaudeAccount(id: "cookie-id", label: "Cookie Org", organizationId: Self.orgC2, keychainAccount: "cookie-id")
        let reader = CLILoginReaderFake(snapshot: .empty)
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [primary, cookieAccount], isSetupComplete: true)
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeClaudeAccount(id: cookieAccount.id)

        XCTAssertTrue(appModel.settings.scanExcludedAccounts.isEmpty)
    }

    func test_removeClaudeAccount_primaryWithOnlyCLIOriginRemaining_runsClearSessionKeyWithoutPromotionAttempt() async throws {
        let primary = ClaudeAccount(
            id: "primary-org",
            label: "Primary",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b0")!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "default-key", account: "default")
        let appModel = makeAppModel(
            cliLoginReader: reader,
            claudeAccounts: [primary, cliAccount],
            isSetupComplete: true,
            keychainRepository: keychain
        )
        await appModel.refreshCLILoginSnapshot()

        // If the CLI-origin candidate were ever handed to
        // `keychainRepository.retrieve`, that call would throw (no Keychain
        // entry exists for it) and this `try` would fail the test -- so a
        // clean pass here is itself proof no promotion was attempted.
        try await appModel.removeClaudeAccount(id: primary.id)

        XCTAssertEqual(appModel.settings.claudeAccounts, [cliAccount])
        let hasDefaultKey = await keychain.hasSessionKey
        XCTAssertFalse(hasDefaultKey, "clearSessionKey must have deleted the default slot")
    }

    func test_removeClaudeAccount_lonePrimaryCookieAccountMatchingCLILogin_staysRemovedAfterRefresh() async throws {
        // Covers the `count > 1` early-return branch in `removeClaudeAccount`:
        // the lone primary account has no CLI `origin` tag, but the CLI
        // snapshot already holds a login for the same organization, so
        // `wasCLIBacked` is true via the login match, not the origin flag.
        let primary = ClaudeAccount(id: Self.orgC1LowercaseString, label: "Example Org", organizationId: Self.orgC1, keychainAccount: ClaudeAccount.primaryKeychainAccount)
        let login = Self.claudeLogin(organizationId: Self.orgC1)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [login]))
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "default-key", account: "default")
        let appModel = makeAppModel(cliLoginReader: reader, claudeAccounts: [primary], isSetupComplete: true, keychainRepository: keychain)
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeClaudeAccount(id: primary.id)

        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.claude(primary).id })

        // The exclusion must outrank the next reconciliation.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertTrue(appModel.settings.claudeAccounts.isEmpty)
    }

    func test_removeClaudeAccount_primaryMatchingCLILoginWithOnlyCLIOriginRemaining_staysRemovedAfterRefresh() async throws {
        // Covers the `guard let promoted else` early-return branch: the
        // primary itself matches a CLI login (so `wasCLIBacked` is true), and
        // the only other account is CLI-origin so it can never be promoted.
        let primary = ClaudeAccount(id: Self.orgC2LowercaseString, label: "Primary", organizationId: Self.orgC2, keychainAccount: ClaudeAccount.primaryKeychainAccount)
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let loginC1 = Self.claudeLogin(organizationId: Self.orgC1)
        let loginC2 = Self.claudeLogin(organizationId: Self.orgC2)
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: nil, claude: [loginC1, loginC2]))
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "default-key", account: "default")
        let appModel = makeAppModel(
            cliLoginReader: reader,
            claudeAccounts: [primary, cliAccount],
            isSetupComplete: true,
            keychainRepository: keychain
        )
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeClaudeAccount(id: primary.id)

        XCTAssertEqual(appModel.settings.claudeAccounts, [cliAccount])
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.claude(primary).id })

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertEqual(appModel.settings.claudeAccounts, [cliAccount], "the removed primary must not come back as a second account")
    }

    func test_clearSessionKey_keepsCLIOriginAccountRemovesOthers() async throws {
        let primary = ClaudeAccount(
            id: "primary-org",
            label: "Primary",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b0")!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let cookieAdditional = ClaudeAccount(
            id: "cookie-additional",
            label: "Cookie Additional",
            organizationId: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
            keychainAccount: "cookie-additional"
        )
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "default-key", account: "default")
        try await keychain.save(sessionKey: "cookie-key", account: "cookie-additional")
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            claudeAccounts: [primary, cookieAdditional, cliAccount],
            isSetupComplete: true,
            keychainRepository: keychain
        )

        try await appModel.clearSessionKey()

        XCTAssertEqual(appModel.settings.claudeAccounts, [cliAccount])
        let hasDefaultKey = await keychain.hasSessionKey
        XCTAssertFalse(hasDefaultKey)
        let stillHasCookieAdditional = await keychain.exists(account: "cookie-additional")
        XCTAssertFalse(stillHasCookieAdditional)
    }

    func test_removeChatGPTAccount_cliOriginAccount_recordsExclusionAndStaysRemoved() async throws {
        let cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            planType: "pro",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        let login = Self.codexLogin()
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(
            cliLoginReader: reader,
            chatGPTAccounts: [cliAccount],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeChatGPTAccount(id: cliAccount.id)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.chatGPT(cliAccount).id })

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty, "the exclusion must block re-add on the next refresh")
    }

    func test_clearChatGPTSessionCookie_keepsCLIOriginAccount_usageShownStaysTrue() async throws {
        let primary = ChatGPTAccount(id: "chatgpt.com", label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        let sessionRepository = ReconciliationChatGPTSessionRepositoryFake()
        await sessionRepository.seed(ChatGPTSession(sessionCookie: "primary-cookie-redacted"), account: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [primary, cliAccount],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true,
            chatGPTSessionRepository: sessionRepository
        )

        try await appModel.clearChatGPTSessionCookie()

        XCTAssertEqual(appModel.settings.chatGPTAccounts, [cliAccount])
        XCTAssertTrue(appModel.settings.isChatGPTUsageShown)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
    }

    func test_clearChatGPTSessionCookie_noCLIOriginAccountRemains_usageShownBecomesFalse() async throws {
        let primary = ChatGPTAccount(id: "chatgpt.com", label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [primary],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )

        try await appModel.clearChatGPTSessionCookie()

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
    }

    func test_excludeChatGPTAccountFromScansAll_excludesAndRemovesCLIOriginAccountToo() async throws {
        let primary = ChatGPTAccount(id: "chatgpt.com", label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [primary, cliAccount],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )

        try await appModel.excludeChatGPTAccountFromScans()

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.chatGPT(cliAccount).id })
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.chatGPT(primary).id })
    }

    func test_removeChatGPTAccount_lonePrimaryCookieAccountMatchingCLILogin_staysRemovedAfterRefresh() async throws {
        // Covers the `guard let successor = promoted?.account ... else` early
        // return in `removeChatGPTAccount`: the primary has no CLI `origin`
        // tag, but the CLI snapshot already holds a login for the same
        // ChatGPT user id, so `wasCLIBacked` is true via the login match, and
        // there is no other account to promote.
        let primary = ChatGPTAccount(id: "user-synthetic-0002", label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let login = Self.codexLogin(chatgptUserId: "user-synthetic-0002")
        let reader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: login, claude: []))
        let appModel = makeAppModel(
            cliLoginReader: reader,
            chatGPTAccounts: [primary],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )
        await appModel.refreshCLILoginSnapshot()

        try await appModel.removeChatGPTAccount(id: primary.id)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.contains { $0.id == ScanExcludedAccount.chatGPT(primary).id })

        // The exclusion must outrank the next reconciliation, and the
        // usage-shown toggle must not flip back on via the `wasEmpty` path.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
    }

    func test_removeChatGPTAccount_primaryPromotion_skipsCLIOriginCandidate() async throws {
        let primary = ChatGPTAccount(id: "primary-user", label: "Primary", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "CLI",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        let cookieAdditional = ChatGPTAccount(id: "cookie-user", label: "Cookie", keychainAccount: "cookie-user")
        let sessionRepository = ReconciliationChatGPTSessionRepositoryFake()
        await sessionRepository.seed(ChatGPTSession(sessionCookie: "primary-cookie-redacted"), account: ChatGPTAccount.primaryKeychainAccount)
        await sessionRepository.seed(ChatGPTSession(sessionCookie: "cookie-additional-cookie-redacted"), account: "cookie-user")
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [primary, cliAccount, cookieAdditional],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true,
            chatGPTSessionRepository: sessionRepository
        )

        try await appModel.removeChatGPTAccount(id: primary.id)

        let newPrimary = appModel.settings.chatGPTAccounts.first(where: \.isPrimary)
        XCTAssertEqual(newPrimary?.id, "cookie-user", "the CLI-origin account must never be a promotion candidate")
        XCTAssertTrue(appModel.settings.chatGPTAccounts.contains(cliAccount))
    }

    // MARK: - Maintenance paths keep CLI-origin accounts (RESEARCH Pitfall 8)

    func test_connectClaudeAccounts_candidatesWithoutCLIOrg_keepsCLIOriginAccountAndUsage() async throws {
        var cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        cliAccount.customLabel = "My CLI Org"
        let discoveredOrg = Organization(id: 1, uuid: "00000000-0000-0000-0000-0000000000d1", name: "Discovered Org", capabilities: ["chat"])
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(ReconciliationStubError.notConfigured),
            organizations: [discoveredOrg],
            isSessionKeyValid: true
        )
        let appModel = makeAppModel(cliLoginReader: CLILoginReaderFake(), usageService: usageService)
        appModel.settings.claudeAccounts = [cliAccount]
        appModel.claudeAccountUsage[cliAccount.id] = UsageData(
            sessionUsage: UsageLimit(utilization: 5, resetAt: Date().addingTimeInterval(3600)),
            weeklyUsage: UsageLimit(utilization: 5, resetAt: Date().addingTimeInterval(86400)),
            sonnetUsage: nil,
            lastUpdated: Date()
        )

        _ = try await appModel.connectClaudeAccounts(importedKeys: [
            ImportedSessionKey(value: "sk-ant-fake-test-key-1234567890", sourceDescription: "Chrome Default")
        ])

        XCTAssertTrue(appModel.settings.claudeAccounts.contains(where: { $0.id == cliAccount.id && $0.customLabel == "My CLI Org" }))
        XCTAssertNotNil(appModel.claudeAccountUsage[cliAccount.id])
    }

    func test_connectClaudeAccounts_candidateRediscoversCLIOrg_rebuildsCookieBackedWithNilOrigin() async throws {
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        let discoveredOrg = Organization(id: 1, uuid: Self.orgC1LowercaseString, name: "Example Org", capabilities: ["chat"])
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(ReconciliationStubError.notConfigured),
            organizations: [discoveredOrg],
            isSessionKeyValid: true
        )
        let appModel = makeAppModel(cliLoginReader: CLILoginReaderFake(), usageService: usageService)
        appModel.settings.claudeAccounts = [cliAccount]

        _ = try await appModel.connectClaudeAccounts(importedKeys: [
            ImportedSessionKey(value: "sk-ant-fake-test-key-1234567890", sourceDescription: "Chrome Default")
        ])

        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1)
        let merged = try XCTUnwrap(appModel.settings.claudeAccounts.first)
        XCTAssertEqual(merged.organizationId, Self.orgC1)
        XCTAssertNil(merged.origin, "a rediscovered organization is rebuilt cookie-backed, merging the CLI-origin row")
        XCTAssertTrue(merged.isPrimary)
    }

    func test_validateAndSaveSessionKey_mergesExistingCLIOriginEntryForSameOrganizationRegardlessOfCase() async throws {
        let cliAccount = ClaudeAccount(
            id: Self.orgC1LowercaseString,
            label: "Example Org",
            organizationId: Self.orgC1,
            keychainAccount: Self.orgC1LowercaseString,
            origin: .cliLogin
        )
        // The API-reported uuid is uppercase-cased, unlike the
        // Keychain-derived lowercased CLI-origin id -- the two must still be
        // recognized as the same organization (registerPrimaryClaudeAccount).
        let org = Organization(id: 1, uuid: "00000000-0000-0000-0000-0000000000C1", name: "Example Org", capabilities: ["chat"])
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(ReconciliationStubError.notConfigured),
            organizations: [org],
            isSessionKeyValid: true
        )
        let appModel = makeAppModel(cliLoginReader: CLILoginReaderFake(), usageService: usageService)
        appModel.settings.claudeAccounts = [cliAccount]

        let saved = try await appModel.validateAndSaveSessionKey("sk-ant-fake-test-key-1234567890")

        XCTAssertTrue(saved)
        XCTAssertEqual(appModel.settings.claudeAccounts.count, 1, "the CLI-origin entry for the same org must merge, not duplicate")
        let merged = try XCTUnwrap(appModel.settings.claudeAccounts.first)
        XCTAssertTrue(merged.isPrimary)
        XCTAssertNil(merged.origin, "the merged account is now cookie-backed")
    }

    func test_connectChatGPTAccounts_candidatesWithoutCLIAccount_keepsCLIOriginAccountAndUsage() async throws {
        var cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        cliAccount.customLabel = "My CLI Account"
        let appModel = makeAppModel(cliLoginReader: CLILoginReaderFake(), chatGPTAccounts: [cliAccount])
        appModel.chatGPTAccountUsage[cliAccount.id] = Self.makeChatGPTUsage()

        _ = try await appModel.connectChatGPTAccounts(importedCookies: [
            ImportedChatGPTSessionCookie(cookieHeader: "sessionKey=abc123redacted", sourceDescription: "Chrome Default")
        ])

        XCTAssertTrue(appModel.settings.chatGPTAccounts.contains { $0.id == cliAccount.id && $0.customLabel == "My CLI Account" })
        XCTAssertNotNil(appModel.chatGPTAccountUsage[cliAccount.id])
    }

    // MARK: - applyChatGPTIdentity preserves origin

    func test_applyChatGPTIdentity_viaAdditionalAccountPoll_preservesCLIOriginMarker() async throws {
        let cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [cliAccount],
            isChatGPTUsageShown: true,
            hasChatGPTSessionCookie: true
        )
        await appModel.refreshCLILoginSnapshot()

        await appModel.refreshAdditionalChatGPTAccounts()

        let updated = try XCTUnwrap(
            appModel.settings.chatGPTAccounts.first(where: { $0.keychainAccount == cliAccount.keychainAccount })
        )
        XCTAssertEqual(updated.origin, .cliLogin)
    }

    // MARK: - applyChatGPTIdentity merges a pasted-cookie collision (D-03)

    func test_validateAndSaveChatGPTSessionCookie_mergesExistingCLIOriginEntryForSameIdentity() async throws {
        // A CLI login already auto-connected this identity as a non-primary
        // CLI-origin account. Pasting a cookie that resolves to the SAME
        // identity must merge into the new primary slot, not leave a
        // duplicate non-primary row behind (mirrors
        // `validateAndSaveSessionKey`'s Claude-side merge).
        var cliAccount = ChatGPTAccount(
            id: "user-synthetic-0002",
            label: "user@example.com",
            planType: "pro",
            keychainAccount: "user-synthetic-0002",
            origin: .cliLogin
        )
        cliAccount.customLabel = "My CLI Account"
        let identity = ChatGPTAccountIdentity(userId: "user-synthetic-0002", accountId: nil, email: "user@example.com", planType: "pro")
        let usageService = ChatGPTIdentityMergeUsageServiceStub(identity: identity)
        // Pre-seed the removed CLI-origin row's own usage cache entry (keyed
        // by ITS keychainAccount, "user-synthetic-0002", not the pasted
        // cookie's "default" primary slot) so the test can prove the merge
        // clears it rather than leaving it orphaned on disk forever.
        let usageCacheRepository = ChatGPTUsageCacheRepositoryFake(
            savedData: Self.makeChatGPTUsage(),
            account: cliAccount.keychainAccount
        )
        let appModel = makeAppModel(
            cliLoginReader: CLILoginReaderFake(),
            chatGPTAccounts: [cliAccount],
            chatGPTUsageCacheRepository: usageCacheRepository,
            chatGPTUsageService: usageService
        )

        let saved = try await appModel.validateAndSaveChatGPTSessionCookie("sessionKey=abc123redacted")

        XCTAssertTrue(saved)
        XCTAssertEqual(appModel.settings.chatGPTAccounts.count, 1, "the CLI-origin entry for the same identity must merge, not duplicate")
        let merged = try XCTUnwrap(appModel.settings.chatGPTAccounts.first)
        XCTAssertTrue(merged.isPrimary)
        XCTAssertEqual(merged.id, "user-synthetic-0002")
        XCTAssertEqual(merged.customLabel, "My CLI Account", "the CLI-origin entry's custom label is carried over")
        XCTAssertFalse(merged.isCLIOrigin, "the merged account is now cookie-backed")
        XCTAssertFalse(
            appModel.settings.chatGPTAccounts.contains { $0.id == ChatGPTAccount.unidentifiedId },
            "no unresolved-primary placeholder must remain to block future Codex logins from auto-connecting"
        )
        let removedRowCache = await usageCacheRepository.load(account: cliAccount.keychainAccount)
        XCTAssertNil(removedRowCache, "the removed CLI-origin row's own usage cache entry must be cleared, not orphaned")
        let clearCallCount = await usageCacheRepository.clearCallCount
        XCTAssertEqual(clearCallCount, 1)
    }
}

// MARK: - Test doubles

private enum ReconciliationStubError: Error {
    case notConfigured
}

/// Always succeeds with a fixed, synthetic usage payload so a reconciled
/// CLI-origin account's first poll (driven transitively by
/// `refreshConfiguredUsageProviders`) never surfaces an unrelated error in a
/// reconciliation-focused test. Never touches a Keychain or network socket.
private actor ReconciliationClaudeOAuthUsageServiceStub: ClaudeOAuthUsageServiceProtocol {
    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        UsageData(
            sessionUsage: UsageLimit(utilization: 1, resetAt: Date().addingTimeInterval(3600)),
            weeklyUsage: UsageLimit(utilization: 1, resetAt: Date().addingTimeInterval(86400)),
            sonnetUsage: nil,
            lastUpdated: Date()
        )
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        throw ReconciliationStubError.notConfigured
    }
}

/// Always succeeds with a fixed, synthetic usage payload for both the bearer
/// (Codex CLI) and cookie paths, so a reconciled CLI-origin ChatGPT
/// account's first poll never needs the stored-cookie path at all.
private actor ReconciliationChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    func fetchUsage() async throws -> ChatGPTUsageData {
        ChatGPTUsageData(rows: [], lastUpdated: Date())
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool { true }

    func fetchUsageAndIdentity(
        codexCLILogin: CodexCLILogin
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        (ChatGPTUsageData(rows: [], lastUpdated: Date()), .unidentified)
    }
}

/// A `ChatGPTSessionRepositoryProtocol` conformer that counts `save` and
/// `clear` calls, so a reconciliation test can assert D-04 (never touches a
/// stored cookie) without a real Keychain.
actor ReconciliationChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    func seed(_ session: ChatGPTSession, account: String) {
        sessions[account] = session
    }

    func save(_ session: ChatGPTSession, account: String) async throws {
        saveCallCount += 1
        sessions[account] = session
    }

    func load(account: String) async throws -> ChatGPTSession {
        guard let session = sessions[account] else { throw ChatGPTSessionRepositoryError.notFound }
        return session
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        sessions[account] == nil
            ? ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            : ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func clear(account: String) async throws {
        clearCallCount += 1
        sessions[account] = nil
    }
}

/// Validates any cookie and resolves the stored-cookie identity poll to a
/// fixed, configurable identity -- so a test can simulate a pasted cookie
/// resolving to the same identity an existing CLI-origin account already
/// holds (the `applyChatGPTIdentity` merge path).
private actor ChatGPTIdentityMergeUsageServiceStub: ChatGPTUsageServiceProtocol {
    private let identity: ChatGPTAccountIdentity

    init(identity: ChatGPTAccountIdentity) {
        self.identity = identity
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        ChatGPTUsageData(rows: [], lastUpdated: Date())
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        (try await fetchUsage(), identity)
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool { true }
}
