import XCTest
@testable import Pinemeter

@MainActor
final class BrowserSessionImportTests: XCTestCase {
    private static let existingKey = "sk-ant-existing-00000000001"
    private static let selectedKey = "sk-ant-selected-00000000001"
    private static let skippedKey = "sk-ant-skipped-000000000001"
    private static let existingID = "11111111-1111-1111-1111-111111111111"
    private static let selectedID = "22222222-2222-2222-2222-222222222222"
    private static let skippedID = "33333333-3333-3333-3333-333333333333"
    private static let existingCookie = "__Secure-next-auth.session-token=existing-cookie"
    private static let selectedCookie = "__Secure-next-auth.session-token=selected-cookie"
    private static let skippedCookie = "__Secure-next-auth.session-token=skipped-cookie"
    private static let existingChatGPTID = "user-existing"
    private static let selectedChatGPTID = "user-selected"
    private static let skippedChatGPTID = "user-skipped"

    func test_discoveryReturnsOpaqueRowsWithoutPersistingCredentialsOrSettings() async throws {
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let importService = BrowserImportServiceFake(keys: [
            .init(value: Self.selectedKey, sourceDescription: "Chrome Profile 2"),
            .init(value: Self.skippedKey, sourceDescription: "Chrome Profile 7"),
        ])
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: BrowserImportUsageService(organizationsByKey: [:]),
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService,
            runningBrowserSources: { [.chrome] }
        )

        let review = await appModel.discoverBrowserSessions()

