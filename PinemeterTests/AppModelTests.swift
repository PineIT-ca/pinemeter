import CommonCrypto
import XCTest
@testable import Pinemeter

@MainActor
final class AppModelTests: XCTestCase {
    func test_availableUpdate_usesNumericVersionComparison() {
        XCTAssertTrue(AvailableUpdate(version: "1.10.0").isNewer(than: "1.9.9"))
        XCTAssertTrue(AvailableUpdate(version: "2.0").isNewer(than: "1.99"))
        XCTAssertFalse(AvailableUpdate(version: "1.2.0").isNewer(than: "1.2.0"))
        XCTAssertFalse(AvailableUpdate(version: "1.2.0").isNewer(than: "1.2.1"))
    }

    func test_checkForUpdates_throttlesDailyNotifiesOnceAndPersistsAvailableVersion() async throws {
        let now = Date()
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.lastUpdateCheckAt = now
        try await settingsRepository.save(settings)
        let releaseCheckService = UpdateReleaseCheckServiceFake(update: AvailableUpdate(version: "1.10.0"))
        let notificationService = NotificationServiceSpy()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: notificationService,
            releaseCheckService: releaseCheckService,
            installedVersion: "1.9.9"
        )

        await appModel.bootstrap()
        await appModel.checkForUpdatesIfNeeded(now: now.addingTimeInterval(23 * 60 * 60))
        let throttledCallCount = await releaseCheckService.callCount
        XCTAssertEqual(throttledCallCount, 0)

        let firstCheck = now.addingTimeInterval(24 * 60 * 60)
        await appModel.checkForUpdatesIfNeeded(now: firstCheck)
        let firstCallCount = await releaseCheckService.callCount
        XCTAssertEqual(firstCallCount, 1)
        XCTAssertEqual(appModel.settings.availableUpdateVersion, "1.10.0")
        XCTAssertEqual(appModel.settings.lastNotifiedUpdateVersion, "1.10.0")
        XCTAssertEqual(notificationService.sentUpdateVersions, ["1.10.0"])

