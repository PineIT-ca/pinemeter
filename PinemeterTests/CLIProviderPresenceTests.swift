//
//  CLIProviderPresenceTests.swift
//  PinemeterTests
//
//  Phase 19 plan 07: a CLI-origin account (Claude Code or Codex CLI) counts
//  as a fully connected account everywhere AppModel previously assumed a
//  stored Pinemeter credential -- the popover, the refresh loop, the "Show
//  ChatGPT usage" toggle, the broker oracle, the provider credential status,
//  and browser recovery. Every token, cookie, and account id below is
//  synthetic -- no real Keychain, file, or network access happens in this
//  file.
//

import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class CLIProviderPresenceTests: XCTestCase {
    // MARK: - Fixtures

    private static let orgA = UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!
    private static let orgB = UUID(uuidString: "00000000-0000-0000-0000-0000000000e2")!
    private static let chatgptUserIdA = "user-synthetic-2001"

    private func makeAppModel(
        cliLoginReader: CLILoginReaderFake = CLILoginReaderFake(),
        claudeAccounts: [ClaudeAccount] = [],
        chatGPTAccounts: [ChatGPTAccount] = [],
        isSetupComplete: Bool = false,
        hasChatGPTSessionCookie: Bool = false,
        isChatGPTUsageShown: Bool = false,
        claudeOAuthUsageService: any ClaudeOAuthUsageServiceProtocol = PresenceClaudeOAuthUsageServiceStub(),
        chatGPTUsageService: any ChatGPTUsageServiceProtocol = PresenceChatGPTUsageServiceStub(),
        usageService: UsageServiceStub = UsageServiceStub(fetchUsageResult: .failure(PresenceStubError.notConfigured)),
        keychainRepository: KeychainRepositoryFake = KeychainRepositoryFake(),
        chatGPTSessionRepository: ReconciliationChatGPTSessionRepositoryFake = ReconciliationChatGPTSessionRepositoryFake(),
        runningBrowserSources: @escaping () -> [BrowserImportSource] = { [] },
        browserLoginPrompt: @escaping ([CredentialProvider]) -> Void = { _ in }
    ) -> AppModel {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychainRepository,
            usageService: usageService,
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: runningBrowserSources,
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: browserLoginPrompt,
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: claudeOAuthUsageService
        )
        appModel.settings.claudeAccounts = claudeAccounts
        appModel.settings.chatGPTAccounts = chatGPTAccounts
        appModel.settings.isChatGPTUsageShown = isChatGPTUsageShown
        appModel.isSetupComplete = isSetupComplete
        appModel.hasChatGPTSessionCookie = hasChatGPTSessionCookie
        return appModel
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
            rows: [.init(label: "Codex Tasks", usedPercent: percentage, resetAt: Date().addingTimeInterval(3600))],
            lastUpdated: Date()
        )
    }

    private static func makeCLIOriginClaudeAccount(organizationId: UUID) -> ClaudeAccount {
        ClaudeAccount(
            id: organizationId.uuidString.lowercased(),
            label: "Claude",
            organizationId: organizationId,
            keychainAccount: organizationId.uuidString.lowercased(),
            origin: .cliLogin
        )
    }

    private static func makeCLIOriginChatGPTAccount(id: String) -> ChatGPTAccount {
        ChatGPTAccount(id: id, label: "ChatGPT", keychainAccount: id, origin: .cliLogin)
    }

    // MARK: - Task 1: CLI-origin accounts count as connected (CLI-08)

    func test_cliOnlyClaudeAccount_countsAsConnected_popoverShowsSection() async throws {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccount],
            claudeOAuthUsageService: PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage()))
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.hasConfiguredUsageProvider)
        XCTAssertEqual(appModel.configuredUsageProviderNames, ["Claude"])
        XCTAssertEqual(appModel.claudeUsageSections.count, 1)
        XCTAssertNotNil(appModel.claudeUsageSections.first?.usageData)
    }

    func test_cliOnlyChatGPTAccount_bearerSuccess_countsAsConnected() async throws {
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f1",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let chatGPTStub = PresenceChatGPTUsageServiceStub(bearerResult: .success((Self.makeChatGPTUsage(), .unidentified)))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            chatGPTAccounts: [cliAccount],
            isChatGPTUsageShown: true,
            chatGPTUsageService: chatGPTStub
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.isChatGPTUsageConfigured)
        XCTAssertFalse(appModel.chatGPTUsageSections.isEmpty)
        XCTAssertTrue(appModel.canShowChatGPTUsage)
    }

    func test_noAccounts_canShowChatGPTUsage_false() {
        let appModel = makeAppModel()
        XCTAssertFalse(appModel.canShowChatGPTUsage)
    }

    func test_hasCLIChatGPTSource_viaIdMatchWithoutOrigin() async {
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f3",
            expiresIn: 3600
        )
        let cookieAccount = ChatGPTAccount(id: Self.chatgptUserIdA, label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let appModel = makeAppModel(cliLoginReader: cliLoginReader, chatGPTAccounts: [cookieAccount])

        await appModel.refreshCLILoginSnapshot()

        XCTAssertFalse(cookieAccount.isCLIOrigin)
        XCTAssertTrue(appModel.hasCLIChatGPTSource)
    }

    func test_cliClaudeLoginAddedDuringRefresh_startsRefreshLoop_brokerDisabled() async {
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeOAuthUsageService: PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage()))
        )
        XCTAssertFalse(appModel.settings.broker.isEnabled)
        XCTAssertFalse(appModel.isRefreshLoopRunning)

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertTrue(appModel.isRefreshLoopRunning)
    }

    func test_bootstrap_persistedCLIOriginClaudeAccount_brokerDisabled_startsRefreshLoop() async throws {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.claudeAccounts = [cliAccount]
        try await settingsRepository.save(settings)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(PresenceStubError.notConfigured)),
            chatGPTUsageService: PresenceChatGPTUsageServiceStub(),
            chatGPTSessionRepository: ReconciliationChatGPTSessionRepositoryFake(),
            chatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            cliLoginReader: CLILoginReaderFake(),
            claudeOAuthUsageService: PresenceClaudeOAuthUsageServiceStub()
        )

        await appModel.bootstrap()

        XCTAssertFalse(appModel.settings.broker.isEnabled)
        XCTAssertTrue(appModel.isRefreshLoopRunning)
    }

    func test_oracleSnapshot_cliOnlyChatGPT_freshUsage_configuredAndFresh() async {
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let appModel = makeAppModel(chatGPTAccounts: [cliAccount], isChatGPTUsageShown: true)
        appModel.chatGPTAccountUsage[cliAccount.id] = Self.makeChatGPTUsage()

        await appModel.exportAggregateUsageSnapshot()

        let snapshot = appModel.retainedOracleSnapshotForTesting
        XCTAssertEqual(snapshot?.chatGPTConfigured, true)
        XCTAssertEqual(snapshot?.chatGPTState, .fresh)
    }

    func test_oracleSnapshot_primaryError_nonPrimaryFresh_stateStaysError() async {
        let primary = ChatGPTAccount(id: ChatGPTAccount.unidentifiedId, label: "ChatGPT", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        let nonPrimary = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let appModel = makeAppModel(
            chatGPTAccounts: [primary, nonPrimary],
            hasChatGPTSessionCookie: true,
            isChatGPTUsageShown: true
        )
        appModel.chatGPTErrorMessage = "boom"
        appModel.chatGPTAccountUsage[nonPrimary.id] = Self.makeChatGPTUsage()

        await appModel.exportAggregateUsageSnapshot()

        XCTAssertEqual(appModel.retainedOracleSnapshotForTesting?.chatGPTState, .error)
    }

    func test_claudeCLISuccess_noStoredKey_credentialStateAccessTokenValid_detailTextAndNoActions() async {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let claudeOAuthStub = PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage()))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccount],
            claudeOAuthUsageService: claudeOAuthStub
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.claudeCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)
        let status = appModel.providerCredentialStatuses.first(where: { $0.provider == .claude })
        XCTAssertEqual(status?.detailText, "Using the Claude Code login.")
        XCTAssertEqual(status?.actions.count, 0)

        // Next cycle: no CLI success and no stored key -> back to missing.
        await cliLoginReader.setSnapshot(.empty)
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertEqual(appModel.claudeCredentialState.health, .missing)
    }

    func test_chatGPTCLISuccess_noStoredCookie_credentialStateAccessTokenValid_detailTextAndNoActions() async {
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f2",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let chatGPTStub = PresenceChatGPTUsageServiceStub(bearerResult: .success((Self.makeChatGPTUsage(), .unidentified)))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            chatGPTAccounts: [cliAccount],
            isChatGPTUsageShown: true,
            chatGPTUsageService: chatGPTStub
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.chatGPTCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        let status = appModel.providerCredentialStatuses.first(where: { $0.provider == .chatGPT })
        XCTAssertEqual(status?.detailText, "Using the Codex CLI login.")
        XCTAssertEqual(status?.actions.count, 0)

        // Next cycle: no CLI success and no stored cookie -> back to missing.
        await cliLoginReader.setSnapshot(.empty)
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .missing)
    }

    /// Two overlapping `refreshConfiguredUsageProviders` calls on the same
    /// model (e.g. a manual "Refresh now" firing while the scheduled refresh
    /// loop's own cycle is still in flight) must never let one cycle's
    /// bookkeeping clear another's already-recorded CLI success. A shared
    /// `AppModel`-level set cleared at the top of every call would have let
    /// the second (overlapping) call's clear wipe the first call's success
    /// before the first call ever reached its own `applyCLICredentialStates`
    /// read -- reverting a genuinely successful CLI poll to "missing" even
    /// though a CLI poll genuinely succeeded this cycle.
    ///
    /// Two additional accounts (so cycle A's own loop produces one success
    /// and is then still in-flight on a second, gated call) isolate exactly
    /// the window the bug lived in: cycle A's CLI success for `cliAccountA`
    /// must survive cycle B's full, overlapping run even though `cliAccountB`'s
    /// own attempt (resumed after cycle B completes) ends in failure and
    /// records no success of its own.
    func test_overlappingRefreshCycles_doNotClearEachOthersCLISuccess() async {
        let cliAccountA = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cliAccountB = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgB)
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [
                CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600),
                CLILoginReaderFake.claudeLogin(organizationId: Self.orgB, expiresIn: 3600),
            ]
        ))
        let gatedStub = TwoCallGatedClaudeOAuthUsageServiceStub(firstCallResult: Self.makeClaudeUsage())
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccountA, cliAccountB],
            claudeOAuthUsageService: gatedStub
        )

        // Cycle A starts: its loop processes `cliAccountA` first (a
        // success, recording `.claude` in whatever cycle A's bookkeeping
        // is), then suspends on the SECOND call -- for `cliAccountB` --
        // while `refreshAdditionalClaudeAccounts`'s own reentrancy guard is
        // still held.
        let cycleA = Task { await appModel.refreshConfiguredUsageProviders(forceRefresh: true) }
        await gatedStub.waitUntilArrived(call: 2)

        // Cycle B: a second, fully overlapping cycle on the same model. Its
        // own `refreshAdditionalClaudeAccounts` call returns immediately
        // (the reentrancy guard is still held by cycle A), so cycle B
        // records no CLI success of its own -- but in the old shared-state
        // design, cycle B's start-of-cycle clear would still have wiped
        // cycle A's already-recorded success for `cliAccountA` out from
        // under it.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        // Resume cycle A's second call with a failure, so `cliAccountB`
        // records no success of its own -- the only way cycle A's final
        // state can show a CLI success is if `cliAccountA`'s earlier one
        // survived cycle B's overlapping run.
        await gatedStub.releaseSecondCall(with: CLIUsageFetchError.networkUnavailable)
        await cycleA.value

        XCTAssertEqual(appModel.claudeCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)
    }

    /// Re-review #1's reverse ordering: cycle A runs uncontested and its own
    /// `applyCLICredentialStates` sets Claude `.valid`/`.accessToken` FIRST.
    /// Cycle B is then the one whose own `refreshAdditionalClaudeAccounts`
    /// bounces off the reentrancy guard (as if a concurrent "Refresh now"
    /// still held it) and so records no success AND no "polled" marker of
    /// its own -- yet B's `applyCLICredentialStates` still runs, LAST,
    /// against the credential state A already set to valid.
    ///
    /// Before this fix, B's empty tracker and the now-`.accessToken` state
    /// looked exactly like "a previously CLI-backed provider found no CLI
    /// success this cycle," so B's own apply flipped Claude back to
    /// `.missing` purely because B's poll was skipped -- not because
    /// anything actually failed -- which then let
    /// `recoverBrowserSessionsIfNeeded` start an unneeded browser scan. The
    /// fix tracks which providers a run actually polled (reached past its
    /// own in-flight guard) and only resets a provider this run polled.
    ///
    /// A second, non-CLI-origin Claude account is required alongside the
    /// CLI one: `recoverBrowserSessionsIfNeeded`'s own "every account is
    /// CLI-origin, never scan" short-circuit would otherwise suppress
    /// recovery regardless of the bug, masking the very thing this test
    /// checks.
    ///
    /// Setting `isRefreshingAdditionalClaudeAccounts` directly (rather than
    /// racing two real `Task`s) pins cycle B's own claude attempt to the
    /// skipped branch deterministically, with no dependency on actual
    /// scheduling order -- `@testable import` makes the internal flag
    /// reachable from this test target.
    func test_overlappingRefreshCycles_laterCycleSkippedByGuard_doesNotClearEarlierCyclesCLISuccess() async {
        let recorder = PresenceCallRecorder()
        let cliAccountA = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cookieAccount = ClaudeAccount(
            id: Self.orgB.uuidString.lowercased(),
            label: "Claude",
            organizationId: Self.orgB,
            keychainAccount: Self.orgB.uuidString.lowercased()
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccountA, cookieAccount],
            claudeOAuthUsageService: PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage())),
            runningBrowserSources: { recorder.runningCount += 1; return [] },
            browserLoginPrompt: { _ in recorder.promptCount += 1 }
        )

        // Cycle A: runs to completion uncontested. Its CLI poll for
        // `cliAccountA` succeeds and `applyCLICredentialStates` sets Claude
        // to `.valid`/`.accessToken` before cycle A returns.
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertEqual(appModel.claudeCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)

        // Cycle B: simulates arriving while a concurrent refresh still holds
        // `refreshAdditionalClaudeAccounts`'s own reentrancy guard -- the
        // exact in-flight state a real overlapping "Refresh now" would see
        // mid-loop.
        appModel.isRefreshingAdditionalClaudeAccounts = true
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        appModel.isRefreshingAdditionalClaudeAccounts = false

        // Claude was never polled this cycle (the guard bounced it) -- its
        // credential state, set by cycle A, must survive untouched, and no
        // browser recovery may fire for it.
        XCTAssertEqual(appModel.claudeCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.claudeCredentialState.health, .valid)
        XCTAssertEqual(recorder.runningCount, 0)
        XCTAssertEqual(recorder.promptCount, 0)
    }

    func test_overlappingRefreshCycles_chatGPTSkippedByGuard_storedSessionPathKeepsCLIState() async {
        let recorder = PresenceCallRecorder()
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let cookieAccount = ChatGPTAccount(
            id: "user-synthetic-2002",
            label: "ChatGPT",
            keychainAccount: "user-synthetic-2002"
        )
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f3",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            chatGPTAccounts: [cliAccount, cookieAccount],
            isChatGPTUsageShown: true,
            chatGPTUsageService: PresenceChatGPTUsageServiceStub(
                bearerResult: .success((Self.makeChatGPTUsage(), .unidentified))
            ),
            runningBrowserSources: { recorder.runningCount += 1; return [] },
            browserLoginPrompt: { _ in recorder.promptCount += 1 }
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        XCTAssertEqual(appModel.chatGPTCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        let runningCountAfterCycleA = recorder.runningCount
        let promptCountAfterCycleA = recorder.promptCount

        // Cycle B arrives while another cycle holds the additional-account
        // guard. The primary stored-session path still runs and finds no
        // stored cookie; it must not overwrite the CLI-backed state.
        appModel.isRefreshingAdditionalChatGPTAccounts = true
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        appModel.isRefreshingAdditionalChatGPTAccounts = false

        XCTAssertEqual(appModel.chatGPTCredentialState.identity.kind, .accessToken)
        XCTAssertEqual(appModel.chatGPTCredentialState.health, .valid)
        XCTAssertEqual(recorder.runningCount, runningCountAfterCycleA)
        XCTAssertEqual(recorder.promptCount, promptCountAfterCycleA)
    }

    func test_storedClaudeCredential_cliSuccessDoesNotOverrideCredentialState() async {
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let claudeOAuthStub = PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage(percentage: 50)))
        let usageStub = UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage()))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            isSetupComplete: true,
            claudeOAuthUsageService: claudeOAuthStub,
            usageService: usageStub
        )
        appModel.settings.cachedOrganizationId = Self.orgA

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        // A stored credential (isSetupComplete) keeps driving its own state;
        // applyCLICredentialStates() must be a no-op while a stored
        // credential is present, even on a successful CLI poll this cycle.
        XCTAssertEqual(appModel.claudeCredentialState.identity.kind, .sessionKey)
    }

    func test_allClaudeAccountsCLIOrigin_missingCredential_neverScansBrowserOrPrompts() async {
        let recorder = PresenceCallRecorder()
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let appModel = makeAppModel(
            claudeAccounts: [cliAccount],
            runningBrowserSources: { recorder.runningCount += 1; return [] },
            browserLoginPrompt: { _ in recorder.promptCount += 1 }
        )
        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .missing,
            failureCategory: .missing
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(appModel.claudeCredentialState.failureCategory, .missing)
        XCTAssertEqual(recorder.runningCount, 0)
        XCTAssertEqual(recorder.promptCount, 0)
    }

    func test_allChatGPTAccountsCLIOrigin_missingCredential_neverScansBrowserOrPrompts() async {
        let recorder = PresenceCallRecorder()
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let appModel = makeAppModel(
            chatGPTAccounts: [cliAccount],
            isChatGPTUsageShown: true,
            runningBrowserSources: { recorder.runningCount += 1; return [] },
            browserLoginPrompt: { _ in recorder.promptCount += 1 }
        )
        appModel.chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .missing,
            failureCategory: .missing
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(recorder.runningCount, 0)
        XCTAssertEqual(recorder.promptCount, 0)
    }

    func test_cookieBackedClaudeAccount_missingCredential_recoveryStillRuns() async {
        let recorder = PresenceCallRecorder()
        let cookieAccount = ClaudeAccount(
            id: Self.orgB.uuidString.lowercased(),
            label: "Claude",
            organizationId: Self.orgB,
            keychainAccount: Self.orgB.uuidString.lowercased()
        )
        let appModel = makeAppModel(
            claudeAccounts: [cookieAccount],
            runningBrowserSources: { recorder.runningCount += 1; return [] },
            browserLoginPrompt: { _ in recorder.promptCount += 1 }
        )
        appModel.claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .missing,
            failureCategory: .missing
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        XCTAssertEqual(recorder.runningCount, 1)
    }

    // MARK: - Task 2: Settings source detail, CLI badge, and CLI-aware wording

    func test_isCLIBacked_claudeAccount_trueForCLIOriginAndCookieAccountWithCLIOrg_falseOtherwise() async {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cookieAccountWithCLIOrg = ClaudeAccount(
            id: "cookie-with-cli-org",
            label: "Claude",
            organizationId: Self.orgB,
            keychainAccount: "cookie-with-cli-org"
        )
        let noCLIOrgId = UUID(uuidString: "00000000-0000-0000-0000-0000000000e3")!
        let cookieAccountWithoutCLIOrg = ClaudeAccount(
            id: noCLIOrgId.uuidString.lowercased(),
            label: "Claude",
            organizationId: noCLIOrgId,
            keychainAccount: noCLIOrgId.uuidString.lowercased()
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [
                CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600),
                CLILoginReaderFake.claudeLogin(organizationId: Self.orgB, expiresIn: 3600),
            ]
        ))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccount, cookieAccountWithCLIOrg, cookieAccountWithoutCLIOrg]
        )

        await appModel.refreshCLILoginSnapshot()

        XCTAssertTrue(appModel.isCLIBacked(claudeAccountId: cliAccount.id))
        XCTAssertTrue(appModel.isCLIBacked(claudeAccountId: cookieAccountWithCLIOrg.id))
        XCTAssertFalse(appModel.isCLIBacked(claudeAccountId: cookieAccountWithoutCLIOrg.id))
        XCTAssertFalse(appModel.isCLIBacked(claudeAccountId: "unknown-id"))
    }

    func test_isCLIBacked_chatGPTAccount_trueForCLIOrigin_falseForNonMatchingCookieAccount() async {
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let cookieAccountNoMatch = ChatGPTAccount(id: "user-synthetic-nomatch", label: "ChatGPT", keychainAccount: "user-synthetic-nomatch")
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f4",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let appModel = makeAppModel(cliLoginReader: cliLoginReader, chatGPTAccounts: [cliAccount, cookieAccountNoMatch])

        await appModel.refreshCLILoginSnapshot()

        XCTAssertTrue(appModel.isCLIBacked(chatGPTAccountId: cliAccount.id))
        XCTAssertFalse(appModel.isCLIBacked(chatGPTAccountId: cookieAccountNoMatch.id))
        XCTAssertFalse(appModel.isCLIBacked(chatGPTAccountId: "unknown-id"))
    }

    func test_isCLIBacked_chatGPTAccount_trueForCookieAccountMatchingCurrentCodexLoginId() async {
        let cookieAccountMatchingLogin = ChatGPTAccount(
            id: Self.chatgptUserIdA,
            label: "ChatGPT",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount
        )
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f5",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let appModel = makeAppModel(cliLoginReader: cliLoginReader, chatGPTAccounts: [cookieAccountMatchingLogin])

        await appModel.refreshCLILoginSnapshot()

        XCTAssertFalse(cookieAccountMatchingLogin.isCLIOrigin)
        XCTAssertTrue(appModel.isCLIBacked(chatGPTAccountId: cookieAccountMatchingLogin.id))
    }

    func test_reenableFeedback_claudeExclusionWithCurrentCLILogin_mentionsCLIReconnect() async {
        let excluded = ScanExcludedAccount(provider: .claude, accountId: Self.orgA.uuidString, displayLabel: "Claude")
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let appModel = makeAppModel(cliLoginReader: cliLoginReader)

        await appModel.refreshCLILoginSnapshot()

        XCTAssertEqual(
            appModel.reenableFeedback(for: excluded),
            "Re-enabled Claude. It reconnects from its CLI login on the next refresh."
        )
    }

    func test_reenableFeedback_claudeExclusionWithoutCurrentCLILogin_mentionsScan() {
        let excluded = ScanExcludedAccount(provider: .claude, accountId: Self.orgA.uuidString, displayLabel: "Claude")
        let appModel = makeAppModel()

        XCTAssertEqual(appModel.reenableFeedback(for: excluded), "Re-enabled Claude. Scan to reconnect it.")
    }

    func test_reenableFeedback_chatGPTExclusionWithCurrentCLILogin_mentionsCLIReconnect() async {
        let excluded = ScanExcludedAccount(provider: .chatGPT, accountId: Self.chatgptUserIdA, displayLabel: "ChatGPT")
        let codexLogin = CLILoginReaderFake.codexLogin(
            chatgptUserId: Self.chatgptUserIdA,
            accountId: "00000000-0000-0000-0000-0000000000f6",
            expiresIn: 3600
        )
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(codex: codexLogin, claude: []))
        let appModel = makeAppModel(cliLoginReader: cliLoginReader)

        await appModel.refreshCLILoginSnapshot()

        XCTAssertEqual(
            appModel.reenableFeedback(for: excluded),
            "Re-enabled ChatGPT. It reconnects from its CLI login on the next refresh."
        )
    }

    func test_removalReconnectHint_claudeCLIBackedAccount_mentionsExcludedFromScans() {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let appModel = makeAppModel(claudeAccounts: [cliAccount])

        XCTAssertEqual(
            appModel.removalReconnectHint(forClaudeAccountId: cliAccount.id),
            "Pinemeter stops reading its CLI login. Re-enable it under Excluded from scans to reconnect it."
        )
    }

    func test_removalReconnectHint_claudeCookieAccount_nil() {
        let cookieAccount = ClaudeAccount(
            id: Self.orgB.uuidString.lowercased(),
            label: "Claude",
            organizationId: Self.orgB,
            keychainAccount: Self.orgB.uuidString.lowercased()
        )
        let appModel = makeAppModel(claudeAccounts: [cookieAccount])

        XCTAssertNil(appModel.removalReconnectHint(forClaudeAccountId: cookieAccount.id))
    }

    func test_removalReconnectHint_chatGPTCLIBackedAccount_mentionsExcludedFromScans() {
        let cliAccount = Self.makeCLIOriginChatGPTAccount(id: Self.chatgptUserIdA)
        let appModel = makeAppModel(chatGPTAccounts: [cliAccount])

        XCTAssertEqual(
            appModel.removalReconnectHint(forChatGPTAccountId: cliAccount.id),
            "Pinemeter stops reading its CLI login. Re-enable it under Excluded from scans to reconnect it."
        )
    }

    func test_usageSourceDetail_claudeAccount_sameStringAcrossTwoConsecutiveCyclesWithSameSource() async {
        let cliAccount = Self.makeCLIOriginClaudeAccount(organizationId: Self.orgA)
        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: nil,
            claude: [CLILoginReaderFake.claudeLogin(organizationId: Self.orgA, expiresIn: 3600)]
        ))
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [cliAccount],
            claudeOAuthUsageService: PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage()))
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        let first = appModel.usageSourceDetail(forClaudeAccountId: cliAccount.id)
        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
        let second = appModel.usageSourceDetail(forClaudeAccountId: cliAccount.id)

        XCTAssertEqual(first, "Using Claude Code login")
        XCTAssertEqual(first, second)
    }

    // MARK: - Task 3: Source-selection invariant (CLI-04)

    /// Assumption-delta invariant (plan 19-04): every connected account --
    /// cookie-backed or CLI-origin, Claude or ChatGPT -- settles each refresh
    /// cycle through exactly one of a recorded source or a recorded error,
    /// and the CLI login snapshot is read exactly once per cycle regardless
    /// of how many accounts consult it. A future change that polls an
    /// account outside source selection, or re-reads the CLI snapshot per
    /// account, fails this test.
    func test_invariant_everyAccountPollResolvesThroughSourceSelection() async throws {
        let orgC1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
        let orgC2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
        let chatgptUserId1 = "user-synthetic-0001"
        let chatgptUserId2 = "user-synthetic-0002"

        let primaryClaudeAccount = ClaudeAccount(
            id: orgC1.uuidString,
            label: "Claude",
            organizationId: orgC1,
            keychainAccount: ClaudeAccount.primaryKeychainAccount
        )
        let cliClaudeAccount = Self.makeCLIOriginClaudeAccount(organizationId: orgC2)
        let primaryChatGPTAccount = ChatGPTAccount(
            id: chatgptUserId1,
            label: "ChatGPT",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount
        )
        let cliChatGPTAccount = Self.makeCLIOriginChatGPTAccount(id: chatgptUserId2)

        let cliLoginReader = CLILoginReaderFake(snapshot: CLILoginSnapshot(
            codex: CLILoginReaderFake.codexLogin(
                chatgptUserId: chatgptUserId2,
                accountId: "00000000-0000-0000-0000-0000000000f7",
                expiresIn: 3600
            ),
            claude: [CLILoginReaderFake.claudeLogin(organizationId: orgC2, expiresIn: 3600)]
        ))
        let usageStub = UsageServiceStub(fetchUsageResult: .success(Self.makeClaudeUsage()))
        let claudeOAuthStub = PresenceClaudeOAuthUsageServiceStub(result: .success(Self.makeClaudeUsage(percentage: 20)))
        let chatGPTStub = PresenceChatGPTUsageServiceStub(
            bearerResult: .success((Self.makeChatGPTUsage(), .unidentified)),
            cookieResult: .success((Self.makeChatGPTUsage(percentage: 15), .unidentified))
        )
        let appModel = makeAppModel(
            cliLoginReader: cliLoginReader,
            claudeAccounts: [primaryClaudeAccount, cliClaudeAccount],
            chatGPTAccounts: [primaryChatGPTAccount, cliChatGPTAccount],
            isSetupComplete: true,
            hasChatGPTSessionCookie: true,
            isChatGPTUsageShown: true,
            claudeOAuthUsageService: claudeOAuthStub,
            chatGPTUsageService: chatGPTStub,
            usageService: usageStub
        )

        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)

        for account in appModel.settings.claudeAccounts {
            let hasSource = appModel.claudeAccountSources[account.id] != nil
            let hasError = account.isPrimary ? appModel.errorMessage != nil : appModel.claudeAccountErrors[account.id] != nil
            XCTAssertTrue(hasSource || hasError, "Claude account \(account.id) resolved through neither a source nor an error")
        }
        for account in appModel.settings.chatGPTAccounts {
            let hasSource = appModel.chatGPTAccountSources[account.id] != nil
            let hasError = account.isPrimary ? appModel.chatGPTErrorMessage != nil : appModel.chatGPTAccountErrors[account.id] != nil
            XCTAssertTrue(hasSource || hasError, "ChatGPT account \(account.id) resolved through neither a source nor an error")
        }

        XCTAssertEqual(appModel.claudeAccountSources[cliClaudeAccount.id], .claudeCode)
        XCTAssertEqual(appModel.chatGPTAccountSources[cliChatGPTAccount.id], .codexCLI)

        let snapshotCallCount = await cliLoginReader.snapshotCallCount
        XCTAssertEqual(snapshotCallCount, 1)
    }
}