        XCTAssertEqual(review.sessions.map(\.profileLabel), ["Chrome Profile 2", "Chrome Profile 7"])
        XCTAssertEqual(review.sessions.map(\.provider), [.claude, .claude])
        XCTAssertEqual(Set(review.sessions.map(\.id)).count, 2)
        XCTAssertFalse(String(reflecting: review).contains(Self.selectedKey))
        let firstSession = try XCTUnwrap(review.sessions.first)
        XCTAssertFalse(String(reflecting: firstSession).contains(Self.selectedKey))
        XCTAssertFalse(String(reflecting: firstSession.credential).contains(Self.selectedKey))
        let storedCredentialExists = await keychainRepository.exists(account: ClaudeAccount.primaryKeychainAccount)
        let storedSettings = await settingsRepository.load()
        XCTAssertFalse(storedCredentialExists)
        XCTAssertEqual(storedSettings, .default)
        XCTAssertEqual(appModel.settings, .default)
    }

    func test_connectingSelectedRowPreservesExistingAccountAndSkipsUnselectedRow() async throws {
        let existing = organization(id: 1, uuid: Self.existingID, name: "Existing")
        let selected = organization(id: 2, uuid: Self.selectedID, name: "Selected")
        let skipped = organization(id: 3, uuid: Self.skippedID, name: "Skipped")
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(
            sessionKey: Self.existingKey,
            account: ClaudeAccount.primaryKeychainAccount
        )
        let importService = BrowserImportServiceFake(keys: [
            .init(value: Self.selectedKey, sourceDescription: "Chrome Profile 2"),
            .init(value: Self.skippedKey, sourceDescription: "Chrome Profile 7"),
        ])
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: BrowserImportUsageService(organizationsByKey: [
                Self.existingKey: [existing],
                Self.selectedKey: [selected],
                Self.skippedKey: [skipped],
            ]),
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService,
            runningBrowserSources: { [.chrome] }
        )
        appModel.settings.claudeAccounts = [ClaudeAccount(
            id: Self.existingID,
            label: "Existing",
            organizationId: try XCTUnwrap(existing.organizationUUID),
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: "Safari Personal",
            customLabel: "Keep me"
        )]

        let review = await appModel.discoverBrowserSessions()
        let selectedRow = try XCTUnwrap(review.sessions.first { $0.profileLabel == "Chrome Profile 2" })
        _ = await appModel.connectBrowserSessions([selectedRow])

        XCTAssertEqual(Set(appModel.settings.claudeAccounts.map(\.id)), Set([Self.existingID, Self.selectedID]))
        XCTAssertFalse(appModel.settings.claudeAccounts.contains { $0.id == Self.skippedID })
        XCTAssertEqual(appModel.settings.claudeAccounts.first { $0.id == Self.existingID }?.customLabel, "Keep me")
        let savedPrimaryKey = try await keychainRepository.retrieve(account: ClaudeAccount.primaryKeychainAccount)
        XCTAssertEqual(savedPrimaryKey, Self.existingKey)
    }

    func test_automaticRecoveryDoesNotConnectANewlyDiscoveredAccount() async throws {
        let existing = organization(id: 1, uuid: Self.existingID, name: "Existing")
        let selected = organization(id: 2, uuid: Self.selectedID, name: "Selected")
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(
            sessionKey: Self.existingKey,
            account: ClaudeAccount.primaryKeychainAccount
        )
        let usageService = BrowserImportUsageService(
            fetchUsageError: AppError.sessionKeyInvalid,
            organizationsByKey: [Self.selectedKey: [selected]]
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: BrowserImportServiceFake(keys: [
                .init(value: Self.selectedKey, sourceDescription: "Chrome Profile 2")
            ]),
            runningBrowserSources: { [.chrome] },
            browserLoginPrompt: { _ in }
        )
        let original = ClaudeAccount(
            id: Self.existingID,
            label: "Existing",
            organizationId: try XCTUnwrap(existing.organizationUUID),
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: "Safari Personal",
            customLabel: "Keep me"
        )
        appModel.settings.claudeAccounts = [original]
        appModel.isSetupComplete = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.settings.claudeAccounts, [original])
        let savedPrimaryKey = try await keychainRepository.retrieve(account: ClaudeAccount.primaryKeychainAccount)
        XCTAssertEqual(savedPrimaryKey, Self.existingKey)
    }

    func test_connectingSelectedChatGPTRowPreservesExistingAccountAndSkipsUnselectedRow() async throws {
        let sessionRepository = BrowserImportChatGPTSessionRepository()
        try await sessionRepository.save(
            .init(sessionCookie: Self.existingCookie),
            account: ChatGPTAccount.primaryKeychainAccount
        )
        let usageService = BrowserImportChatGPTUsageService(byCookie: [
            Self.existingCookie: .init(
                userId: Self.existingChatGPTID,
                accountId: nil,
                email: "existing@example.com",
                planType: "pro"
            ),
            Self.selectedCookie: .init(
                userId: Self.selectedChatGPTID,
                accountId: nil,
                email: "selected@example.com",
                planType: "plus"
            ),
            Self.skippedCookie: .init(
                userId: Self.skippedChatGPTID,
                accountId: nil,
                email: "skipped@example.com",
                planType: "free"
            ),
        ])
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: BrowserImportUsageService(organizationsByKey: [:]),
            chatGPTUsageService: usageService,
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: BrowserImportServiceFake(keys: [], cookies: [
                .init(cookieHeader: Self.selectedCookie, sourceDescription: "Chrome Profile 2"),
                .init(cookieHeader: Self.skippedCookie, sourceDescription: "Chrome Profile 7"),
            ]),
            runningBrowserSources: { [.chrome] },
            browserLoginPrompt: { _ in }
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [ChatGPTAccount(
            id: Self.existingChatGPTID,
            label: "existing@example.com",
            planType: "pro",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount,
            profileLabel: "Safari Personal",
            customLabel: "Keep GPT"
        )]

        let review = await appModel.discoverBrowserSessions()
        let selectedRow = try XCTUnwrap(review.sessions.first { $0.profileLabel == "Chrome Profile 2" })
        _ = await appModel.connectBrowserSessions([selectedRow])

        XCTAssertEqual(
            Set(appModel.settings.chatGPTAccounts.map(\.id)),
            Set([Self.existingChatGPTID, Self.selectedChatGPTID])
        )
        XCTAssertFalse(appModel.settings.chatGPTAccounts.contains { $0.id == Self.skippedChatGPTID })
        XCTAssertEqual(
            appModel.settings.chatGPTAccounts.first { $0.id == Self.existingChatGPTID }?.customLabel,
            "Keep GPT"
        )
        let savedPrimary = try await sessionRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertEqual(savedPrimary.sessionCookie, Self.existingCookie)
    }

    func test_invalidSelectedSessionIsNotReportedConnectedWhenRetainedAccountRefreshes() async throws {
        let existing = organization(id: 1, uuid: Self.existingID, name: "Existing")
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(
            sessionKey: Self.existingKey,
            account: ClaudeAccount.primaryKeychainAccount
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: BrowserImportUsageService(organizationsByKey: [Self.existingKey: [existing]]),
            notificationService: NotificationServiceSpy(),
            browserLoginPrompt: { _ in }
        )
        appModel.settings.claudeAccounts = [ClaudeAccount(
            id: Self.existingID,
            label: "Existing",
            organizationId: try XCTUnwrap(existing.organizationUUID),
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: "Safari Personal"
        )]
        let invalidSelection = BrowserSessionImportSession(
            provider: .claude,
            source: .chrome,
            profileLabel: "Chrome Profile 9",
            credential: .claudeSessionKey(Self.selectedKey)
        )

        let outcome = await appModel.connectBrowserSessions([invalidSelection])

        XCTAssertEqual(outcome.totalImported, 0)
        guard case .failed = try XCTUnwrap(outcome.results.first).claude else {
            return XCTFail("An invalid selected session must report failure")
        }
        XCTAssertEqual(appModel.settings.claudeAccounts.map(\.id), [Self.existingID])
    }

    func test_emptySelectionDoesNotChangeConnectedAccounts() async throws {
        let existing = organization(id: 1, uuid: Self.existingID, name: "Existing")
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: BrowserImportUsageService(organizationsByKey: [:]),
            notificationService: NotificationServiceSpy(),
            browserLoginPrompt: { _ in }
        )
        let account = ClaudeAccount(
            id: Self.existingID,
            label: "Existing",
            organizationId: try XCTUnwrap(existing.organizationUUID),
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        appModel.settings.claudeAccounts = [account]

        let outcome = await appModel.connectBrowserSessions([])

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(appModel.settings.claudeAccounts, [account])
    }

    func test_mixedSelectionReportsProviderSuccessAndFailureIndependently() async {
        let selected = organization(id: 2, uuid: Self.selectedID, name: "Selected")
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: BrowserImportUsageService(organizationsByKey: [Self.selectedKey: [selected]]),
            chatGPTUsageService: BrowserImportChatGPTUsageService(byCookie: [:]),
            chatGPTSessionRepository: BrowserImportChatGPTSessionRepository(),
            notificationService: NotificationServiceSpy(),
            browserLoginPrompt: { _ in }
        )
        let sessions = [
            BrowserSessionImportSession(
                provider: .claude,
                source: .chrome,
                profileLabel: "Chrome Profile 2",
                credential: .claudeSessionKey(Self.selectedKey)
            ),
            BrowserSessionImportSession(
                provider: .chatGPT,
                source: .chrome,
                profileLabel: "Chrome Work",
                credential: .chatGPTCookie(Self.selectedCookie)
            ),
            BrowserSessionImportSession(
                provider: .chatGPT,
                source: .chrome,
                profileLabel: "Chrome Personal",
                credential: .chatGPTCookie(Self.skippedCookie)
            ),
        ]

        let outcome = await appModel.connectBrowserSessions(sessions)

        XCTAssertTrue(outcome.claudeImported)
        XCTAssertFalse(outcome.chatGPTImported)
        XCTAssertEqual(outcome.totalImported, 1)
    }

    func test_restrictedChatGPTRecoveryNeverStoresAnUnapprovedCookie() async throws {
        let repository = BrowserImportChatGPTSessionRepository()
        let controller = ChatGPTAccountConnectionController(
            usageService: BrowserImportChatGPTUsageService(byCookie: [
                Self.selectedCookie: .init(userId: Self.selectedChatGPTID, accountId: nil, email: nil, planType: nil)
            ]),
            sessionRepository: repository
        )
        let original = ChatGPTAccount(id: Self.existingChatGPTID, label: "Keep identity", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        do {
            _ = try await controller.connect(
                importedCookies: [.init(cookieHeader: Self.selectedCookie, sourceDescription: "Chrome")],
                preserveExistingAccounts: true,
                allowedAccountIds: [Self.existingChatGPTID],
                excludedAccountIds: { [] }, currentAccounts: { [original] }, progress: { _ in }
            )
            XCTFail("Recovery must reject a different identity")
        } catch {}
        let state = await repository.validate(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertEqual(state.state, .missing)
    }

    func test_duplicateBrowserSessionsReportEveryValidatedSourceAsConnected() async throws {
        let org = organization(id: 1, uuid: Self.selectedID, name: "One account")
        let claude = ClaudeAccountConnectionController(
            usageService: BrowserImportUsageService(organizationsByKey: [Self.selectedKey: [org], Self.skippedKey: [org]]),
            keychainRepository: KeychainRepositoryFake()
        )
        let keys = [ImportedSessionKey(value: Self.selectedKey, sourceDescription: "Chrome"),
                    ImportedSessionKey(value: Self.skippedKey, sourceDescription: "Safari")]
        let connectedClaude = try await claude.connect(importedKeys: keys, excludedAccountIds: { [] }, currentAccounts: { [] }, progress: { _ in }, connectPrimary: { _ in true })
        XCTAssertEqual(connectedClaude.accounts.count, 1)
        XCTAssertEqual(Set(connectedClaude.result.connected.map(\.value)), Set(keys.map(\.value)))

        let identity = ChatGPTAccountIdentity(userId: Self.selectedChatGPTID, accountId: nil, email: nil, planType: nil)
        let chatGPT = ChatGPTAccountConnectionController(
            usageService: BrowserImportChatGPTUsageService(byCookie: [Self.selectedCookie: identity, Self.skippedCookie: identity]),
            sessionRepository: BrowserImportChatGPTSessionRepository()
        )
        let cookies = [ImportedChatGPTSessionCookie(cookieHeader: Self.selectedCookie, sourceDescription: "Chrome"),
                       ImportedChatGPTSessionCookie(cookieHeader: Self.skippedCookie, sourceDescription: "Safari")]
        let connectedChatGPT = try await chatGPT.connect(importedCookies: cookies, excludedAccountIds: { [] }, currentAccounts: { [] }, progress: { _ in })
        XCTAssertEqual(connectedChatGPT.accounts.count, 1)
        XCTAssertEqual(Set(connectedChatGPT.connected.map(\.cookieHeader)), Set(cookies.map(\.cookieHeader)))
    }

    func test_unavailablePrimaryHasActionableRecoveryWithoutChangingCredentials() async throws {
        let org = organization(id: 1, uuid: Self.selectedID, name: "Selected")
        let repository = KeychainRepositoryFake()
        let controller = ClaudeAccountConnectionController(
            usageService: BrowserImportUsageService(organizationsByKey: [Self.selectedKey: [org]]),
            keychainRepository: repository
        )
        let original = ClaudeAccount(id: Self.existingID, label: "Personal", organizationId: UUID(uuidString: Self.existingID)!, keychainAccount: ClaudeAccount.primaryKeychainAccount)
        do {
            _ = try await controller.connect(
                importedKeys: [.init(value: Self.selectedKey, sourceDescription: "Chrome")],
                preserveExistingAccounts: true,
                excludedAccountIds: { [] }, currentAccounts: { [original] }, progress: { _ in }, connectPrimary: { _ in XCTFail("Must preserve primary"); return true }
            )
            XCTFail("Missing primary requires recovery")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Personal"))
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
        }
        let hasPrimary = await repository.exists(account: ClaudeAccount.primaryKeychainAccount)
        XCTAssertFalse(hasPrimary)
    }

    func test_partialFailureWithinOneBrowserRetainsEachFailedProfile() async {
        let org = organization(id: 1, uuid: Self.selectedID, name: "Selected")
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(), usageService: BrowserImportUsageService(organizationsByKey: [Self.selectedKey: [org]]), notificationService: NotificationServiceSpy(), browserLoginPrompt: { _ in })
        let outcome = await model.connectBrowserSessions([
            .init(provider: .claude, source: .chrome, profileLabel: "Chrome Work", credential: .claudeSessionKey(Self.selectedKey)),
            .init(provider: .claude, source: .chrome, profileLabel: "Chrome Expired", credential: .claudeSessionKey(Self.skippedKey))
        ])
        XCTAssertTrue(outcome.claudeImported)
        XCTAssertEqual(outcome.sessionFailures.count, 1)
        XCTAssertTrue(outcome.sessionFailures.first?.contains("Chrome Expired") == true)
        XCTAssertFalse(outcome.sessionFailures.first?.contains(Self.skippedKey) == true)
    }

    func test_failedChatGPTValidationDoesNotClaimAccountsWereExcluded() async {
        let controller = ChatGPTAccountConnectionController(usageService: BrowserImportChatGPTUsageService(byCookie: [:]), sessionRepository: BrowserImportChatGPTSessionRepository())
        let original = ChatGPTAccount(id: Self.existingChatGPTID, label: "Existing", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        do {
            _ = try await controller.connect(importedCookies: [.init(cookieHeader: Self.selectedCookie, sourceDescription: "Chrome")], preserveExistingAccounts: true, excludedAccountIds: { [] }, currentAccounts: { [original] }, progress: { _ in })
            XCTFail("Validation must fail")
        } catch {
            guard case SessionKeyImportError.invalidImportedChatGPTSessionCookie = error else { return XCTFail("Expected validation failure, got \(error)") }
        }
    }

    func test_unidentifiedChatGPTProfilesAreNotAssumedToShareAnAccount() async throws {
        let controller = ChatGPTAccountConnectionController(usageService: BrowserImportChatGPTUsageService(byCookie: [Self.selectedCookie: .unidentified, Self.skippedCookie: .unidentified]), sessionRepository: BrowserImportChatGPTSessionRepository())
        let connection = try await controller.connect(importedCookies: [.init(cookieHeader: Self.selectedCookie, sourceDescription: "Chrome Work"), .init(cookieHeader: Self.skippedCookie, sourceDescription: "Chrome Personal")], excludedAccountIds: { [] }, currentAccounts: { [] }, progress: { _ in })
        XCTAssertEqual(connection.connected.map(\.cookieHeader), [Self.selectedCookie])
    }

    func test_partialDiscoveryPreservesFullDiskAccessRecoveryAfterConnection() async {
        let org = organization(id: 1, uuid: Self.selectedID, name: "Selected")
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(), usageService: BrowserImportUsageService(organizationsByKey: [Self.selectedKey: [org]]), notificationService: NotificationServiceSpy(), browserLoginPrompt: { _ in })
        let failure = BrowserSessionImportFailure(provider: .claude, source: .safari, message: SessionKeyImportError.safariAccessDenied.localizedDescription, offersFullDiskAccessSettings: true)
        let outcome = await model.connectBrowserSessions([.init(provider: .claude, source: .chrome, profileLabel: "Chrome", credential: .claudeSessionKey(Self.selectedKey))], discoveryFailures: [failure])
        XCTAssertTrue(outcome.claudeImported)
        XCTAssertTrue(outcome.offersFullDiskAccessSettings)
        XCTAssertEqual(outcome.discoveryFailures, [failure])
    }

    private func organization(id: Int, uuid: String, name: String) -> Organization {
        Organization(id: id, uuid: uuid, name: name, capabilities: ["chat"])
    }
}