        await appModel.checkForUpdatesIfNeeded(now: firstCheck.addingTimeInterval(24 * 60 * 60))
        let secondCallCount = await releaseCheckService.callCount
        XCTAssertEqual(secondCallCount, 2)
        XCTAssertEqual(notificationService.sentUpdateVersions, ["1.10.0"])
        await Task.yield()
        let persistedSettings = await settingsRepository.load()
        XCTAssertEqual(persistedSettings.availableUpdateVersion, "1.10.0")
    }

    func test_installAvailableUpdate_delegatesToUpdater() {
        let updater = AppUpdaterSpy()
        let appModel = AppModel(appUpdater: updater)

        appModel.installAvailableUpdate()

        XCTAssertEqual(updater.installCallCount, 1)
    }

    func test_bootstrap_withoutSessionKey_showsSetupState() async {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        try? await keychainRepository.delete(account: "default")

        await appModel.bootstrap()

        XCTAssertTrue(appModel.isReady)
        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertNil(appModel.usageData)
        XCTAssertNil(appModel.errorMessage)
    }

    func test_userWithSessionKey_seesUsageAfterLaunch() async {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let usageService = UsageServiceStub(fetchUsageResult: .success(expectedUsage))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        try? await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        await appModel.bootstrap()

        XCTAssertTrue(appModel.isReady)
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertEqual(appModel.usageData, expectedUsage)
        XCTAssertNil(appModel.errorMessage)
        XCTAssertEqual(notificationService.lastEvaluatedUsageData, expectedUsage)
    }

    func test_userWithSessionKey_seesErrorWhenUsageFailsAfterLaunch() async {
        let failure = TestError(message: TestConstants.fetchFailureMessage)
        let usageService = UsageServiceStub(fetchUsageResult: .failure(failure))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        try? await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        await appModel.bootstrap()

        XCTAssertTrue(appModel.isReady)
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertNil(appModel.usageData)
        XCTAssertEqual(appModel.errorMessage, failure.localizedDescription)
        XCTAssertNil(notificationService.lastEvaluatedUsageData)
    }

    func test_refreshingUsage_showsLatestUsageAndClearsError() async {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let usageService = UsageServiceStub(fetchUsageResult: .success(expectedUsage))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        appModel.isSetupComplete = true
        appModel.errorMessage = TestConstants.previousErrorMessage

        await appModel.refreshUsage(forceRefresh: true)

        XCTAssertEqual(appModel.usageData, expectedUsage)
        XCTAssertNil(appModel.errorMessage)
        XCTAssertFalse(appModel.isRefreshing)
        XCTAssertFalse(appModel.isLoading)
        XCTAssertEqual(notificationService.lastEvaluatedUsageData, expectedUsage)
    }

    func test_refreshingUsage_showsErrorWhenFetchFails() async {
        let failure = TestError(message: TestConstants.fetchFailureMessage)
        let usageService = UsageServiceStub(fetchUsageResult: .failure(failure))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        appModel.isSetupComplete = true

        await appModel.refreshUsage(forceRefresh: false)

        XCTAssertNil(appModel.usageData)
        XCTAssertEqual(appModel.errorMessage, failure.localizedDescription)
        XCTAssertFalse(appModel.isRefreshing)
        XCTAssertFalse(appModel.isLoading)
        XCTAssertNil(notificationService.lastEvaluatedUsageData)
    }

    func test_refreshingUsage_hidesUsageWhenSetupIncomplete() async {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        appModel.isSetupComplete = false
        appModel.usageData = makeUsageData(percentage: TestConstants.cachedPercentage)

        await appModel.refreshUsage(forceRefresh: false)

        XCTAssertNil(appModel.usageData)
        XCTAssertNil(notificationService.lastEvaluatedUsageData)
    }

    func test_userWithInvalidSessionKey_staysInSetup() async throws {
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)),
            isSessionKeyValid: false
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        let result = try await appModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)

        XCTAssertFalse(result)
        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertTrue(appModel.settings.isFirstLaunch)
        XCTAssertNil(appModel.settings.cachedOrganizationId)
        XCTAssertNil(appModel.usageData)
        XCTAssertEqual(appModel.claudeCredentialState.health, .invalid)
        XCTAssertEqual(appModel.claudeCredentialState.failureCategory, .providerRejected)
    }

    func test_providerCredentialStatusViewModelsExposeSanitizedClaudeAndChatGPTState() async throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: "raw sk-ant-secret must not appear")))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )
        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .unavailable,
            failureCategory: .storageUnavailable,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        let statuses = appModel.providerCredentialStatuses

        XCTAssertEqual(statuses.map(\.id), ["claude.sessionKey", "chatGPT.sessionCookie", "gemini.apiKey"])
        let claude = try XCTUnwrap(statuses.first { $0.provider == .claude })
        XCTAssertEqual(claude.providerName, "Claude")
        XCTAssertEqual(claude.credentialName, "Claude session key")
        XCTAssertEqual(claude.stateText, "Unavailable")
        XCTAssertEqual(claude.statusTitle, claude.stateText)
        XCTAssertEqual(claude.detailText, "Check Keychain access and try again.")
        XCTAssertEqual(claude.statusDescription, claude.detailText)
        XCTAssertEqual(claude.lastFailureTitle, "Credential storage unavailable")
        XCTAssertEqual(claude.actions.map(\.displayTitle), ["Reconnect", "Repair", "Clear"])
        XCTAssertEqual(claude.actions.map(\.kind), [.reconnect, .repair, .clear])
        XCTAssertFalse(claude.searchableText.contains("sk-ant-secret"))
        XCTAssertFalse(claude.detailText.contains("sk-ant-secret"))

        let chatGPT = try XCTUnwrap(statuses.first { $0.provider == .chatGPT })
        XCTAssertEqual(chatGPT.providerName, "ChatGPT")
        XCTAssertEqual(chatGPT.credentialName, "ChatGPT session cookie")
        XCTAssertEqual(chatGPT.stateText, "Unknown")
        XCTAssertEqual(chatGPT.detailText, "Sign in to ChatGPT in your browser, then import the browser session into Pinemeter.")
        XCTAssertEqual(chatGPT.actions.map(\.displayTitle), ["Reconnect"])
        XCTAssertEqual(chatGPT.actions.map(\.kind), [.reconnect])

        let gemini = try XCTUnwrap(statuses.first { $0.provider == .gemini })
        XCTAssertEqual(gemini.providerName, "Gemini")
        XCTAssertEqual(gemini.credentialName, "Gemini API key")
        XCTAssertEqual(gemini.stateText, "Unknown")
        XCTAssertEqual(gemini.detailText, "Add a Gemini API key in Settings.")
        XCTAssertEqual(gemini.setupPromptTitle, "Connect Gemini")
        XCTAssertEqual(gemini.setupAccessibilityLabel, "Gemini API key status: Unknown. Add a Gemini API key in Settings.")
        XCTAssertTrue(gemini.actions.isEmpty)
        XCTAssertFalse(gemini.searchableText.contains("sk-ant-secret"))
        XCTAssertFalse(gemini.searchableText.contains("AIza"))

        appModel.geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .invalid,
            failureCategory: .providerRejected,
            checkedAt: Date(timeIntervalSince1970: 1)
        )
        let invalidGemini = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .gemini })
        XCTAssertEqual(invalidGemini.actions.map(\.displayTitle), ["Clear"])
        XCTAssertEqual(invalidGemini.actions.map(\.kind), [.clear])
    }

    func test_providerCredentialStatusSetupPromptsDistinguishReadyMissingAndRepairableCredentials() throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .valid,
            checkedAt: Date(timeIntervalSince1970: 0)
        )
        var claude = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .claude })
        XCTAssertFalse(claude.shouldPromptForSetupCredential)
        XCTAssertFalse(claude.isRepairableInSetup)
        XCTAssertEqual(claude.setupPromptTitle, "Saved Claude session key is ready")
        XCTAssertEqual(claude.detailText, "Saved Claude session key is ready.")
        XCTAssertEqual(claude.setupPromptDescription, claude.detailText)
        XCTAssertTrue(claude.setupAccessibilityLabel.contains("Claude session key status: Ready"))

        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .missing,
            failureCategory: .missing,
            checkedAt: Date(timeIntervalSince1970: 0)
        )
        claude = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .claude })
        XCTAssertFalse(claude.shouldPromptForSetupCredential)
        XCTAssertFalse(claude.isRepairableInSetup)
        XCTAssertEqual(claude.setupPromptTitle, "Connect Claude")
        XCTAssertEqual(claude.detailText, "Sign in to Claude in your browser, then import the browser session into Pinemeter.")
        XCTAssertEqual(claude.setupPromptDescription, claude.detailText)
        XCTAssertFalse(claude.setupPromptDescription.localizedCaseInsensitiveContains("paste"))
        XCTAssertFalse(claude.setupPromptDescription.localizedCaseInsensitiveContains("manually"))

        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .unavailable,
            failureCategory: .storageUnavailable,
            checkedAt: Date(timeIntervalSince1970: 0)
        )
        claude = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .claude })
        XCTAssertFalse(claude.shouldPromptForSetupCredential)
        XCTAssertTrue(claude.isRepairableInSetup)
        XCTAssertEqual(claude.setupPromptTitle, "Recover Claude session key")
        XCTAssertEqual(claude.detailText, "Check Keychain access and try again.")
        XCTAssertEqual(claude.setupPromptDescription, claude.detailText)
        XCTAssertFalse(claude.setupAccessibilityLabel.contains(TestConstants.sessionKeyValue))
    }

    func test_providerCredentialStatusesExposeRecoveryActionsForBoundaryStates() throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        let cases: [(CredentialHealthState, [ProviderCredentialActionKind])] = [
            (.unknown, [.reconnect]),
            (.missing, [.reconnect]),
            (.validating, []),
            (.valid, [.reconnect, .clear]),
            (.refreshRecommended, [.reconnect, .clear]),
            (.invalid, [.reconnect, .repair, .clear]),
            (.expired, [.reconnect, .repair, .clear]),
            (.unavailable, [.reconnect, .repair, .clear])
        ]

        for (health, expectedActions) in cases {
            appModel.claudeCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: health,
                failureCategory: health == .valid ? nil : .providerRejected,
                checkedAt: Date(timeIntervalSince1970: 0)
            )

            let claude = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .claude })
            XCTAssertEqual(claude.actions.map(\.kind), expectedActions, "Unexpected actions for \\(health)")
            XCTAssertFalse(claude.searchableText.contains(TestConstants.sessionKeyValue))
        }
    }

    func test_performProviderCredentialAction_repairsClaudeThroughScopedSessionKeyRepair() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .success(expectedUsage)),
            notificationService: NotificationServiceSpy()
        )
        appModel.isSetupComplete = true

        let result = try await appModel.performProviderCredentialAction(.repair, for: .claude)
        let savedKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertEqual(result.health, .valid)
        XCTAssertNil(result.failureCategory)
        XCTAssertEqual(appModel.claudeCredentialState, result)
        XCTAssertEqual(savedKey, TestConstants.sessionKeyValue)
        XCTAssertEqual(appModel.usageData, expectedUsage)
    }

    func test_performProviderCredentialAction_reconnectsChatGPTThroughSessionRepositoryBoundary() async throws {
        let expectedUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 44, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let sessionRepository = AppModelChatGPTSessionRepositoryFake()
        let importService = SessionKeyImportServiceStub(
            result: .failure(SessionKeyImportError.noSessionKeyFound),
            chatGPTResult: .success(ImportedChatGPTSessionCookie(
                cookieHeader: "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie",
                sourceDescription: "Chrome Default"
            ))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: AppModelChatGPTUsageServiceStub(fetchUsageResult: .success(expectedUsage), validateResult: true),
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let result = try await appModel.performProviderCredentialAction(.reconnect, for: .chatGPT)
        let savedSession = try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(result.health, .valid)
        XCTAssertNil(result.failureCategory)
        XCTAssertEqual(appModel.chatGPTCredentialState, result)
        XCTAssertEqual(savedSession.sessionCookie, "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie")
        XCTAssertEqual(appModel.chatGPTUsageData, expectedUsage)
        XCTAssertFalse(appModel.providerCredentialStatuses[1].searchableText.contains("synthetic-chatgpt-session-cookie"))
    }

    func test_performProviderCredentialAction_clearsOnlyRequestedProviderCredential() async throws {
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = AppModelChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy()
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true

        let result = try await appModel.performProviderCredentialAction(.clear, for: .chatGPT)
        let savedClaudeKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertEqual(result.health, .missing)
        XCTAssertEqual(result.failureCategory, .missing)
        XCTAssertEqual(savedClaudeKey, TestConstants.sessionKeyValue)
        do {
            _ = try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)
            XCTFail("Expected ChatGPT session cookie to be cleared")
        } catch {
            // Expected: cleared session repository rejects the load without exposing credential material.
        }
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
    }

    func test_performProviderCredentialAction_clearsGeminiWithoutChangingMixedProviderState() async throws {
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = AppModelChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let geminiAPIKeyRepository = AppModelGeminiAPIKeyRepositoryFake()
        try await geminiAPIKeyRepository.save(
            try GeminiAPIKey("gemini-api-key-redaction-sentinel"),
            account: GeminiUsageService.defaultAPIKeyAccount
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTSessionRepository: sessionRepository,
            geminiAPIKeyRepository: geminiAPIKeyRepository,
            notificationService: NotificationServiceSpy()
        )
        appModel.isSetupComplete = true
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 42,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        appModel.geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .valid,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        let result = try await appModel.performProviderCredentialAction(.clear, for: .gemini)
        let savedClaudeKey = try await keychainRepository.retrieve(account: "default")
        let savedChatGPTSession = try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(result.health, .missing)
        XCTAssertEqual(result.failureCategory, .missing)
        XCTAssertFalse(appModel.hasGeminiAPIKey)
        XCTAssertNil(appModel.geminiUsageData)
        XCTAssertNil(appModel.geminiErrorMessage)
        XCTAssertEqual(savedClaudeKey, TestConstants.sessionKeyValue)
        XCTAssertEqual(savedChatGPTSession.sessionCookie, "chatgpt-session-redacted")
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        do {
            _ = try await geminiAPIKeyRepository.load(account: GeminiUsageService.defaultAPIKeyAccount)
            XCTFail("Expected Gemini API key to be cleared")
        } catch GeminiAPIKeyRepositoryError.notFound {
            // Expected: clearing Gemini removes only Gemini credential material.
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
    }

    func test_performProviderCredentialAction_rejectsUnsupportedChatGPTRepairWithoutCredentialLeak() async throws {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )
        appModel.chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .invalid,
            failureCategory: .providerRejected,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        do {
            _ = try await appModel.performProviderCredentialAction(.repair, for: .chatGPT)
            XCTFail("Expected unsupported action to throw")
        } catch let actionError as AppProviderCredentialActionError {
            XCTAssertEqual(actionError, .unsupportedAction(provider: .chatGPT, action: .repair))
            XCTAssertFalse(actionError.localizedDescription.contains("chatgpt-session-redacted"))
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)
    }

    func test_performProviderCredentialAction_rejectsUnsupportedGeminiReconnectAndRepairWithoutCredentialLeak() async throws {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )
        appModel.geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .invalid,
            failureCategory: .providerRejected,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        for action in [ProviderCredentialActionKind.reconnect, .repair] {
            do {
                _ = try await appModel.performProviderCredentialAction(action, for: .gemini)
                XCTFail("Expected unsupported action to throw")
            } catch let actionError as AppProviderCredentialActionError {
                XCTAssertEqual(actionError, .unsupportedAction(provider: .gemini, action: action))
                XCTAssertFalse(actionError.localizedDescription.contains("gemini-api-key-redaction-sentinel"))
                XCTAssertFalse(actionError.localizedDescription.contains("AIza"))
            } catch {
                XCTFail("Unexpected error: \\(error)")
            }
        }
        XCTAssertEqual(appModel.geminiCredentialState.failureCategory, .providerRejected)
    }

    func test_userWithValidSessionKey_entersUsageAndLoadsData() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let organization = Organization(
            id: 1,
            uuid: TestConstants.organizationUUIDString,
            name: "Test Org",
            capabilities: ["chat"]
        )
        let usageService = UsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            organizations: [organization],
            isSessionKeyValid: true
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        let result = try await appModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)

        XCTAssertTrue(result)
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertFalse(appModel.settings.isFirstLaunch)
        XCTAssertEqual(
            appModel.settings.cachedOrganizationId,
            UUID(uuidString: TestConstants.organizationUUIDString)
        )
        XCTAssertEqual(appModel.usageData, expectedUsage)
    }

    func test_importingSessionKey_savesImportedKeyAndLoadsData() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let organization = Organization(
            id: 1,
            uuid: TestConstants.organizationUUIDString,
            name: "Test Org",
            capabilities: ["chat"]
        )
        let usageService = UsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            organizations: [organization],
            isSessionKeyValid: true
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let importService = SessionKeyImportServiceStub(result: .success(ImportedSessionKey(
            value: TestConstants.sessionKeyValue,
            sourceDescription: "Chrome Default"
        )))

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService,
            sessionKeyImportService: importService
        )

        let imported = try await appModel.importAndSaveSessionKey()
        let savedKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertEqual(imported.sourceDescription, "Chrome Default")
        XCTAssertEqual(savedKey, TestConstants.sessionKeyValue)
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertEqual(appModel.usageData, expectedUsage)
    }

    func test_importingProviderSessionsFromBrowser_savesClaudeAndChatGPT() async throws {
        let expectedClaudeUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let expectedChatGPTUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 37, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let organization = Organization(
            id: 1,
            uuid: TestConstants.organizationUUIDString,
            name: "Test Org",
            capabilities: ["chat"]
        )
        let keychainRepository = KeychainRepositoryFake()
        let chatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedChatGPTUsage),
            validateResult: true
        )
        let chatGPTSessionRepository = AppModelChatGPTSessionRepositoryFake()
        let importService = SessionKeyImportServiceStub(
            result: .success(ImportedSessionKey(
                value: TestConstants.sessionKeyValue,
                sourceDescription: "Chrome Default"
            )),
            chatGPTResult: .success(ImportedChatGPTSessionCookie(
                cookieHeader: "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie",
                sourceDescription: "Chrome Default"
            ))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(
                fetchUsageResult: .success(expectedClaudeUsage),
                organizations: [organization]
            ),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let outcome = await appModel.importProviderSessions(from: .chrome)
        let savedClaudeKey = try await keychainRepository.retrieve(account: "default")
        let savedChatGPTSession = try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(outcome.source, .chrome)
        XCTAssertEqual(outcome.claude, .imported(sourceDescription: "Chrome Default"))
        XCTAssertEqual(outcome.chatGPT, .imported(sourceDescription: "Chrome Default"))
        XCTAssertEqual(savedClaudeKey, TestConstants.sessionKeyValue)
        XCTAssertEqual(savedChatGPTSession.sessionCookie, "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie")
        XCTAssertTrue(appModel.isSetupComplete)
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.usageData, expectedClaudeUsage)
        XCTAssertEqual(appModel.chatGPTUsageData, expectedChatGPTUsage)
    }

    func test_providerAwareMenuState_routesConfiguredProvidersToUsageSurface() async {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, [])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")

        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true

        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["ChatGPT"])
        XCTAssertEqual(appModel.usageDashboardTitle, "ChatGPT Usage")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading ChatGPT usage data...")

        appModel.hasGeminiAPIKey = true

        XCTAssertEqual(appModel.configuredUsageProviderNames, ["ChatGPT", "Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading ChatGPT and Gemini usage data...")

        appModel.isSetupComplete = true

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Claude", "ChatGPT", "Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Claude, ChatGPT, and Gemini usage data...")
    }

    func test_usagePopoverContentAvailabilityIncludesGeminiDataAndErrors() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        XCTAssertFalse(appModel.hasUsagePopoverContent)

        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 42,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(appModel.hasUsagePopoverContent)

        appModel.geminiUsageData = nil
        appModel.geminiErrorMessage = "Gemini quota data is unavailable."

        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_providerDisplayCombinations_includeGeminiOnly() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 18,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Gemini Usage")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Gemini usage data...")
        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_providerDisplayCombinations_includeClaudePlusGemini() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        appModel.isSetupComplete = true
        appModel.usageData = makeUsageData(percentage: TestConstants.sessionPercentage)
        appModel.hasGeminiAPIKey = true
        appModel.geminiUsageData = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 22,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Claude", "Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Claude and Gemini usage data...")
        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_providerDisplayCombinations_includeChatGPTPlusGemini() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

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

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["ChatGPT", "Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading ChatGPT and Gemini usage data...")
        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_providerDisplayCombinations_includeAllProviders() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        appModel.isSetupComplete = true
        appModel.usageData = makeUsageData(percentage: TestConstants.sessionPercentage)
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

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Claude", "ChatGPT", "Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Claude, ChatGPT, and Gemini usage data...")
        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_providerDisplayCombinations_includeGeminiErrorState() async {
        let geminiUsageService = AppModelGeminiUsageServiceStub(
            fetchUsageResult: .failure(GeminiUsageError.networkUnavailable),
            validateResult: true
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            geminiUsageService: geminiUsageService,
            notificationService: NotificationServiceSpy()
        )
        appModel.hasGeminiAPIKey = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let geminiFetchCount = await geminiUsageService.fetchUsageCallCount
        XCTAssertEqual(geminiFetchCount, 1)
        XCTAssertTrue(appModel.hasGeminiAPIKey)
        XCTAssertNil(appModel.geminiUsageData)
        XCTAssertEqual(appModel.geminiErrorMessage, GeminiUsageError.networkUnavailable.localizedDescription)
        XCTAssertEqual(appModel.geminiCredentialState.health, .unavailable)
        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Gemini"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Gemini Usage")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Gemini usage data...")
        XCTAssertTrue(appModel.hasUsagePopoverContent)
    }

    func test_refreshConfiguredUsageProviders_refreshesOnlyVisibleConfiguredProviders() async {
        let expectedClaudeUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let expectedChatGPTUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 42, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let expectedGeminiUsage = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 12,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let usageService = UsageServiceStub(fetchUsageResult: .success(expectedClaudeUsage))
        let chatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedChatGPTUsage),
            validateResult: true
        )
        let geminiUsageService = AppModelGeminiUsageServiceStub(
            fetchUsageResult: .success(expectedGeminiUsage),
            validateResult: true
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: usageService,
            chatGPTUsageService: chatGPTUsageService,
            geminiUsageService: geminiUsageService,
            notificationService: NotificationServiceSpy()
        )

        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.hasGeminiAPIKey = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let claudeFetchCountAfterProviderOnlyRefresh = await usageService.fetchUsageCallCount
        let chatGPTFetchCountAfterProviderOnlyRefresh = await chatGPTUsageService.fetchUsageCallCount
        let geminiFetchCountAfterProviderOnlyRefresh = await geminiUsageService.fetchUsageCallCount

        XCTAssertNil(appModel.usageData)
        XCTAssertEqual(appModel.chatGPTUsageData, expectedChatGPTUsage)
        XCTAssertEqual(appModel.geminiUsageData, expectedGeminiUsage)
        XCTAssertEqual(claudeFetchCountAfterProviderOnlyRefresh, 0)
        XCTAssertEqual(chatGPTFetchCountAfterProviderOnlyRefresh, 1)
        XCTAssertEqual(geminiFetchCountAfterProviderOnlyRefresh, 1)

        appModel.isSetupComplete = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let claudeFetchCountAfterAllRefresh = await usageService.fetchUsageCallCount
        let claudeForceRefreshValues = await usageService.forceRefreshValues
        let chatGPTFetchCountAfterAllRefresh = await chatGPTUsageService.fetchUsageCallCount
        let geminiFetchCountAfterAllRefresh = await geminiUsageService.fetchUsageCallCount

        XCTAssertEqual(appModel.usageData, expectedClaudeUsage)
        XCTAssertEqual(appModel.chatGPTUsageData, expectedChatGPTUsage)
        XCTAssertEqual(appModel.geminiUsageData, expectedGeminiUsage)
        XCTAssertEqual(claudeFetchCountAfterAllRefresh, 1)
        XCTAssertEqual(claudeForceRefreshValues, [true])
        XCTAssertEqual(chatGPTFetchCountAfterAllRefresh, 2)
        XCTAssertEqual(geminiFetchCountAfterAllRefresh, 2)
    }

    func test_providerAwareMenuState_hidesChatGPTWhenUsageToggleIsOff() async {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            notificationService: NotificationServiceSpy()
        )

        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = false

        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, [])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")

        appModel.isSetupComplete = true

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Claude"])
        XCTAssertEqual(appModel.usageDashboardTitle, "Claude Usage")
        XCTAssertEqual(appModel.usageLoadingMessage, "Loading Claude usage data...")
    }

    func test_refreshConfiguredUsageProviders_missingChatGPTSessionRemovesProviderFromMenuState() async {
        let chatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .failure(ChatGPTUsageError.missingSessionCookie),
            validateResult: false
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: chatGPTUsageService,
            notificationService: NotificationServiceSpy()
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let chatGPTFetchCount = await chatGPTUsageService.fetchUsageCallCount
        XCTAssertEqual(chatGPTFetchCount, 1)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertNil(appModel.chatGPTUsageData)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .missing)
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")
    }

    func test_refreshConfiguredUsageProviders_missingGeminiAPIKeyRemovesProviderFromMenuState() async {
        let geminiUsageService = AppModelGeminiUsageServiceStub(
            fetchUsageResult: .failure(GeminiUsageError.missingAPIKey),
            validateResult: false
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            geminiUsageService: geminiUsageService,
            notificationService: NotificationServiceSpy()
        )
        appModel.hasGeminiAPIKey = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let geminiFetchCount = await geminiUsageService.fetchUsageCallCount
        XCTAssertEqual(geminiFetchCount, 1)
        XCTAssertFalse(appModel.hasGeminiAPIKey)
        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertNil(appModel.geminiUsageData)
        XCTAssertEqual(appModel.geminiCredentialState.health, .missing)
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")
    }

    func test_importingChatGPTSessionCookie_savesImportedCookieAndRefreshesUsage() async throws {
        let expectedUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 42, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let chatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            validateResult: true
        )
        let chatGPTSessionRepository = AppModelChatGPTSessionRepositoryFake()
        let importService = SessionKeyImportServiceStub(
            result: .failure(SessionKeyImportError.noSessionKeyFound),
            chatGPTResult: .success(ImportedChatGPTSessionCookie(
                cookieHeader: "__Secure-next-auth.session-token=synthetic-chatgpt-session-cookie",
                sourceDescription: "Chrome Default"
            ))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let imported = try await appModel.importAndSaveChatGPTSessionCookie()
        let savedSession = try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(imported.sourceDescription, "Chrome Default")
        XCTAssertEqual(savedSession.sessionCookie, "__Secure-next-auth.session-token=synthetic-chatgpt-session-cookie")
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertTrue(appModel.settings.isChatGPTUsageShown)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(appModel.chatGPTUsageData, expectedUsage)
    }

    func test_importingChatGPTSessionCookie_savesImportedCookieWhenUsageRefreshFails() async throws {
        let chatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .failure(TestError(message: "quota unavailable")),
            validateResult: false
        )
        let chatGPTSessionRepository = AppModelChatGPTSessionRepositoryFake()
        let importService = SessionKeyImportServiceStub(
            result: .failure(SessionKeyImportError.noSessionKeyFound),
            chatGPTResult: .success(ImportedChatGPTSessionCookie(
                cookieHeader: "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie",
                sourceDescription: "Chrome Default"
            ))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        let imported = try await appModel.importAndSaveChatGPTSessionCookie()
        let savedSession = try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(imported.sourceDescription, "Chrome Default")
        XCTAssertEqual(savedSession.sessionCookie, "__Secure-authjs.session-token=synthetic-chatgpt-session-cookie")
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertTrue(appModel.settings.isChatGPTUsageShown)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(appModel.chatGPTErrorMessage, "quota unavailable")
    }

    func test_repairingClaudeSessionKey_resavesCurrentKeyAndRefreshesCredentialState() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let usageService = UsageServiceStub(fetchUsageResult: .success(expectedUsage))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )
        appModel.isSetupComplete = true

        let state = await appModel.repairClaudeSessionKey()
        let savedKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertEqual(state.health, .valid)
        XCTAssertNil(state.failureCategory)
        XCTAssertEqual(appModel.claudeCredentialState, state)
        XCTAssertEqual(savedKey, TestConstants.sessionKeyValue)
        XCTAssertEqual(appModel.usageData, expectedUsage)
    }

    func test_repairingClaudeSessionKey_whenKeychainSaveFailsPublishesSanitizedStorageFailure() async throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = RepairFailingKeychainRepository(sessionKey: TestConstants.sessionKeyValue)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )
        appModel.isSetupComplete = true

        let state = await appModel.repairClaudeSessionKey()

        XCTAssertEqual(state.health, .unavailable)
        XCTAssertEqual(state.failureCategory, .storageUnavailable)
        XCTAssertEqual(appModel.claudeCredentialState, state)
        XCTAssertNil(appModel.usageData)
        XCTAssertNil(appModel.errorMessage)
    }

    func test_importingSessionKey_whenImportedKeyInvalid_staysInSetup() async throws {
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)),
            organizations: [],
            isSessionKeyValid: false
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let importService = SessionKeyImportServiceStub(result: .success(ImportedSessionKey(
            value: TestConstants.sessionKeyValue,
            sourceDescription: "Chrome Default"
        )))

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService,
            sessionKeyImportService: importService
        )

        do {
            _ = try await appModel.importAndSaveSessionKey()
            XCTFail("Expected invalidImportedSessionKey to be thrown")
        } catch SessionKeyImportError.invalidImportedSessionKey {
            XCTAssertFalse(appModel.isSetupComplete)
            XCTAssertNil(appModel.usageData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_userWithValidSessionKeyWithoutOrganization_staysInSetup() async {
        let usageService = UsageServiceStub(
            fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)),
            organizations: [],
            isSessionKeyValid: true
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        do {
            _ = try await appModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)
            XCTFail("Expected organizationNotFound to be thrown")
        } catch AppError.organizationNotFound {
            XCTAssertFalse(appModel.isSetupComplete)
            XCTAssertNil(appModel.usageData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_userClearsSession_returnsToSetupState() async throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        appModel.isSetupComplete = true
        appModel.usageData = makeUsageData(percentage: TestConstants.cachedPercentage)
        appModel.errorMessage = TestConstants.fetchFailureMessage

        var updatedSettings = appModel.settings
        updatedSettings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        updatedSettings.isFirstLaunch = false
        appModel.settings = updatedSettings

        try await appModel.clearSessionKey()

        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertNil(appModel.usageData)
        XCTAssertNil(appModel.errorMessage)
        XCTAssertNil(appModel.settings.cachedOrganizationId)
        XCTAssertTrue(appModel.settings.isFirstLaunch)
    }

    func test_claudeCredentialLifecycle_recoversFromInvalidClearAndReacquire() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let organization = Organization(
            id: 1,
            uuid: TestConstants.organizationUUIDString,
            name: "Lifecycle Org",
            capabilities: ["chat"]
        )
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let invalidUsageService = UsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            organizations: [organization],
            isSessionKeyValid: false
        )
        let invalidModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: invalidUsageService,
            notificationService: notificationService
        )

        let rejected = try await invalidModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)

        XCTAssertFalse(rejected)
        XCTAssertFalse(invalidModel.isSetupComplete)
        XCTAssertEqual(invalidModel.claudeCredentialState.health, .invalid)
        XCTAssertEqual(invalidModel.claudeCredentialState.failureCategory, .providerRejected)
        do {
            _ = try await keychainRepository.retrieve(account: "default")
            XCTFail("Expected missing Claude session key after invalid validation")
        } catch KeychainError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let validUsageService = UsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            organizations: [organization],
            isSessionKeyValid: true
        )
        let setupModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: validUsageService,
            notificationService: notificationService
        )

        let acquired = try await setupModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)

        let savedSessionKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertTrue(acquired)
        XCTAssertTrue(setupModel.isSetupComplete)
        XCTAssertEqual(setupModel.claudeCredentialState.health, .valid)
        XCTAssertEqual(savedSessionKey, TestConstants.sessionKeyValue)

        let reuseModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: validUsageService,
            notificationService: notificationService
        )

        await reuseModel.bootstrap()

        XCTAssertTrue(reuseModel.isSetupComplete)
        XCTAssertEqual(reuseModel.claudeCredentialState.health, .valid)
        XCTAssertEqual(reuseModel.usageData, expectedUsage)

        try await setupModel.clearSessionKey()

        XCTAssertFalse(setupModel.isSetupComplete)
        XCTAssertNil(setupModel.usageData)
        XCTAssertEqual(setupModel.claudeCredentialState.health, .missing)
        XCTAssertEqual(setupModel.claudeCredentialState.failureCategory, .missing)

        let reacquired = try await setupModel.validateAndSaveSessionKey(TestConstants.sessionKeyValue)

        let reacquiredSessionKey = try await keychainRepository.retrieve(account: "default")

        XCTAssertTrue(reacquired)
        XCTAssertTrue(setupModel.isSetupComplete)
        XCTAssertEqual(setupModel.claudeCredentialState.health, .valid)
        XCTAssertEqual(reacquiredSessionKey, TestConstants.sessionKeyValue)
    }

    func test_chatGPTCredentialLifecycle_recoversFromInvalidClearAndReacquire() async throws {
        let expectedUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: 24, resetAt: nil)],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let notificationService = NotificationServiceSpy()
        let chatGPTSessionRepository = AppModelChatGPTSessionRepositoryFake()
        let invalidChatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            validateResult: false
        )
        let invalidModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: invalidChatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: notificationService
        )

        let rejected = try await invalidModel.validateAndSaveChatGPTSessionCookie("synthetic-chatgpt-session-cookie")

        XCTAssertFalse(rejected)
        XCTAssertFalse(invalidModel.hasChatGPTSessionCookie)
        XCTAssertEqual(invalidModel.chatGPTCredentialState.health, .invalid)
        XCTAssertEqual(invalidModel.chatGPTCredentialState.failureCategory, .providerRejected)
        do {
            _ = try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)
            XCTFail("Expected missing ChatGPT session after invalid validation")
        } catch ChatGPTSessionRepositoryError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let validChatGPTUsageService = AppModelChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            validateResult: true
        )
        let setupModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: validChatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: notificationService
        )

        let acquired = try await setupModel.validateAndSaveChatGPTSessionCookie("synthetic-chatgpt-session-cookie")

        XCTAssertTrue(acquired)
        XCTAssertTrue(setupModel.hasChatGPTSessionCookie)
        XCTAssertTrue(setupModel.settings.isChatGPTUsageShown)
        let savedChatGPTSession = try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)

        XCTAssertEqual(setupModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(setupModel.chatGPTUsageData, expectedUsage)
        XCTAssertEqual(savedChatGPTSession.sessionCookie, "synthetic-chatgpt-session-cookie")

        var reuseSettings = AppSettings.default
        reuseSettings.isChatGPTUsageShown = true
        try await settingsRepository.save(reuseSettings)
        let reuseModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            chatGPTUsageService: validChatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: notificationService
        )

        await reuseModel.bootstrap()

        XCTAssertTrue(reuseModel.hasChatGPTSessionCookie)
        XCTAssertEqual(reuseModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(reuseModel.chatGPTUsageData, expectedUsage)

        try await setupModel.clearChatGPTSessionCookie()

        XCTAssertFalse(setupModel.hasChatGPTSessionCookie)
        XCTAssertFalse(setupModel.settings.isChatGPTUsageShown)
        XCTAssertNil(setupModel.chatGPTUsageData)
        XCTAssertNil(setupModel.chatGPTErrorMessage)
        XCTAssertEqual(setupModel.chatGPTCredentialState.health, .missing)
        XCTAssertEqual(setupModel.chatGPTCredentialState.failureCategory, .missing)

        let reacquired = try await setupModel.validateAndSaveChatGPTSessionCookie("synthetic-chatgpt-session-cookie")

        XCTAssertTrue(reacquired)
        XCTAssertTrue(setupModel.hasChatGPTSessionCookie)
        XCTAssertEqual(setupModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(setupModel.chatGPTUsageData, expectedUsage)
    }

    func test_geminiCredentialLifecycle_recoversFromInvalidClearAndReacquire() async throws {
        let expectedUsage = GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: 33,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let notificationService = NotificationServiceSpy()
        let geminiAPIKeyRepository = AppModelGeminiAPIKeyRepositoryFake()
        let invalidGeminiUsageService = AppModelGeminiUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            validateResult: false
        )
        let invalidModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            geminiUsageService: invalidGeminiUsageService,
            geminiAPIKeyRepository: geminiAPIKeyRepository,
            notificationService: notificationService
        )

        let rejected = try await invalidModel.validateAndSaveGeminiAPIKey("gemini-api-key-redaction-sentinel")

        XCTAssertFalse(rejected)
        XCTAssertFalse(invalidModel.hasGeminiAPIKey)
        XCTAssertEqual(invalidModel.geminiCredentialState.health, .invalid)
        XCTAssertEqual(invalidModel.geminiCredentialState.failureCategory, .providerRejected)
        do {
            _ = try await geminiAPIKeyRepository.load(account: GeminiUsageService.defaultAPIKeyAccount)
            XCTFail("Expected missing Gemini API key after invalid validation")
        } catch GeminiAPIKeyRepositoryError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let validGeminiUsageService = AppModelGeminiUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            validateResult: true
        )
        let setupModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            geminiUsageService: validGeminiUsageService,
            geminiAPIKeyRepository: geminiAPIKeyRepository,
            notificationService: notificationService
        )

        let acquired = try await setupModel.validateAndSaveGeminiAPIKey(" gemini-api-key-redaction-sentinel ")

        XCTAssertTrue(acquired)
        XCTAssertTrue(setupModel.hasGeminiAPIKey)
        let savedGeminiAPIKey = try await geminiAPIKeyRepository.load(account: GeminiUsageService.defaultAPIKeyAccount)

        XCTAssertEqual(setupModel.geminiCredentialState.health, .valid)
        XCTAssertEqual(setupModel.geminiUsageData, expectedUsage)
        XCTAssertEqual(savedGeminiAPIKey.value, "gemini-api-key-redaction-sentinel")

        let reuseModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage))),
            geminiUsageService: validGeminiUsageService,
            geminiAPIKeyRepository: geminiAPIKeyRepository,
            notificationService: notificationService
        )

        await reuseModel.bootstrap()

        XCTAssertTrue(reuseModel.hasGeminiAPIKey)
        XCTAssertEqual(reuseModel.geminiCredentialState.health, .valid)
        XCTAssertEqual(reuseModel.geminiUsageData, expectedUsage)

        try await setupModel.clearGeminiAPIKey()

        XCTAssertFalse(setupModel.hasGeminiAPIKey)
        XCTAssertNil(setupModel.geminiUsageData)
        XCTAssertNil(setupModel.geminiErrorMessage)
        XCTAssertEqual(setupModel.geminiCredentialState.health, .missing)
        XCTAssertEqual(setupModel.geminiCredentialState.failureCategory, .missing)

        let reacquired = try await setupModel.validateAndSaveGeminiAPIKey("gemini-api-key-redaction-sentinel")

        XCTAssertTrue(reacquired)
        XCTAssertTrue(setupModel.hasGeminiAPIKey)
        XCTAssertEqual(setupModel.geminiCredentialState.health, .valid)
        XCTAssertEqual(setupModel.geminiUsageData, expectedUsage)
    }

    func test_userWithNotificationPermission_doesNotSeePermissionPrompt() async {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        notificationService.hasPermission = true
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        await appModel.requestNotificationPermissionIfNeeded()

        XCTAssertEqual(notificationService.requestAuthorizationCallCount, 0)
    }

    func test_userWithoutNotificationPermission_isPromptedForPermission() async {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        notificationService.hasPermission = false
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        await appModel.requestNotificationPermissionIfNeeded()

        XCTAssertEqual(notificationService.requestAuthorizationCallCount, 1)
    }

    func test_userSendsTestNotification_triggersNotificationService() async throws {
        let usageService = UsageServiceStub(fetchUsageResult: .failure(TestError(message: TestConstants.unexpectedErrorMessage)))
        let notificationService = NotificationServiceSpy()
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            notificationService: notificationService
        )

        try await appModel.sendTestNotification()

        XCTAssertEqual(notificationService.sentThresholdType, .warning)
        XCTAssertEqual(notificationService.sentThresholdPercentage, 85.0)
    }

    func test_chatGPTChromiumFallback_stripsChromeHostDigestFromDecryptedCookieValue() {
        let token = "chatgpt-session-token"
        var payload = ChatGPTChromiumCookieFallbackImporter.hostDigest(for: ".chatgpt.com")
        payload.append(Data(token.utf8))

        XCTAssertEqual(
            ChatGPTChromiumCookieFallbackImporter.decodedChromePlaintext(payload, hostKey: ".chatgpt.com"),
            token
        )
    }

    func test_chatGPTChromiumFallback_decryptsChromeV10CookieValueWithHostDigest() throws {
        let key = Data("0123456789abcdef".utf8)
        let token = "chatgpt-session-token"
        var plaintext = ChatGPTChromiumCookieFallbackImporter.hostDigest(for: ".chatgpt.com")
        plaintext.append(Data(token.utf8))
        let encryptedValue = try encryptedChromiumTestValue(plaintext, key: key)

        XCTAssertEqual(
            ChatGPTChromiumCookieFallbackImporter.decryptedChromiumValue(
                encryptedValue,
                hostKey: ".chatgpt.com",
                key: key
            ),
            token
        )
    }

    func test_chatGPTChromiumFallback_reconstructsSplitSessionCookieChunks() {
        let header = ChatGPTChromiumCookieFallbackImporter.normalizedCookieHeader(from: [
            .init(hostKey: ".chatgpt.com", name: "__Secure-next-auth.session-token.1", value: "second"),
            .init(hostKey: ".chatgpt.com", name: "__Secure-next-auth.session-token.0", value: "first"),
            .init(hostKey: ".chatgpt.com", name: "oai-did", value: "device-id"),
        ])

        XCTAssertEqual(
            header,
            "__Secure-next-auth.session-token=firstsecond; oai-did=device-id"
        )
    }

    private func encryptedChromiumTestValue(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCapacity = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintextBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintext.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        output.removeSubrange(outputLength..<output.count)
        var encryptedValue = Data("v10".utf8)
        encryptedValue.append(output)
        return encryptedValue
    }
}

