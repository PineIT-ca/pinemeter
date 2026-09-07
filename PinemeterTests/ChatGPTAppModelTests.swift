//
//  ChatGPTAppModelTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class ChatGPTAppModelTests: XCTestCase {
    func test_bootstrap_detectsExistingChatGPTSessionWithoutRequiringClaudeSetup() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = makeAppModel(chatGPTSessionRepository: sessionRepository)

        await appModel.bootstrap()

        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertNil(appModel.chatGPTCredentialState.failureCategory)
    }

    func test_bootstrap_withChatGPTStorageUnavailablePublishesSanitizedStatus() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        await sessionRepository.setStatus(ChatGPTSessionAcquisitionStatus(
            state: .storageUnavailable,
            lastErrorCategory: .keychainReadFailed
        ))
        let appModel = makeAppModel(chatGPTSessionRepository: sessionRepository)

        await appModel.bootstrap()

        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .unavailable)
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .storageUnavailable)
        let status = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .chatGPT })
        XCTAssertEqual(status.lastFailureTitle, "Credential storage unavailable")
        XCTAssertEqual(status.actions.map(\.kind), [.reconnect, .clear])
        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, [])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")
    }

    func test_bootstrap_withExistingChatGPTSessionButUsageHiddenLeavesMenuInSetupState() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = makeAppModel(chatGPTSessionRepository: sessionRepository)
        appModel.settings.isChatGPTUsageShown = false

        await appModel.bootstrap()

        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.isSetupComplete)
        XCTAssertFalse(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, [])
        XCTAssertEqual(appModel.usageDashboardTitle, "Usage Dashboard")
        XCTAssertEqual(appModel.usageLoadingMessage, "Connect Claude, ChatGPT, or Gemini to see usage data.")
        XCTAssertNil(appModel.chatGPTUsageData)
    }

    func test_validateAndSaveChatGPTSessionCookie_withInvalidCookiePublishesSanitizedProviderRejection() async throws {
        let chatGPTService = ChatGPTUsageServiceStub(isSessionCookieValid: false)
        let sessionRepository = ChatGPTSessionRepositoryFake()
        let appModel = makeAppModel(
            chatGPTUsageService: chatGPTService,
            chatGPTSessionRepository: sessionRepository
        )

        let result = try await appModel.validateAndSaveChatGPTSessionCookie("chatgpt-session-redacted")

        XCTAssertFalse(result)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .invalid)
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)
        let status = try XCTUnwrap(appModel.providerCredentialStatuses.first { $0.provider == .chatGPT })
        XCTAssertFalse(status.searchableText.contains("chatgpt-session-redacted"))
    }

    func test_validateAndSaveChatGPTSessionCookie_savesToChatGPTAccountAndRefreshesUsage() async throws {
        let expectedUsage = makeChatGPTUsage(percentage: 25)
        let chatGPTService = ChatGPTUsageServiceStub(
            fetchUsageResult: .success(expectedUsage),
            isSessionCookieValid: true
        )
        let keychainRepository = KeychainRepositoryFake()
        let sessionRepository = ChatGPTSessionRepositoryFake()
        let appModel = makeAppModel(
            keychainRepository: keychainRepository,
            chatGPTUsageService: chatGPTService,
            chatGPTSessionRepository: sessionRepository
        )

        let result = try await appModel.validateAndSaveChatGPTSessionCookie("chatgpt-session-redacted")

        XCTAssertTrue(result)
        let savedChatGPTSession = try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount)
        XCTAssertEqual(savedChatGPTSession.sessionCookie, "chatgpt-session-redacted")
        await XCTAssertThrowsErrorAsync(try await keychainRepository.retrieve(account: "default"))
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertTrue(appModel.settings.isChatGPTUsageShown)
        XCTAssertEqual(appModel.chatGPTUsageData, expectedUsage)
        XCTAssertNil(appModel.chatGPTErrorMessage)
    }

    func test_validateAndSaveChatGPTSessionCookie_withInvalidCookieDoesNotSave() async throws {
        let chatGPTService = ChatGPTUsageServiceStub(isSessionCookieValid: false)
        let keychainRepository = KeychainRepositoryFake()
        let sessionRepository = ChatGPTSessionRepositoryFake()
        let appModel = makeAppModel(
            keychainRepository: keychainRepository,
            chatGPTUsageService: chatGPTService,
            chatGPTSessionRepository: sessionRepository
        )

        let result = try await appModel.validateAndSaveChatGPTSessionCookie("chatgpt-session-redacted")

        XCTAssertFalse(result)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        await XCTAssertThrowsErrorAsync(try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount))
    }

    func test_refreshChatGPTUsage_failureDoesNotOverwriteClaudeUsageOrError() async {
        let claudeUsage = makeClaudeUsage(percentage: 42)
        let chatGPTService = ChatGPTUsageServiceStub(
            fetchUsageResult: .failure(ChatGPTUsageError.networkUnavailable)
        )
        let keychainRepository = KeychainRepositoryFake()
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try? await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = makeAppModel(
            keychainRepository: keychainRepository,
            chatGPTUsageService: chatGPTService,
            chatGPTSessionRepository: sessionRepository
        )
        appModel.usageData = claudeUsage
        appModel.errorMessage = "Claude error stays separate"

        await appModel.refreshChatGPTUsage()

        XCTAssertEqual(appModel.usageData, claudeUsage)
        XCTAssertEqual(appModel.errorMessage, "Claude error stays separate")
        XCTAssertEqual(appModel.chatGPTErrorMessage, "ChatGPT quota data is unavailable. Check your connection and try again.")
        XCTAssertNil(appModel.chatGPTUsageData)
    }

    /// Target invariant A: a transient poll failure (httpError/network) keeps
    /// the last-good chatGPTUsageData intact and only surfaces the error.
    func test_refreshChatGPTUsage_transientFailureKeepsPreviousDataAndSetsErrorMessage() async {
        let previousUsage = makeChatGPTUsage(percentage: 55)
        let chatGPTService = ChatGPTUsageServiceSequencedStub(results: [
            .success(previousUsage),
            .failure(ChatGPTUsageError.httpError(statusCode: 503))
        ])
        let appModel = makeAppModel(chatGPTUsageService: chatGPTService)
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshChatGPTUsage()
        XCTAssertEqual(appModel.chatGPTUsageData, previousUsage)

        await appModel.refreshChatGPTUsage()

        XCTAssertEqual(appModel.chatGPTUsageData, previousUsage, "Transient failure must not erase last-good data")
        XCTAssertEqual(appModel.chatGPTErrorMessage, ChatGPTUsageError.httpError(statusCode: 503).localizedDescription)
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
    }

    /// Target invariant D: a single invalidSessionCookie poll keeps data and
    /// credential valid-with-error; only the second *consecutive* one flips
    /// the credential to invalid.
    func test_refreshChatGPTUsage_singleInvalidSessionKeepsValidState_secondConsecutiveFlipsInvalid() async {
        let previousUsage = makeChatGPTUsage(percentage: 55)
        let chatGPTService = ChatGPTUsageServiceSequencedStub(results: [
            .success(previousUsage),
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .failure(ChatGPTUsageError.invalidSessionCookie)
        ])
        let appModel = makeAppModel(chatGPTUsageService: chatGPTService)
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshChatGPTUsage() // seed last-good data

        await appModel.refreshChatGPTUsage() // 1st consecutive invalidSessionCookie
        XCTAssertEqual(appModel.chatGPTUsageData, previousUsage)
        XCTAssertTrue(appModel.hasChatGPTSessionCookie, "One failed poll must not surface reconnect UI")
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(appModel.chatGPTErrorMessage, ChatGPTUsageError.invalidSessionCookie.localizedDescription)

        await appModel.refreshChatGPTUsage() // 2nd consecutive invalidSessionCookie
        XCTAssertEqual(appModel.chatGPTUsageData, previousUsage, "Last-good data survives even the flip to invalid")
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .invalid)
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)
    }

    /// Target invariant D: a success between two invalidSessionCookie polls
    /// resets the consecutive-failure counter, so the credential does not
    /// flip to invalid.
    func test_refreshChatGPTUsage_successBetweenFailuresResetsConsecutiveInvalidSessionCounter() async {
        let usage = makeChatGPTUsage(percentage: 55)
        let chatGPTService = ChatGPTUsageServiceSequencedStub(results: [
            .success(usage),
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .success(usage),
            .failure(ChatGPTUsageError.invalidSessionCookie)
        ])
        let appModel = makeAppModel(chatGPTUsageService: chatGPTService)
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshChatGPTUsage() // success
        await appModel.refreshChatGPTUsage() // 1st invalidSessionCookie
        await appModel.refreshChatGPTUsage() // success resets counter
        await appModel.refreshChatGPTUsage() // 1st invalidSessionCookie again (not 2nd consecutive)

        XCTAssertTrue(appModel.hasChatGPTSessionCookie, "A success in between must reset the consecutive counter")
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(appModel.chatGPTUsageData, usage)
    }

    /// F4: once a provider rejection has flipped health to `.invalid`
    /// (`.providerRejected`), keychain presence alone must not resurrect it
    /// to `.valid` mid-poll -- `validate()` only proves the cookie is still
    /// THERE, not that the provider accepts it again. Uses a gated stub to
    /// inspect state while the poll is in flight, which is the only place
    /// the pre-fix flap was ever externally observable (the poll's own
    /// failure re-flips it back to `.invalid` by the time the call returns
    /// either way).
    func test_refreshChatGPTUsage_keychainPresenceDoesNotResurrectHealthMidPollWhenProviderRejected() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let gatedService = ChatGPTUsageServiceGatedStub(results: [
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .failure(ChatGPTUsageError.invalidSessionCookie),
        ])
        let appModel = makeAppModel(chatGPTUsageService: gatedService, chatGPTSessionRepository: sessionRepository)
        appModel.hasChatGPTSessionCookie = true

        // Drive the credential to genuinely provider-rejected through real
        // consecutive polls, exactly like target invariant D's own test --
        // the counter that decides this is private, so there is no shortcut.
        await appModel.refreshChatGPTUsage() // 1st consecutive invalidSessionCookie
        await appModel.refreshChatGPTUsage() // 2nd consecutive -> flips to invalid
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .invalid)
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)

        // The cookie is dead but still present in the Keychain (only explicit
        // disconnect ever deletes it), so the next poll's top-of-function
        // revalidation will find it there. Gate the 3rd fetch to inspect
        // state exactly while that poll is in flight -- the only place the
        // pre-fix flap was ever externally observable (the poll's own
        // failure re-flips it back to `.invalid` by the time the call
        // returns either way).
        await gatedService.armGateForNextCall()
        let pollTask = Task { await appModel.refreshChatGPTUsage() }
        await gatedService.waitUntilGatedCallEntered()

        XCTAssertEqual(
            appModel.chatGPTCredentialState.health, .invalid,
            "keychain presence alone must not resurrect health mid-poll"
        )
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)

        await gatedService.release()
        await pollTask.value

        XCTAssertEqual(
            appModel.chatGPTCredentialState.health, .invalid,
            "a genuinely dead cookie must still read invalid once the poll fails again"
        )
        XCTAssertEqual(appModel.chatGPTCredentialState.failureCategory, .providerRejected)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
    }

    /// F4: recovery must still be possible -- a successful fetch after a
    /// provider-rejected state clears the credential back to valid, exactly
    /// as it does for any other failure category.
    func test_refreshChatGPTUsage_successfulPollRecoversFromProviderRejected() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let recoveredUsage = makeChatGPTUsage(percentage: 33)
        let chatGPTService = ChatGPTUsageServiceSequencedStub(results: [
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .success(recoveredUsage),
        ])
        let appModel = makeAppModel(chatGPTUsageService: chatGPTService, chatGPTSessionRepository: sessionRepository)
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshChatGPTUsage() // 1st consecutive invalidSessionCookie
        await appModel.refreshChatGPTUsage() // 2nd consecutive -> flips to invalid
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .invalid)

        await appModel.refreshChatGPTUsage() // the provider accepts the session again

        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertNil(appModel.chatGPTCredentialState.failureCategory)
        XCTAssertEqual(appModel.chatGPTUsageData, recoveredUsage)
        XCTAssertNil(appModel.chatGPTErrorMessage)
    }

    /// F10: a Keychain read failure (`ChatGPTUsageError.secureStorageUnavailable`)
    /// must surface its own honest message, keep last-good data, and not
    /// count toward (or itself trip) the consecutive-invalidSessionCookie
    /// streak -- it says nothing about whether the provider still accepts
    /// the session.
    func test_refreshChatGPTUsage_secureStorageUnavailable_surfacesHonestMessageAndDoesNotCountTowardInvalidSessionStreak() async {
        let previousUsage = makeChatGPTUsage(percentage: 55)
        let chatGPTService = ChatGPTUsageServiceSequencedStub(results: [
            .success(previousUsage),
            .failure(ChatGPTUsageError.invalidSessionCookie),
            .failure(ChatGPTUsageError.secureStorageUnavailable),
            .failure(ChatGPTUsageError.invalidSessionCookie)
        ])
        let appModel = makeAppModel(chatGPTUsageService: chatGPTService)
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshChatGPTUsage() // seed last-good data
        await appModel.refreshChatGPTUsage() // 1st consecutive invalidSessionCookie
        await appModel.refreshChatGPTUsage() // secureStorageUnavailable

        XCTAssertEqual(appModel.chatGPTUsageData, previousUsage, "last-good data must survive a Keychain read failure")
        XCTAssertEqual(
            appModel.chatGPTErrorMessage,
            ChatGPTUsageError.secureStorageUnavailable.localizedDescription
        )
        XCTAssertTrue(appModel.hasChatGPTSessionCookie, "must not clear credential state on a storage failure")
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid, "must not itself trip provider-rejected health")

        await appModel.refreshChatGPTUsage() // 1st invalidSessionCookie again -- not 2nd consecutive

        XCTAssertTrue(
            appModel.hasChatGPTSessionCookie,
            "the storage failure must not have counted toward the consecutive invalidSessionCookie streak"
        )
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
    }

    /// Target invariant E: `chatGPTUsageData` is memory-only otherwise, so
    /// bootstrap must seed it from the persisted cache before the first poll
    /// runs, preserving the original `lastUpdated` (never faked to "now").
    func test_bootstrap_loadsPersistedChatGPTUsageWithOriginalLastUpdated() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let originalLastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        let persistedUsage = ChatGPTUsageData(
            rows: [.init(label: "Codex weekly", usedPercent: 47, resetAt: nil)],
            lastUpdated: originalLastUpdated
        )
        let cacheRepository = ChatGPTUsageCacheRepositoryFake(savedData: persistedUsage)
        // Never-resolving fetch: this test only checks the state bootstrap
        // establishes before/regardless of the first poll completing, so the
        // provider is left unconfigured to keep refreshConfiguredUsageProviders
        // from touching chatGPTUsageData at all in this test.
        let appModel = makeAppModel(
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: cacheRepository
        )
        appModel.settings.isChatGPTUsageShown = false

        await appModel.bootstrap()

        XCTAssertEqual(appModel.chatGPTUsageData, persistedUsage)
        XCTAssertEqual(appModel.chatGPTUsageData?.lastUpdated, originalLastUpdated)
    }

    func test_clearChatGPTSessionCookie_deletesOnlyChatGPTAccountAndHidesUsage() async throws {
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let cacheRepository = ChatGPTUsageCacheRepositoryFake(savedData: makeChatGPTUsage(percentage: 1))
        let appModel = makeAppModel(
            keychainRepository: keychainRepository,
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: cacheRepository
        )
        appModel.settings.isChatGPTUsageShown = true
        appModel.chatGPTUsageData = makeChatGPTUsage(percentage: 1)
        appModel.chatGPTErrorMessage = "old error"
        appModel.hasChatGPTSessionCookie = true

        try await appModel.clearChatGPTSessionCookie()

        let savedClaudeKey = try await keychainRepository.retrieve(account: "default")
        XCTAssertEqual(savedClaudeKey, TestConstants.sessionKeyValue)
        await XCTAssertThrowsErrorAsync(try await sessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount))
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
        XCTAssertNil(appModel.chatGPTUsageData)
        XCTAssertNil(appModel.chatGPTErrorMessage)
        let persistedAfterClear = await cacheRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertNil(persistedAfterClear, "Explicit disconnect must also clear the disk-persisted snapshot")
    }

    func test_scanExcludedChatGPTAccount_isSkippedUntilReenabled() async throws {
        let sessionRepository = ChatGPTSessionRepositoryFake()
        let importService = SessionKeyImportServiceStub(
            result: .failure(SessionKeyImportError.noSessionKeyFound),
            chatGPTResult: .success(ImportedChatGPTSessionCookie(
                cookieHeader: "chatgpt-session-redacted",
                sourceDescription: "Chrome Default"
            ))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(makeClaudeUsage(percentage: 10))),
            chatGPTUsageService: ChatGPTUsageServiceStub(),
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService
        )

        _ = try await appModel.importAndSaveChatGPTSessionCookie(from: .chrome)
        try await appModel.excludeChatGPTAccountFromScans()

        do {
            _ = try await appModel.importAndSaveChatGPTSessionCookie(from: .chrome)
            XCTFail("Expected excluded account to be skipped")
        } catch SessionKeyImportError.allDiscoveredAccountsExcluded {
            // Expected.
        }

        let exclusion = try XCTUnwrap(appModel.settings.scanExcludedAccounts.first)
        appModel.reenableScanAccount(id: exclusion.id)
        _ = try await appModel.importAndSaveChatGPTSessionCookie(from: .chrome)

        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        XCTAssertTrue(appModel.settings.scanExcludedAccounts.isEmpty)
    }

    private func makeAppModel(
        keychainRepository: KeychainRepositoryFake = KeychainRepositoryFake(),
        chatGPTUsageService: ChatGPTUsageServiceProtocol = ChatGPTUsageServiceStub(),
        chatGPTSessionRepository: ChatGPTSessionRepositoryFake = ChatGPTSessionRepositoryFake(),
        chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake = ChatGPTUsageCacheRepositoryFake()
    ) -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .success(makeClaudeUsage(percentage: 10))),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            chatGPTUsageCacheRepository: chatGPTUsageCacheRepository,
            notificationService: NotificationServiceSpy()
        )
    }
}