private actor BrowserImportServiceFake: SessionKeyImportServiceProtocol {
    let keys: [ImportedSessionKey]
    let cookies: [ImportedChatGPTSessionCookie]

    init(keys: [ImportedSessionKey], cookies: [ImportedChatGPTSessionCookie] = []) {
        self.keys = keys
        self.cookies = cookies
    }

    func importSessionKey() async throws -> ImportedSessionKey { try await importSessionKey(from: .defaultBrowser) }

    func importSessionKey(from source: BrowserImportSource) async throws -> ImportedSessionKey {
        guard let first = keys.first else { throw SessionKeyImportError.noSessionKeyFound }
        return first
    }

    func importAllSessionKeys(from source: BrowserImportSource) async throws -> [ImportedSessionKey] {
        guard !keys.isEmpty else { throw SessionKeyImportError.noSessionKeyFound }
        return keys
    }

    func importChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        try await importChatGPTSessionCookie(from: .defaultBrowser)
    }

    func importChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        guard let first = cookies.first else { throw SessionKeyImportError.noChatGPTSessionCookieFound }
        return first
    }

    func importAllChatGPTSessionCookies(from source: BrowserImportSource) async throws -> [ImportedChatGPTSessionCookie] {
        guard !cookies.isEmpty else { throw SessionKeyImportError.noChatGPTSessionCookieFound }
        return cookies
    }

    func repairSavedSessionKey(account: String) async -> CredentialState {
        .init(identity: .init(provider: .claude, kind: .sessionKey), health: .valid)
    }
}

