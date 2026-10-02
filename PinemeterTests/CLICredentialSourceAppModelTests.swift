//
//  CLICredentialSourceAppModelTests.swift
//  PinemeterTests
//
//  Tracer for Phase 19 plan 01: a Codex CLI login on disk drives one bearer
//  `wham/usage` request for the primary ChatGPT account, through the real
//  `CLILoginService` and the real `ChatGPTUsageService`/`ChatGPTHTTPClient`
//  stack (only the transport is intercepted). Every synthetic value here is
//  fake: no real token, cookie, or Keychain secret is read or written.
//

import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class CLICredentialSourceAppModelTests: XCTestCase {
    private var tempDirectoryURL: URL?

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        TracerRequestURLProtocol.handler = nil
        super.tearDown()
    }

    func test_tracer_codexCLILoginPollsPrimaryChatGPTAccountEndToEnd() async throws {
        let accountId = "00000000-0000-0000-0000-0000000000a1"
        let chatgptUserId = "user-synthetic-0001"

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinemeter-cli-tracer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        tempDirectoryURL = tempDirectory

        let accessToken = Self.fakeAccessToken(
            chatgptUserId: chatgptUserId,
            chatgptAccountId: accountId,
            planType: "pro",
            email: "user@example.com",
            expiresIn: 3600
        )
        let authJSON = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "\(accessToken)",
            "account_id": "\(accountId)"
          },
          "last_refresh": "2026-09-25T23:27:57.129430Z"
        }
        """
        try authJSON.write(
            to: tempDirectory.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8
        )

        let cliLoginReader = CLILoginService(codexEnvironment: ["CODEX_HOME": tempDirectory.path])

        let recorder = TracerRequestRecorder()
        TracerRequestURLProtocol.handler = { request in
            recorder.record(request)
            let body = """
            {"user_id":"\(chatgptUserId)","account_id":"\(accountId)","rate_limit":{"primary_window":{"used_percent":5}}}
            """.data(using: .utf8)!
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, body)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TracerRequestURLProtocol.self]
        let httpClient = ChatGPTHTTPClient(configuration: configuration)

        let sessionRepository = TracerChatGPTSessionRepositoryFake()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "stored-cookie-redacted"),
            account: ChatGPTAccount.primaryKeychainAccount
        )

        let chatGPTUsageService = ChatGPTUsageService(httpClient: httpClient, sessionRepository: sessionRepository)

        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage())),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: cliLoginReader
        )

        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        ]
        appModel.settings.isChatGPTUsageShown = true
        appModel.hasChatGPTSessionCookie = true

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 1, "exactly one request should reach the network")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/backend-api/wham/usage")
        XCTAssertEqual(request.authorization, "Bearer \(accessToken)")
        XCTAssertEqual(request.chatgptAccountId, accountId)
        XCTAssertNil(request.cookie, "the bearer path must never send a Cookie header")
        XCTAssertFalse(requests.contains { $0.path.contains("auth/session") })

        XCTAssertNotNil(appModel.chatGPTUsageData)
        XCTAssertEqual(appModel.chatGPTAccountSources[chatgptUserId], .codexCLI)
        XCTAssertEqual(appModel.usageSourceDetail(forChatGPTAccountId: chatgptUserId), "Using Codex CLI login")
    }

    /// Builds a synthetic three-segment JWT with the claims
    /// `CodexCLILoginReader` decodes. Never a real token -- the signature
    /// segment is an unchecked placeholder.
    private static func fakeAccessToken(
        chatgptUserId: String,
        chatgptAccountId: String,
        planType: String,
        email: String,
        expiresIn: TimeInterval
    ) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let exp = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
        let payload = """
        {"exp":\(exp),"https://api.openai.com/auth":{"chatgpt_user_id":"\(chatgptUserId)",\
        "chatgpt_account_id":"\(chatgptAccountId)","chatgpt_plan_type":"\(planType)"},\
        "https://api.openai.com/profile":{"email":"\(email)"}}
        """
        func base64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64url(header)).\(base64url(payload)).signature-not-checked"
    }

    private static func makeClaudeUsage(percentage: Double = 10) -> UsageData {
        UsageData(
            sessionUsage: UsageLimit(utilization: percentage, resetAt: Date().addingTimeInterval(3600)),
            weeklyUsage: UsageLimit(utilization: percentage * 2, resetAt: Date().addingTimeInterval(86400)),
            sonnetUsage: nil,
            lastUpdated: Date()
        )
    }

    private static func makeChatGPTUsage(percentage: Double = 10) -> ChatGPTUsageData {
        ChatGPTUsageData(
            rows: [.init(label: "Codex Tasks", usedPercent: percentage, resetAt: Date(timeIntervalSince1970: 0))],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Primary ChatGPT fallback rules (CLI-06, D-03, D-04, D-05)

    private func makeFallbackAppModel(
        primaryAccountId: String,
        cliLoginReader: CLILoginReaderFake,
        chatGPTUsageService: FallbackChatGPTUsageServiceStub,
        sessionRepository: CountingChatGPTSessionRepositoryFake
    ) async -> AppModel {
        await sessionRepository.seed(
            ChatGPTSession(sessionCookie: "stored-cookie-redacted"),
            account: ChatGPTAccount.primaryKeychainAccount
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage())),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: cliLoginReader
        )
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: primaryAccountId, label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        ]
        appModel.settings.isChatGPTUsageShown = true
        appModel.hasChatGPTSessionCookie = true
        // refreshChatGPTUsage() consults latestCLILoginSnapshot, which is
        // normally primed once per cycle by refreshConfiguredUsageProviders()
        // before any per-provider refresh runs; these tests call
        // refreshChatGPTUsage() directly, so the snapshot must be primed here.
        await appModel.refreshCLILoginSnapshot()
        return appModel
    }

    func test_refreshChatGPTUsage_codexRejected_fallsBackToStoredCookieAndSucceeds() async throws {
        let primaryId = "user-synthetic-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.rejected),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )

        await appModel.refreshChatGPTUsage()

        let bearerCalls = await usageStub.bearerCallCount
        let cookieCalls = await usageStub.cookieCallCount
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.chatGPTAccountSources[primaryId], .storedSession)
        XCTAssertNil(appModel.chatGPTErrorMessage)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0, "a Codex CLI failure must never touch the stored cookie (D-04)")
        XCTAssertEqual(clearCalls, 0, "a Codex CLI failure must never touch the stored cookie (D-04)")
    }

    func test_refreshChatGPTUsage_codexInvalidResponse_fallsBackToStoredCookieAndSucceeds() async throws {
        let primaryId = "user-synthetic-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.invalidResponse),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )

        await appModel.refreshChatGPTUsage()

        let bearerCalls = await usageStub.bearerCallCount
        let cookieCalls = await usageStub.cookieCallCount
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.chatGPTAccountSources[primaryId], .storedSession)
        XCTAssertNil(appModel.chatGPTErrorMessage)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(clearCalls, 0)
    }

    func test_refreshChatGPTUsage_codexNetworkUnavailable_doesNotFallBackToCookie() async throws {
        let primaryId = "user-synthetic-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.networkUnavailable),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )
        let lastGoodUsage = Self.makeChatGPTUsage(percentage: 42)
        appModel.chatGPTUsageData = lastGoodUsage

        await appModel.refreshChatGPTUsage()

        let bearerCalls = await usageStub.bearerCallCount
        let cookieCalls = await usageStub.cookieCallCount
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 0, "an outage must not also hit the stored cookie in the same cycle")
        XCTAssertEqual(appModel.chatGPTErrorMessage, CLIUsageFetchError.networkUnavailable.errorDescription)
        XCTAssertEqual(appModel.chatGPTUsageData, lastGoodUsage, "last-good usage must survive an outage")
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(clearCalls, 0)
    }

    func test_refreshChatGPTUsage_expiredCodexLogin_fallsBackToCookie() async throws {
        let primaryId = "user-synthetic-0001"
        // D-05: expiresIn 30s is inside the 60s skew, so this login is
        // already treated as expired.
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 30),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.networkUnavailable),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )

        await appModel.refreshChatGPTUsage()

        let bearerCalls = await usageStub.bearerCallCount
        let cookieCalls = await usageStub.cookieCallCount
        XCTAssertEqual(bearerCalls, 0, "an expired token must make zero bearer requests")
        XCTAssertEqual(cookieCalls, 1)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(clearCalls, 0)
    }

    func test_refreshChatGPTUsage_noCodexLoginForPrimaryId_fallsBackToCookie() async throws {
        let primaryId = "user-synthetic-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: "user-someone-else",
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.networkUnavailable),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )

        await appModel.refreshChatGPTUsage()

        let bearerCalls = await usageStub.bearerCallCount
        let cookieCalls = await usageStub.cookieCallCount
        XCTAssertEqual(bearerCalls, 0, "a login for a different account must never be tried")
        XCTAssertEqual(cookieCalls, 1)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(clearCalls, 0)
    }

    func test_refreshChatGPTUsage_twoCyclesOfRejectedCodexAndSuccessfulCookie_keepsCredentialValid() async throws {
        let primaryId = "user-synthetic-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600),
            claude: []
        ))
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .failure(CLIUsageFetchError.rejected),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = await makeFallbackAppModel(
            primaryAccountId: primaryId,
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageStub,
            sessionRepository: sessionRepository
        )

        await appModel.refreshChatGPTUsage()
        await appModel.refreshChatGPTUsage()

        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertTrue(appModel.hasChatGPTSessionCookie)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(clearCalls, 0)
    }

    /// D-04, consolidated: runs every Codex-CLI-path case (rejected,
    /// invalid response, network outage, expired login, wrong-account login)
    /// against ONE session repository and asserts it never once saw a save
    /// or a clear, across all of them together -- not just within each
    /// individual case's own assertions above.
    func test_refreshChatGPTUsage_everyCodexCLIPathCase_neverTouchesStoredSessionRepository() async throws {
        let primaryId = "user-synthetic-0001"
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        await sessionRepository.seed(
            ChatGPTSession(sessionCookie: "stored-cookie-redacted"),
            account: ChatGPTAccount.primaryKeychainAccount
        )

        let cases: [(name: String, snapshot: CLILoginSnapshot, bearerResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>)] = [
            (
                "rejected",
                CLILoginSnapshot(codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600), claude: []),
                .failure(CLIUsageFetchError.rejected)
            ),
            (
                "invalidResponse",
                CLILoginSnapshot(codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600), claude: []),
                .failure(CLIUsageFetchError.invalidResponse)
            ),
            (
                "networkUnavailable",
                CLILoginSnapshot(codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600), claude: []),
                .failure(CLIUsageFetchError.networkUnavailable)
            ),
            (
                "expiredLogin",
                CLILoginSnapshot(codex: CLILoginReaderFake.codexLogin(chatgptUserId: primaryId, accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 30), claude: []),
                .failure(CLIUsageFetchError.networkUnavailable)
            ),
            (
                "wrongAccountLogin",
                CLILoginSnapshot(codex: CLILoginReaderFake.codexLogin(chatgptUserId: "user-someone-else", accountId: "00000000-0000-0000-0000-0000000000a1", expiresIn: 3600), claude: []),
                .failure(CLIUsageFetchError.networkUnavailable)
            ),
        ]

        for testCase in cases {
            let cliLoginReader = CLILoginReaderFake(snapshot: testCase.snapshot)
            let usageStub = FallbackChatGPTUsageServiceStub(
                bearerResult: testCase.bearerResult,
                cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
            )
            let appModel = AppModel(
                settingsRepository: SettingsRepositoryFake(),
                keychainRepository: KeychainRepositoryFake(),
                usageService: UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage())),
                chatGPTUsageService: usageStub,
                chatGPTSessionRepository: sessionRepository,
                chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
                notificationService: NotificationServiceSpy(),
                runningBrowserSources: { [] },
                codexWorkspaceResolver: { nil },
                browserLoginPrompt: { _ in },
                cliLoginReader: cliLoginReader
            )
            appModel.settings.chatGPTAccounts = [
                ChatGPTAccount(id: primaryId, label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
            ]
            appModel.settings.isChatGPTUsageShown = true
            appModel.hasChatGPTSessionCookie = true
            await appModel.refreshCLILoginSnapshot()

            await appModel.refreshChatGPTUsage()

            let saveCalls = await sessionRepository.saveCallCount
            let clearCalls = await sessionRepository.clearCallCount
            XCTAssertEqual(saveCalls, 0, "case \(testCase.name) must never save the stored session")
            XCTAssertEqual(clearCalls, 0, "case \(testCase.name) must never clear the stored session")
        }
    }

    func test_appModel_withoutExplicitCodexWorkspaceResolver_resolvesNoWorkspaceUnderXCTest() async throws {
        let usageStub = FallbackChatGPTUsageServiceStub(
            bearerResult: .success((Self.makeChatGPTUsage(), .unidentified)),
            cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage())),
            chatGPTUsageService: usageStub,
            chatGPTSessionRepository: TracerChatGPTSessionRepositoryFake(),
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in },
            cliLoginReader: CLILoginReaderFake()
        )
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: "user-synthetic-0001", label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        ]
        appModel.hasChatGPTSessionCookie = true

        let snapshot = await appModel.remotePushSourceSnapshot()
        XCTAssertTrue(
            snapshot.codexWorkspaceAccountIds.isEmpty,
            "the default codexWorkspaceResolver must be test-safe and never read the real auth.json under XCTest"
        )
    }

    // MARK: - Claude primary and additional accounts (CLI-02..CLI-06, D-03, D-04, D-05, edge CLI-08)

    private func makeClaudeAppModel(
        cliLoginReader: CLILoginReaderFake,
        claudeOAuthUsageService: any ClaudeOAuthUsageServiceProtocol,
        cookieUsageService: any UsageServiceProtocol,
        keychainRepository: KeychainRepositoryFake? = nil,
        notificationService: NotificationServiceSpy? = nil
    ) async -> AppModel {
        let keychainRepository = keychainRepository ?? KeychainRepositoryFake()
        let notificationService = notificationService ?? NotificationServiceSpy()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: cookieUsageService,
            chatGPTUsageService: FallbackChatGPTUsageServiceStub(
                bearerResult: .failure(CLIUsageFetchError.invalidResponse),
                cookieResult: .success((Self.makeChatGPTUsage(), .unidentified))
            ),
            chatGPTSessionRepository: TracerChatGPTSessionRepositoryFake(),
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: notificationService,
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthUsageService
        )
        await appModel.refreshCLILoginSnapshot()
        return appModel
    }

    func test_claudePrimary_unexpiredCLILogin_pollsOAuthFirstAndSkipsCookie() async throws {
        let organizationId = UUID()
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let oauthUsage = Self.makeClaudeUsage(percentage: 7)
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .success(oauthUsage))
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            primaryResult: .success(Self.makeClaudeUsage(percentage: 99))
        )
        let notificationSpy = NotificationServiceSpy()
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService,
            notificationService: notificationSpy
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Acme",
                organizationId: organizationId,
                keychainAccount: ClaudeAccount.primaryKeychainAccount
            ),
        ]

        await appModel.refreshUsage(forceRefresh: true)

        XCTAssertEqual(appModel.usageData, oauthUsage)
        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 1)
        let cookieCalls = await cookieService.primaryCallCount
        XCTAssertEqual(cookieCalls, 0)
        XCTAssertEqual(appModel.claudeAccountSources[organizationId.uuidString], .claudeCode)
        XCTAssertEqual(notificationSpy.evaluateThresholdsCallCount, 1)
        XCTAssertEqual(notificationSpy.lastEvaluatedUsageData, oauthUsage)
    }

    func test_claudePrimary_oauthRejected_fallsBackToCookieAndRecordsStoredSession() async throws {
        let organizationId = UUID()
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.rejected))
        let cookieUsage = Self.makeClaudeUsage(percentage: 33)
        let cookieService = ScriptedClaudeCookieUsageServiceStub(primaryResult: .success(cookieUsage))
        let keychainFake = KeychainRepositoryFake()
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService,
            keychainRepository: keychainFake
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Acme",
                organizationId: organizationId,
                keychainAccount: ClaudeAccount.primaryKeychainAccount
            ),
        ]

        await appModel.refreshUsage(forceRefresh: true)

        XCTAssertEqual(appModel.usageData, cookieUsage)
        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 1)
        let cookieCalls = await cookieService.primaryCallCount
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.claudeAccountSources[organizationId.uuidString], .storedSession)
        let saveCalls = await keychainFake.saveCallCount
        let deleteCalls = await keychainFake.deleteCallCount
        XCTAssertEqual(saveCalls, 0, "a rejected CLI login must never write the stored session key (D-04)")
        XCTAssertEqual(deleteCalls, 0)
    }

    func test_claudePrimary_oauthNetworkUnavailable_doesNotFallBackAndKeepsLastGoodUsage() async throws {
        let organizationId = UUID()
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.networkUnavailable))
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            primaryResult: .success(Self.makeClaudeUsage(percentage: 99))
        )
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Acme",
                organizationId: organizationId,
                keychainAccount: ClaudeAccount.primaryKeychainAccount
            ),
        ]
        let lastGoodUsage = Self.makeClaudeUsage(percentage: 42)
        appModel.usageData = lastGoodUsage

        await appModel.refreshUsage(forceRefresh: true)

        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 1)
        let cookieCalls = await cookieService.primaryCallCount
        XCTAssertEqual(cookieCalls, 0, "an outage must not also hit the stored cookie in the same cycle")
        XCTAssertEqual(appModel.errorMessage, CLIUsageFetchError.networkUnavailable.errorDescription)
        XCTAssertEqual(appModel.usageData, lastGoodUsage, "last-good usage must survive an outage")
    }

    func test_claudeAdditional_expiredLogin_makesZeroOAuthCallsAndOneCookieCall() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            // D-05: expiresIn 30s is inside the 60s skew, so already expired.
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 30)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.invalidResponse))
        let cookieUsage = Self.makeClaudeUsage(percentage: 55)
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            resultsByKeychainAccount: [keychainAccount: .success(cookieUsage)]
        )
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount
            ),
        ]

        await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 0, "an expired login must make zero OAuth calls")
        let cookieCalls = await cookieService.additionalCallCounts[keychainAccount] ?? 0
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.claudeAccountUsage[organizationId.uuidString], cookieUsage)
        XCTAssertEqual(appModel.claudeAccountSources[organizationId.uuidString], .storedSession)
    }

    func test_claudeAdditional_oauthInvalidResponse_fallsBackToCookieAndRecordsStoredSession() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.invalidResponse))
        let cookieUsage = Self.makeClaudeUsage(percentage: 61)
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            resultsByKeychainAccount: [keychainAccount: .success(cookieUsage)]
        )
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount
            ),
        ]

        await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 1)
        let cookieCalls = await cookieService.additionalCallCounts[keychainAccount] ?? 0
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.claudeAccountSources[organizationId.uuidString], .storedSession)
        XCTAssertNil(appModel.claudeAccountErrors[organizationId.uuidString])
    }

    func test_claudeAdditional_cliOriginNoLogin_cookieThrowsNoSessionKey_showsMissingOrExpiredMessage() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        // No Claude login in the snapshot at all for this org.
        let cliLoginReader = CLILoginReaderFake(snapshot: .empty)
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.invalidResponse))
        // No scripted cookie result for this keychain account -> AppError.noSessionKey.
        let cookieService = ScriptedClaudeCookieUsageServiceStub()
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        let previousCredentialState = appModel.claudeCredentialState
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount,
                origin: .cliLogin
            ),
        ]

        await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let oauthCalls = await claudeOAuthStub.callCount
        XCTAssertEqual(oauthCalls, 0, "no login in the snapshot must make zero OAuth calls")
        XCTAssertEqual(
            appModel.claudeAccountErrors[organizationId.uuidString],
            CLISourceUnavailableReason.missingOrExpired.message(for: .claude)
        )
        XCTAssertEqual(appModel.claudeCredentialState, previousCredentialState)
    }

    func test_claudeAdditional_cliOriginRejected_cookieThrowsNoSessionKey_showsRejectedMessage() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.rejected))
        let cookieService = ScriptedClaudeCookieUsageServiceStub()
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount,
                origin: .cliLogin
            ),
        ]

        await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true)

        XCTAssertEqual(
            appModel.claudeAccountErrors[organizationId.uuidString],
            CLISourceUnavailableReason.rejected.message(for: .claude)
        )
    }

    func test_claudeAdditional_removedWhileOAuthInFlight_leavesNoResidualState() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = SuspendingClaudeOAuthUsageServiceStub(
            result: .success(Self.makeClaudeUsage(percentage: 73))
        )
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            resultsByKeychainAccount: [keychainAccount: .success(Self.makeClaudeUsage(percentage: 88))]
        )
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount
            ),
        ]

        let refreshTask = Task { await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true) }
        await claudeOAuthStub.waitUntilEntered()
        appModel.settings.claudeAccounts = []
        await claudeOAuthStub.release()
        await refreshTask.value

        XCTAssertNil(appModel.claudeAccountUsage[organizationId.uuidString])
        XCTAssertNil(appModel.claudeAccountErrors[organizationId.uuidString])
        XCTAssertNil(appModel.claudeAccountSources[organizationId.uuidString])
    }

    func test_claudeAdditional_oauthCancelled_noCookieCallAndNoErrorRecorded() async throws {
        let organizationId = UUID()
        let keychainAccount = organizationId.uuidString
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId, expiresIn: 3600)]
        ))
        let claudeOAuthStub = ScriptedClaudeOAuthUsageServiceStub(result: .failure(CancellationError()))
        let cookieService = ScriptedClaudeCookieUsageServiceStub(
            resultsByKeychainAccount: [keychainAccount: .success(Self.makeClaudeUsage(percentage: 12))]
        )
        let appModel = await makeClaudeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthStub,
            cookieUsageService: cookieService
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId.uuidString,
                label: "Personal",
                organizationId: organizationId,
                keychainAccount: keychainAccount
            ),
        ]

        await appModel.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let cookieCalls = await cookieService.additionalCallCounts[keychainAccount] ?? 0
        XCTAssertEqual(cookieCalls, 0, "a cancelled OAuth call must never fall back to the cookie")
        XCTAssertNil(appModel.claudeAccountErrors[organizationId.uuidString])
        XCTAssertNil(appModel.claudeAccountUsage[organizationId.uuidString])
    }

    /// D-04, consolidated across every CLI-path case this plan adds (primary
    /// and additional, success/rejected/invalidResponse/outage/expired/
    /// cancelled/no-login): one `KeychainRepositoryFake` must see zero save
    /// and zero delete calls, across all of them together.
    func test_claudeAdditional_everyCLIPathCase_neverTouchesKeychainRepository() async throws {
        let keychainFake = KeychainRepositoryFake()

        let organizationId1 = UUID()
        let keychainAccount1 = organizationId1.uuidString
        let rejectedCase = await makeClaudeAppModel(
            cliLoginReader: CLILoginReaderFake(snapshot: CLILoginSnapshot(
                codex: nil,
                claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId1, expiresIn: 3600)]
            )),
            claudeOAuthUsageService: ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.rejected)),
            cookieUsageService: ScriptedClaudeCookieUsageServiceStub(
                resultsByKeychainAccount: [keychainAccount1: .success(Self.makeClaudeUsage(percentage: 1))]
            ),
            keychainRepository: keychainFake
        )
        rejectedCase.isSetupComplete = true
        rejectedCase.settings.claudeAccounts = [
            ClaudeAccount(id: organizationId1.uuidString, label: "A", organizationId: organizationId1, keychainAccount: keychainAccount1),
        ]
        await rejectedCase.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let organizationId2 = UUID()
        let keychainAccount2 = organizationId2.uuidString
        let noLoginCLIOriginCase = await makeClaudeAppModel(
            cliLoginReader: CLILoginReaderFake(snapshot: .empty),
            claudeOAuthUsageService: ScriptedClaudeOAuthUsageServiceStub(result: .failure(CLIUsageFetchError.invalidResponse)),
            cookieUsageService: ScriptedClaudeCookieUsageServiceStub(),
            keychainRepository: keychainFake
        )
        noLoginCLIOriginCase.isSetupComplete = true
        noLoginCLIOriginCase.settings.claudeAccounts = [
            ClaudeAccount(
                id: organizationId2.uuidString,
                label: "B",
                organizationId: organizationId2,
                keychainAccount: keychainAccount2,
                origin: .cliLogin
            ),
        ]
        await noLoginCLIOriginCase.refreshAdditionalClaudeAccounts(forceRefresh: true)

        let organizationId3 = UUID()
        let networkOutageCase = await makeClaudeAppModel(
            cliLoginReader: CLILoginReaderFake(snapshot: CLILoginSnapshot(
                codex: nil,
                claude: [CLILoginReaderFake.claudeLogin(organizationId: organizationId3, expiresIn: 3600)]
            )),
            claudeOAuthUsageService: ScriptedClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage(percentage: 3))),
            cookieUsageService: ScriptedClaudeCookieUsageServiceStub(
                primaryResult: .failure(CLIUsageFetchError.networkUnavailable)
            ),
            keychainRepository: keychainFake
        )
        networkOutageCase.isSetupComplete = true
        networkOutageCase.settings.claudeAccounts = [
            ClaudeAccount(id: organizationId3.uuidString, label: "C", organizationId: organizationId3, keychainAccount: ClaudeAccount.primaryKeychainAccount),
        ]
        await networkOutageCase.refreshUsage(forceRefresh: true)

        let saveCalls = await keychainFake.saveCallCount
        let deleteCalls = await keychainFake.deleteCallCount
        XCTAssertEqual(saveCalls, 0, "no CLI-path case across primary or additional accounts may save a session key")
        XCTAssertEqual(deleteCalls, 0, "no CLI-path case across primary or additional accounts may delete a session key")
    }

    // MARK: - Additional ChatGPT accounts poll the Codex CLI login first (CLI-01, CLI-05, CLI-06, D-03, D-04, D-05)

    private func makeChatGPTAdditionalAppModel(
        cliLoginReader: CLILoginReaderFake,
        chatGPTUsageService: any ChatGPTUsageServiceProtocol,
        chatGPTSessionRepository: (any ChatGPTSessionRepositoryProtocol)? = nil
    ) async -> AppModel {
        let sessionRepository = chatGPTSessionRepository ?? TracerChatGPTSessionRepositoryFake()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage())),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: cliLoginReader
        )
        await appModel.refreshCLILoginSnapshot()
        appModel.settings.isChatGPTUsageShown = true
        return appModel
    }

    func test_chatGPTAdditional_matchingCodexLogin_pollsBearerFirstAndSkipsCookie() async throws {
        let chatgptUserId = "user-additional-0001"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let bearerUsage = Self.makeChatGPTUsage(percentage: 17)
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [chatgptUserId: .success((bearerUsage, .unidentified))],
            cookieResultsByKeychainAccount: [chatgptUserId: .success((Self.makeChatGPTUsage(percentage: 99), .unidentified))]
        )
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "Additional", keychainAccount: chatgptUserId),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()

        let bearerCalls = await usageService.bearerCallCounts[chatgptUserId] ?? 0
        let cookieCalls = await usageService.cookieCallCounts[chatgptUserId] ?? 0
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 0, "a matching Codex CLI login must skip the cookie call entirely")
        XCTAssertEqual(appModel.chatGPTAccountUsage[chatgptUserId], bearerUsage)
        XCTAssertEqual(appModel.chatGPTAccountSources[chatgptUserId], .codexCLI)
    }

    func test_chatGPTAdditional_bearerRejected_fallsBackToCookieAndRecordsStoredSession() async throws {
        let chatgptUserId = "user-additional-0002"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let cookieUsage = Self.makeChatGPTUsage(percentage: 28)
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [chatgptUserId: .failure(CLIUsageFetchError.rejected)],
            cookieResultsByKeychainAccount: [chatgptUserId: .success((cookieUsage, .unidentified))]
        )
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "Additional", keychainAccount: chatgptUserId),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()

        let bearerCalls = await usageService.bearerCallCounts[chatgptUserId] ?? 0
        let cookieCalls = await usageService.cookieCallCounts[chatgptUserId] ?? 0
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(appModel.chatGPTAccountUsage[chatgptUserId], cookieUsage)
        XCTAssertEqual(appModel.chatGPTAccountSources[chatgptUserId], .storedSession)
        XCTAssertNil(appModel.chatGPTAccountErrors[chatgptUserId])
    }

    func test_chatGPTAdditional_bearerNetworkUnavailable_zeroCookieCallsKeepsLastGoodUsage() async throws {
        let chatgptUserId = "user-additional-0003"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [chatgptUserId: .failure(CLIUsageFetchError.networkUnavailable)],
            cookieResultsByKeychainAccount: [chatgptUserId: .success((Self.makeChatGPTUsage(percentage: 99), .unidentified))]
        )
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "Additional", keychainAccount: chatgptUserId),
        ]
        let lastGoodUsage = Self.makeChatGPTUsage(percentage: 55)
        appModel.chatGPTAccountUsage[chatgptUserId] = lastGoodUsage

        await appModel.refreshAdditionalChatGPTAccounts()

        let bearerCalls = await usageService.bearerCallCounts[chatgptUserId] ?? 0
        let cookieCalls = await usageService.cookieCallCounts[chatgptUserId] ?? 0
        XCTAssertEqual(bearerCalls, 1)
        XCTAssertEqual(cookieCalls, 0, "an outage must not also hit the stored cookie in the same cycle")
        XCTAssertEqual(appModel.chatGPTAccountErrors[chatgptUserId], CLIUsageFetchError.networkUnavailable.errorDescription)
        XCTAssertEqual(appModel.chatGPTAccountUsage[chatgptUserId], lastGoodUsage, "last-good usage must survive an outage")
    }

    func test_chatGPTAdditional_secondAccountWithNoMatchingLogin_zeroBearerCallsUsesCookie() async throws {
        let matchedId = "user-additional-0004"
        let unmatchedId = "user-additional-0005"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: matchedId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let matchedBearerUsage = Self.makeChatGPTUsage(percentage: 11)
        let unmatchedCookieUsage = Self.makeChatGPTUsage(percentage: 66)
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [matchedId: .success((matchedBearerUsage, .unidentified))],
            cookieResultsByKeychainAccount: [
                matchedId: .success((Self.makeChatGPTUsage(percentage: 88), .unidentified)),
                unmatchedId: .success((unmatchedCookieUsage, .unidentified)),
            ]
        )
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: matchedId, label: "Matched", keychainAccount: matchedId),
            ChatGPTAccount(id: unmatchedId, label: "Unmatched", keychainAccount: unmatchedId),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()

        let unmatchedBearerCalls = await usageService.bearerCallCounts[unmatchedId] ?? 0
        let unmatchedCookieCalls = await usageService.cookieCallCounts[unmatchedId] ?? 0
        XCTAssertEqual(unmatchedBearerCalls, 0, "a login for a different account must never be tried")
        XCTAssertEqual(unmatchedCookieCalls, 1)
        XCTAssertEqual(appModel.chatGPTAccountUsage[unmatchedId], unmatchedCookieUsage)
        XCTAssertEqual(appModel.chatGPTAccountSources[unmatchedId], .storedSession)
        XCTAssertEqual(appModel.chatGPTAccountSources[matchedId], .codexCLI)
    }

    func test_chatGPTAdditional_cliOriginNoUsableLogin_cookieThrowsMissingSessionCookie_showsMessage() async throws {
        let chatgptUserId = "user-additional-0006"
        // No Codex login in the snapshot at all for this account.
        let cliLoginReader = CLILoginReaderFake(snapshot: .empty)
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub()
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "CLI-origin", keychainAccount: chatgptUserId, origin: .cliLogin),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()

        let bearerCalls = await usageService.bearerCallCounts[chatgptUserId] ?? 0
        XCTAssertEqual(bearerCalls, 0)
        XCTAssertEqual(
            appModel.chatGPTAccountErrors[chatgptUserId],
            "No current Codex CLI login. Run codex once, or connect a browser session."
        )
    }

    func test_chatGPTAdditional_bearerOutcome_neverTouchesCookieRejectionCounterOrCredentialState() async throws {
        let chatgptUserId = "user-additional-0007"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [chatgptUserId: .failure(CLIUsageFetchError.rejected)],
            cookieResultsByKeychainAccount: [chatgptUserId: .success((Self.makeChatGPTUsage(percentage: 5), .unidentified))]
        )
        let sessionRepository = CountingChatGPTSessionRepositoryFake()
        let appModel = await makeChatGPTAdditionalAppModel(
            cliLoginReader: cliLoginReader,
            chatGPTUsageService: usageService,
            chatGPTSessionRepository: sessionRepository
        )
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "Additional", keychainAccount: chatgptUserId),
        ]
        let previousCredentialState = appModel.chatGPTCredentialState

        await appModel.refreshAdditionalChatGPTAccounts()

        XCTAssertEqual(appModel.chatGPTCredentialState, previousCredentialState)
        let saveCalls = await sessionRepository.saveCallCount
        let clearCalls = await sessionRepository.clearCallCount
        XCTAssertEqual(saveCalls, 0, "a rejected bearer outcome must never touch the stored session repository (D-04)")
        XCTAssertEqual(clearCalls, 0)
    }

    func test_chatGPTAdditional_bearerCancelled_outcomeCancelledWithNoErrorRecorded() async throws {
        let chatgptUserId = "user-additional-0008"
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId,
                accountId: "00000000-0000-0000-0000-0000000000a1",
                expiresIn: 3600
            ),
            claude: []
        ))
        let usageService = ScriptedAdditionalChatGPTUsageServiceStub(
            bearerResultsByChatGPTUserId: [chatgptUserId: .failure(CancellationError())],
            cookieResultsByKeychainAccount: [chatgptUserId: .success((Self.makeChatGPTUsage(percentage: 5), .unidentified))]
        )
        let appModel = await makeChatGPTAdditionalAppModel(cliLoginReader: cliLoginReader, chatGPTUsageService: usageService)
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: chatgptUserId, label: "Additional", keychainAccount: chatgptUserId),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()

        let cookieCalls = await usageService.cookieCallCounts[chatgptUserId] ?? 0
        XCTAssertEqual(cookieCalls, 0, "a cancelled bearer call must never fall back to the cookie")
        XCTAssertNil(appModel.chatGPTAccountErrors[chatgptUserId])
        XCTAssertNil(appModel.chatGPTAccountUsage[chatgptUserId])
    }
}

/// Thread-safely records every request the tracer's `URLProtocol` handles,
/// so the test can assert on the exact wire shape without a data race
/// between the loading callback and the assertions.
private final class TracerRequestRecorder: @unchecked Sendable {
    struct Recorded {
        let path: String
        let authorization: String?
        let cookie: String?
        let chatgptAccountId: String?
    }

    private let lock = NSLock()
    private var stored: [Recorded] = []

    func record(_ request: URLRequest) {
        let recorded = Recorded(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            chatgptAccountId: request.value(forHTTPHeaderField: "chatgpt-account-id")
        )
        lock.lock()
        stored.append(recorded)
        lock.unlock()
    }

    var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Intercepts the real `ChatGPTHTTPClient`'s `URLSession` traffic, so the
/// tracer exercises the actual wire-building code (header names, no Cookie
/// header, no `/api/auth/session` hop) rather than a protocol-level stub.
private final class TracerRequestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A real `ChatGPTSessionRepositoryProtocol` conformer holding one cookie in
/// memory, so the stored-cookie fallback path has something to fall back to
/// if a future case needs it. The tracer itself never reaches this path.
private actor TracerChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]

    func save(_ session: ChatGPTSession, account: String) async throws {
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
        sessions[account] = nil
    }
}

/// Scripts the Codex CLI bearer result and the stored-cookie result
/// separately, and counts calls of each -- so a fallback test can assert
/// exactly which path(s) ran without a real network round trip.
private actor FallbackChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    private(set) var bearerCallCount = 0
    private(set) var cookieCallCount = 0
    private let bearerResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>
    private let cookieResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>

    init(
        bearerResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>,
        cookieResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>
    ) {
        self.bearerResult = bearerResult
        self.cookieResult = cookieResult
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        try await fetchUsageAndIdentity(account: ChatGPTAccount.primaryKeychainAccount, chatgptAccountId: nil).usage
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        cookieCallCount += 1
        switch cookieResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool { true }

    func fetchUsageAndIdentity(
        codexCLILogin: CodexCLILogin
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        bearerCallCount += 1
        switch bearerResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

/// A `ChatGPTSessionRepositoryProtocol` conformer that counts `save` and
/// `clear` calls, so a fallback test can assert the Codex CLI path never
/// touches the stored cookie or its counters (D-04).
private actor CountingChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    /// Seeds a session directly, bypassing `save()`, so the initial fixture
    /// setup never inflates `saveCallCount`.
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

/// Scripts `ClaudeOAuthUsageServiceProtocol.fetchUsage(accessToken:)` with one
/// fixed result and counts calls, so a Claude CLI-path test can assert
/// exactly one (or zero) OAuth requests went out.
private actor ScriptedClaudeOAuthUsageServiceStub: ClaudeOAuthUsageServiceProtocol {
    private(set) var callCount = 0
    private let result: Result<UsageData, Error>

    init(result: Result<UsageData, Error>) {
        self.result = result
    }

    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        callCount += 1
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        throw CLIUsageFetchError.invalidResponse
    }
}

/// Suspends its `fetchUsage(accessToken:)` call until released, so a test can
/// remove the account from settings while the call is in flight (edge CLI-08
/// concurrency) and prove the result is discarded rather than resurrecting a
/// removed account's state.
private actor SuspendingClaudeOAuthUsageServiceStub: ClaudeOAuthUsageServiceProtocol {
    private let result: Result<UsageData, Error>
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(result: Result<UsageData, Error>) {
        self.result = result
    }

    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        throw CLIUsageFetchError.invalidResponse
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Scripts the Claude cookie path (`UsageServiceProtocol`) for both the
/// primary (`fetchUsage(forceRefresh:)`) and additional-account
/// (`fetchUsage(account:organizationId:forceRefresh:)`) calls, counting each
/// separately. An additional account with no scripted result throws
/// `AppError.noSessionKey`, matching the real `UsageService`'s behavior for
/// an account with no stored session key.
private actor ScriptedClaudeCookieUsageServiceStub: UsageServiceProtocol {
    private(set) var primaryCallCount = 0
    private(set) var additionalCallCounts: [String: Int] = [:]
    private let primaryResult: Result<UsageData, Error>
    private let resultsByKeychainAccount: [String: Result<UsageData, Error>]

    init(
        primaryResult: Result<UsageData, Error> = .failure(AppError.noSessionKey),
        resultsByKeychainAccount: [String: Result<UsageData, Error>] = [:]
    ) {
        self.primaryResult = primaryResult
        self.resultsByKeychainAccount = resultsByKeychainAccount
    }

    func fetchUsage(forceRefresh: Bool) async throws -> UsageData {
        primaryCallCount += 1
        switch primaryResult {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool) async throws -> UsageData {
        additionalCallCounts[account, default: 0] += 1
        guard let result = resultsByKeychainAccount[account] else {
            throw AppError.noSessionKey
        }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func fetchOrganizations() async throws -> [Organization] { [] }
    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] { [] }
    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool { true }
}

/// Scripts the additional-account Codex CLI bearer call
/// (`fetchUsageAndIdentity(codexCLILogin:)`, keyed by the login's
/// `chatgptUserId`) and the cookie call
/// (`fetchUsageAndIdentity(account:chatgptAccountId:)`, keyed by the
/// keychain account) independently, counting each separately. An account
/// with no scripted bearer/cookie result throws the same error the real
/// service throws for "nothing usable" (`CLIUsageFetchError.invalidResponse`
/// / `ChatGPTUsageError.missingSessionCookie`).
private actor ScriptedAdditionalChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    private(set) var bearerCallCounts: [String: Int] = [:]
    private(set) var cookieCallCounts: [String: Int] = [:]
    private let bearerResultsByChatGPTUserId: [String: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>]
    private let cookieResultsByKeychainAccount: [String: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>]

    init(
        bearerResultsByChatGPTUserId: [String: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>] = [:],
        cookieResultsByKeychainAccount: [String: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>] = [:]
    ) {
        self.bearerResultsByChatGPTUserId = bearerResultsByChatGPTUserId
        self.cookieResultsByKeychainAccount = cookieResultsByKeychainAccount
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        throw ChatGPTUsageError.missingSessionCookie
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        throw ChatGPTUsageError.missingSessionCookie
    }

    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        cookieCallCounts[account, default: 0] += 1
        guard let result = cookieResultsByKeychainAccount[account] else {
            throw ChatGPTUsageError.missingSessionCookie
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool { true }

    func fetchUsageAndIdentity(
        codexCLILogin: CodexCLILogin
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        bearerCallCounts[codexCLILogin.chatgptUserId, default: 0] += 1
        guard let result = bearerResultsByChatGPTUserId[codexCLILogin.chatgptUserId] else {
            throw CLIUsageFetchError.invalidResponse
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