private actor ChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
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

    func setStatus(_ status: ChatGPTSessionAcquisitionStatus) {
        self.status = status
    }

    func clear(account: String) async throws {
        sessions[account] = nil
        status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

/// Returns one queued result per call to `fetchUsage()`, holding on the last
/// entry once exhausted -- lets a single test drive AppModel through a
/// specific sequence of poll outcomes (success/failure/success/...) to
/// exercise the consecutive-invalidSessionCookie counter (target invariant D).
private actor ChatGPTUsageServiceSequencedStub: ChatGPTUsageServiceProtocol {
    private var results: [Result<ChatGPTUsageData, Error>]

    init(results: [Result<ChatGPTUsageData, Error>]) {
        self.results = results
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        let result = results.count > 1 ? results.removeFirst() : (results.first ?? .failure(ChatGPTUsageError.networkUnavailable))
        switch result {
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
        true
    }
}

/// Same queued-results driving as `ChatGPTUsageServiceSequencedStub`, plus an
/// opt-in gate: `armGateForNextCall()` makes the NEXT `fetchUsage()` suspend
/// until the test calls `release()`, so a test can inspect `AppModel` state
/// while that specific poll is genuinely in flight -- the only window in
/// which the F4 flap this stub exercises was ever externally observable (see
/// `ChatGPTAppModelTests`'s mid-poll test). Calls made without arming the
/// gate first resolve immediately, same as the ungated sequenced stub.
private actor ChatGPTUsageServiceGatedStub: ChatGPTUsageServiceProtocol {
    private var results: [Result<ChatGPTUsageData, Error>]
    private var shouldGateNextCall = false
    private var hasEnteredGatedCall = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(results: [Result<ChatGPTUsageData, Error>]) {
        self.results = results
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        if shouldGateNextCall {
            shouldGateNextCall = false
            hasEnteredGatedCall = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { self.releaseContinuation = $0 }
        }
        let result = results.count > 1 ? results.removeFirst() : (results.first ?? .failure(ChatGPTUsageError.networkUnavailable))
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        true
    }

    /// Arms the gate for the next `fetchUsage()` call only.
    func armGateForNextCall() {
        shouldGateNextCall = true
        hasEnteredGatedCall = false
    }

    /// Suspends until the gated `fetchUsage()` call has been entered.
    func waitUntilGatedCallEntered() async {
        if hasEnteredGatedCall { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    /// Lets the in-flight gated call resolve.
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    let fetchUsageResult: Result<ChatGPTUsageData, Error>
    let isSessionCookieValid: Bool

    init(
        fetchUsageResult: Result<ChatGPTUsageData, Error> = .success(makeChatGPTUsage(percentage: 10)),
        isSessionCookieValid: Bool = true
    ) {
        self.fetchUsageResult = fetchUsageResult
        self.isSessionCookieValid = isSessionCookieValid
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        try await fetchUsage(sessionCookie: "stored-chatgpt-session-redacted")
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        switch fetchUsageResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        isSessionCookieValid
    }
}

private func makeClaudeUsage(percentage: Double) -> UsageData {
    UsageData(
        sessionUsage: UsageLimit(
            utilization: percentage,
            resetAt: Date().addingTimeInterval(3600)
        ),
        weeklyUsage: UsageLimit(
            utilization: 50,
            resetAt: Date().addingTimeInterval(86400)
        ),
        sonnetUsage: nil,
        lastUpdated: Date()
    )
}

private func makeChatGPTUsage(percentage: Double) -> ChatGPTUsageData {
    ChatGPTUsageData(
        rows: [
            .init(label: "Codex Tasks", usedPercent: percentage, resetAt: Date(timeIntervalSince1970: 0))
        ],
        lastUpdated: Date(timeIntervalSince1970: 0)
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected
    }
}