// MARK: - Test doubles

/// Thread-confined (MainActor-only use) call counter for the
/// `runningBrowserSources`/`browserLoginPrompt` closures injected into
/// `AppModel`, so a test can assert a browser scan or login prompt never (or
/// exactly once) fired during a refresh cycle (RESEARCH Pitfall 4).
private final class PresenceCallRecorder {
    var runningCount = 0
    var promptCount = 0
}

private enum PresenceStubError: Error {
    case notConfigured
}

/// Scripts the Claude Code OAuth usage call with one fixed result and counts
/// calls. Never touches a real Keychain, file, or network socket.
private actor PresenceClaudeOAuthUsageServiceStub: ClaudeOAuthUsageServiceProtocol {
    private(set) var callCount = 0
    private let result: Result<UsageData, Error>

    init(result: Result<UsageData, Error> = .failure(PresenceStubError.notConfigured)) {
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
        throw PresenceStubError.notConfigured
    }
}

/// Resolves its FIRST `fetchUsage` call immediately with a fixed success
/// result, then suspends its SECOND call until explicitly released with a
/// chosen outcome -- so a test can deterministically let one CLI poll
/// succeed (recording a success), then pause the very next poll mid-cycle
/// and run a second, fully overlapping cycle to completion before resuming
/// it. `waitUntilArrived(call:)` only returns once that call has actually
/// been reached, so the test never races its own setup.
private actor TwoCallGatedClaudeOAuthUsageServiceStub: ClaudeOAuthUsageServiceProtocol {
    private var callCount = 0
    private var secondCallArrived = false
    private var secondCallArrivedContinuation: CheckedContinuation<Void, Never>?
    private var secondCallReleaseContinuation: CheckedContinuation<Result<UsageData, Error>, Never>?
    private let firstCallResult: UsageData

    init(firstCallResult: UsageData) {
        self.firstCallResult = firstCallResult
    }

    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        callCount += 1
        guard callCount == 1 else {
            secondCallArrived = true
            secondCallArrivedContinuation?.resume()
            secondCallArrivedContinuation = nil
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<UsageData, Error>, Never>) in
                secondCallReleaseContinuation = continuation
            }
            return try outcome.get()
        }
        return firstCallResult
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        throw PresenceStubError.notConfigured
    }

    /// Only `call: 2` is supported -- the first call never blocks.
    func waitUntilArrived(call: Int) async {
        precondition(call == 2, "only the second call blocks")
        guard !secondCallArrived else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            secondCallArrivedContinuation = continuation
        }
    }

    func releaseSecondCall(with error: Error) {
        secondCallReleaseContinuation?.resume(returning: .failure(error))
        secondCallReleaseContinuation = nil
    }
}

