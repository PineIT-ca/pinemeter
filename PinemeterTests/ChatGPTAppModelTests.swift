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

    func test_clearChatGPTSessionCookie_deletesOnlyChatGPTAccountAndHidesUsage() async throws {
        let keychainRepository = KeychainRepositoryFake()
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = ChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = makeAppModel(
            keychainRepository: keychainRepository,
            chatGPTSessionRepository: sessionRepository
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
    }

    private func makeAppModel(
        keychainRepository: KeychainRepositoryFake = KeychainRepositoryFake(),
        chatGPTUsageService: ChatGPTUsageServiceProtocol = ChatGPTUsageServiceStub(),
        chatGPTSessionRepository: ChatGPTSessionRepositoryFake = ChatGPTSessionRepositoryFake()
    ) -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .success(makeClaudeUsage(percentage: 10))),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
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