// MARK: - Helpers

private actor UpdateReleaseCheckServiceFake: ReleaseCheckServiceProtocol {
    private let update: AvailableUpdate
    private(set) var callCount = 0

    init(update: AvailableUpdate) {
        self.update = update
    }

    func latestRelease() async throws -> AvailableUpdate {
        callCount += 1
        return update
    }
}

@MainActor
private final class AppUpdaterSpy: AppUpdaterProtocol {
    private(set) var installCallCount = 0

    func installAvailableUpdate() {
        installCallCount += 1
    }
}

private actor RepairFailingKeychainRepository: KeychainRepositoryProtocol {
    private let sessionKey: String

    init(sessionKey: String) {
        self.sessionKey = sessionKey
    }

    func save(sessionKey: String, account: String) async throws {
        throw KeychainError.saveFailed(OSStatus: OSStatus(errSecInteractionNotAllowed))
    }

    func retrieve(account: String) async throws -> String {
        sessionKey
    }

    func repairClaudeSessionKey(_ sessionKey: String, account: String) async throws -> ClaudeCredentialRepairResult {
        throw KeychainError.saveFailed(OSStatus: OSStatus(errSecInteractionNotAllowed))
    }

    func update(sessionKey: String, account: String) async throws {
        throw KeychainError.updateFailed(OSStatus: OSStatus(errSecInteractionNotAllowed))
    }

    func delete(account: String) async throws {}

    func exists(account: String) async -> Bool {
        true
    }
}