/// Scripts the Codex CLI bearer call (`fetchUsageAndIdentity(codexCLILogin:)`)
/// and the cookie call (`fetchUsageAndIdentity(account:chatgptAccountId:)`)
/// independently with one fixed result each, counting both. An unscripted
/// bearer call throws `CLIUsageFetchError.invalidResponse` (falls back to the
/// cookie); an unscripted cookie call throws
/// `ChatGPTUsageError.missingSessionCookie` (matches "nothing usable").
private actor PresenceChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    private(set) var bearerCallCount = 0
    private(set) var cookieCallCount = 0
    private let bearerResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>?
    private let cookieResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>?

    init(
        bearerResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>? = nil,
        cookieResult: Result<(usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity), Error>? = nil
    ) {
        self.bearerResult = bearerResult
        self.cookieResult = cookieResult
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        throw ChatGPTUsageError.missingSessionCookie
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        throw ChatGPTUsageError.missingSessionCookie
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool { true }

    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        cookieCallCount += 1
        guard let cookieResult else { throw ChatGPTUsageError.missingSessionCookie }
        switch cookieResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func fetchUsageAndIdentity(
        codexCLILogin: CodexCLILogin
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        bearerCallCount += 1
        guard let bearerResult else { throw CLIUsageFetchError.invalidResponse }
        switch bearerResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