private actor BrowserImportChatGPTSessionRepository: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]

    func save(_ session: ChatGPTSession, account: String) async throws { sessions[account] = session }

    func load(account: String) async throws -> ChatGPTSession {
        guard let session = sessions[account] else { throw ChatGPTSessionRepositoryError.notFound }
        return session
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        sessions[account] == nil
            ? .init(state: .missing, lastErrorCategory: .notFound)
            : .init(state: .available, lastErrorCategory: nil)
    }

    func clear(account: String) async throws { sessions[account] = nil }
}

private actor BrowserImportChatGPTUsageService: ChatGPTUsageServiceProtocol {
    let byCookie: [String: ChatGPTAccountIdentity]

    init(byCookie: [String: ChatGPTAccountIdentity]) {
        self.byCookie = byCookie
    }

    func fetchUsage() async throws -> ChatGPTUsageData { usage() }
    func fetchUsage(account: String) async throws -> ChatGPTUsageData { usage() }
    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData { usage() }

    func fetchUsageAndIdentity(account: String) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        (usage(), .unidentified)
    }

    func fetchUsageAndIdentity(sessionCookie: String) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        guard let identity = byCookie[sessionCookie] else { throw ChatGPTUsageError.invalidSessionCookie }
        return (usage(), identity)
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        byCookie[sessionCookie] != nil
    }

    private func usage() -> ChatGPTUsageData {
        .init(
            rows: [.init(label: "Codex weekly", usedPercent: 10, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }
}

private actor BrowserImportUsageService: UsageServiceProtocol {
    let fetchUsageError: Error?
    let organizationsByKey: [String: [Organization]]

    init(fetchUsageError: Error? = nil, organizationsByKey: [String: [Organization]]) {
        self.fetchUsageError = fetchUsageError
        self.organizationsByKey = organizationsByKey
    }

    func fetchUsage(forceRefresh: Bool) async throws -> UsageData {
        if let fetchUsageError { throw fetchUsageError }
        return usage()
    }

    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool) async throws -> UsageData {
        usage()
    }

    func fetchOrganizations() async throws -> [Organization] { [] }

    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] {
        organizationsByKey[sessionKey.value] ?? []
    }

    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool {
        organizationsByKey[sessionKey.value] != nil
    }

    private func usage() -> UsageData {
        let now = Date()
        return UsageData(
            sessionUsage: .init(utilization: 10, resetAt: now.addingTimeInterval(3_600)),
            weeklyUsage: .init(utilization: 20, resetAt: now.addingTimeInterval(86_400)),
            sonnetUsage: nil,
            lastUpdated: now
        )
    }
}