private actor AppModelChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    private let fetchUsageResult: Result<ChatGPTUsageData, Error>
    private let validateResult: Bool
    private(set) var fetchUsageCallCount = 0

    init(fetchUsageResult: Result<ChatGPTUsageData, Error>, validateResult: Bool) {
        self.fetchUsageResult = fetchUsageResult
        self.validateResult = validateResult
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        fetchUsageCallCount += 1
        switch fetchUsageResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        validateResult
    }
}

private actor AppModelChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]
    private var status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)

    func save(_ session: ChatGPTSession, account: String) async throws {
        sessions[account] = session
        status = ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func load(account: String) async throws -> ChatGPTSession {
        guard let session = sessions[account] else {
            status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            throw ChatGPTSessionRepositoryError.notFound
        }
        return session
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        status
    }

    func clear(account: String) async throws {
        sessions[account] = nil
        status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

private actor AppModelGeminiUsageServiceStub: GeminiUsageServiceProtocol {
    private let fetchUsageResult: Result<GeminiUsageData, Error>
    private let validateResult: Bool
    private(set) var fetchUsageCallCount = 0

    init(fetchUsageResult: Result<GeminiUsageData, Error>, validateResult: Bool) {
        self.fetchUsageResult = fetchUsageResult
        self.validateResult = validateResult
    }

    func fetchUsage() async throws -> GeminiUsageData {
        fetchUsageCallCount += 1
        switch fetchUsageResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func fetchUsage(apiKey: GeminiAPIKey) async throws -> GeminiUsageData {
        try await fetchUsage()
    }

    func validateAPIKey(_ apiKey: GeminiAPIKey) async throws -> Bool {
        validateResult
    }
}

private actor AppModelGeminiAPIKeyRepositoryFake: GeminiAPIKeyRepositoryProtocol {
    private var apiKeys: [String: GeminiAPIKey] = [:]
    private var status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)

    func save(_ apiKey: GeminiAPIKey, account: String) async throws {
        apiKeys[account] = apiKey
        status = GeminiAPIKeyAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func load(account: String) async throws -> GeminiAPIKey {
        guard let apiKey = apiKeys[account] else {
            status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            throw GeminiAPIKeyRepositoryError.notFound
        }
        return apiKey
    }

    func validate(account: String) async -> GeminiAPIKeyAcquisitionStatus {
        status
    }

    func clear(account: String) async throws {
        apiKeys[account] = nil
        status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

private func makeUsageData(percentage: Double) -> UsageData {
    let resetDate = Date().addingTimeInterval(TestConstants.oneHourInterval)
    let sessionUsage = UsageLimit(utilization: percentage, resetAt: resetDate)
    let weeklyUsage = UsageLimit(utilization: TestConstants.weeklyPercentage, resetAt: resetDate)

    return UsageData(
        sessionUsage: sessionUsage,
        weeklyUsage: weeklyUsage,
        sonnetUsage: nil,
        lastUpdated: Date()
    )
}
