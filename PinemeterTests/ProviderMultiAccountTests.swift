//
//  ProviderMultiAccountTests.swift
//  PinemeterTests
//
//  Coverage for connecting several ChatGPT accounts and several Gemini API
//  keys: identity-based deduplication, per-account usage and errors, popover
//  sections, broker oracle rows, legacy migration, and teardown.
//

import XCTest
@testable import Pinemeter

@MainActor
final class ProviderMultiAccountTests: XCTestCase {

    // MARK: - Fixtures

    private static let cookieA = "__Secure-next-auth.session-token=cookie-account-a"
    private static let cookieB = "__Secure-next-auth.session-token=cookie-account-b"
    private static let userA = "user-aaaaaaaaaaaaaaaaaaaaaaaa"
    private static let userB = "user-bbbbbbbbbbbbbbbbbbbbbbbb"
    // Deliberately not shaped like a real Google API key: PinemeterTests/ is
    // force-pushed to the public mirror, where GitHub push protection rejects
    // credential-shaped literals even when the value is fabricated.
    private static let firstKey = "gemini-test-key-one"
    private static let secondKey = "gemini-test-key-two"
    private static let thirdKey = "gemini-test-key-three"

    private func usage(_ percent: Double, label: String = "Codex weekly") -> ChatGPTUsageData {
        ChatGPTUsageData(
            rows: [.init(
                label: label,
                usedPercent: percent,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000),
                sourceLabel: "rate_limit",
                menuBarRole: .chatGPTWeekly,
                windowSeconds: 604_800
            )],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }

    private func identity(userId: String, email: String, plan: String = "pro") -> ChatGPTAccountIdentity {
        ChatGPTAccountIdentity(userId: userId, accountId: nil, email: email, planType: plan)
    }

    private func makeAppModel(
        usageService: MultiChatGPTUsageServiceStub,
        sessionRepository: MultiChatGPTSessionRepositoryFake,
        importService: SessionKeyImportServiceStub,
        cacheRepository: ChatGPTUsageCacheRepositoryFake = ChatGPTUsageCacheRepositoryFake(),
        brokerService: (any BrokerLifecycleProtocol)? = nil
    ) -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "claude unused"))),
            chatGPTUsageService: usageService,
            chatGPTSessionRepository: sessionRepository,
            chatGPTUsageCacheRepository: cacheRepository,
            notificationService: NotificationServiceSpy(),
            sessionKeyImportService: importService,
            // No-op UI callbacks: CI runs the suite through `xctest` directly,
            // where the production modal default blocks forever in
            // `NSAlert.runModal`.
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in },
            brokerService: brokerService
        )
    }

    // MARK: - ChatGPT model

    func test_chatGPTAccount_codableRoundTripPreservesIdentityAndPrimaryFlag() throws {
        let primary = ChatGPTAccount(
            id: Self.userA,
            label: "a@example.com",
            planType: "pro",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount,
            profileLabel: "Chrome Default"
        )
        let additional = ChatGPTAccount(
            id: Self.userB,
            label: "b@example.com",
            keychainAccount: Self.userB,
            profileLabel: "Chrome Profile 2"
        )

        let decoded = try JSONDecoder().decode(
            [ChatGPTAccount].self,
            from: try JSONEncoder().encode([primary, additional])
        )

        XCTAssertEqual(decoded, [primary, additional])
        XCTAssertTrue(decoded[0].isPrimary)
        XCTAssertFalse(decoded[1].isPrimary)
    }

    func test_appSettings_decodesLegacyJSONWithoutProviderAccountLists() throws {
        let legacyJSON = """
        {
          "refresh_interval": 60,
          "notifications_enabled": true,
          "is_first_launch": false,
          "show_chatgpt_usage": true,
          "chatgpt_custom_label": "Work GPT"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)

        XCTAssertEqual(settings.chatGPTAccounts, [])
        XCTAssertEqual(settings.geminiAccounts, [])
        XCTAssertEqual(settings.chatGPTCustomLabel, "Work GPT")
    }

    // MARK: - Multi-account ChatGPT connect

    func test_connectChatGPTAccounts_connectsEveryDistinctAccountAcrossProfiles() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [
                Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com")),
                Self.cookieB: (usage(12), identity(userId: Self.userB, email: "b@example.com", plan: "plus")),
            ]
        )
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(
                result: .failure(SessionKeyImportError.noSessionKeyFound),
                allChatGPTResults: [
                    ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default"),
                    ImportedChatGPTSessionCookie(cookieHeader: Self.cookieB, sourceDescription: "Chrome Profile 2"),
                ]
            )
        )

        _ = try await appModel.importAndSaveChatGPTSessionCookie(from: .chrome)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.count, 2)
        let primary = try XCTUnwrap(appModel.settings.chatGPTAccounts.first { $0.isPrimary })
        let additional = try XCTUnwrap(appModel.settings.chatGPTAccounts.first { !$0.isPrimary })
        XCTAssertEqual(primary.id, Self.userA)
        XCTAssertEqual(primary.label, "a@example.com")
        XCTAssertEqual(primary.planType, "pro")
        XCTAssertEqual(additional.id, Self.userB)
        XCTAssertEqual(additional.keychainAccount, Self.userB)
        XCTAssertEqual(additional.planType, "plus")

        // Each account's cookie lands in its own Keychain slot.
        let savedPrimary = try await sessionRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        let savedAdditional = try await sessionRepository.load(account: Self.userB)
        XCTAssertEqual(savedPrimary.sessionCookie, Self.cookieA)
        XCTAssertEqual(savedAdditional.sessionCookie, Self.cookieB)

        XCTAssertEqual(appModel.chatGPTUsageData?.rows.first?.usedPercent, 34)
        XCTAssertEqual(appModel.chatGPTAccountUsage[Self.userB]?.rows.first?.usedPercent, 12)

        let sections = appModel.chatGPTUsageSections
        XCTAssertEqual(sections.map(\.title), ["a@example.com", "b@example.com"])
        XCTAssertTrue(sections.allSatisfy { $0.isRenameable })
    }

    func test_connectChatGPTAccounts_deduplicatesSameAccountAcrossProfiles() async throws {
        let sharedIdentity = identity(userId: Self.userA, email: "a@example.com")
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [
                Self.cookieA: (usage(34), sharedIdentity),
                Self.cookieB: (usage(34), sharedIdentity),
            ]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(
                result: .failure(SessionKeyImportError.noSessionKeyFound),
                allChatGPTResults: [
                    ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default"),
                    ImportedChatGPTSessionCookie(cookieHeader: Self.cookieB, sourceDescription: "Chrome Profile 2"),
                ]
            )
        )

        _ = try await appModel.importAndSaveChatGPTSessionCookie(from: .chrome)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.count, 1)
        XCTAssertTrue(appModel.settings.chatGPTAccounts[0].isPrimary)
        XCTAssertTrue(appModel.chatGPTAccountUsage.isEmpty)
    }

    func test_connectChatGPTAccounts_keepsPrimarySlotWithTheAccountThatAlreadyHeldIt() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [
                Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com")),
                Self.cookieB: (usage(12), identity(userId: Self.userB, email: "b@example.com")),
            ]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        // B already holds the primary slot from an earlier connect.
        appModel.settings.chatGPTAccounts = [ChatGPTAccount(
            id: Self.userB,
            label: "b@example.com",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount
        )]

        _ = try await appModel.connectChatGPTAccounts(importedCookies: [
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default"),
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieB, sourceDescription: "Chrome Profile 2"),
        ])

        let primary = try XCTUnwrap(appModel.settings.chatGPTAccounts.first { $0.isPrimary })
        XCTAssertEqual(primary.id, Self.userB, "A rescan must not repoint the legacy slot at a different account")
    }

    func test_connectChatGPTAccounts_preservesCustomLabelsAcrossRescan() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com"))]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.chatGPTAccounts = [ChatGPTAccount(
            id: Self.userA,
            label: "a@example.com",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount,
            customLabel: "Work GPT"
        )]

        _ = try await appModel.connectChatGPTAccounts(importedCookies: [
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default")
        ])

        XCTAssertEqual(appModel.settings.chatGPTAccounts.first?.customLabel, "Work GPT")
        XCTAssertEqual(appModel.chatGPTDisplayLabel, "Work GPT")
    }

    // MARK: - Per-account polling

    func test_refreshAdditionalChatGPTAccounts_keepsLastGoodUsageWhenOneAccountFails() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byAccount: [
                ChatGPTAccount.primaryKeychainAccount: .success((usage(34), identity(userId: Self.userA, email: "a@example.com"))),
                Self.userB: .success((usage(12), identity(userId: Self.userB, email: "b@example.com"))),
            ]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]

        await appModel.refreshAdditionalChatGPTAccounts()
        XCTAssertEqual(appModel.chatGPTAccountUsage[Self.userB]?.rows.first?.usedPercent, 12)

        await usageService.setAccountResult(
            Self.userB,
            .failure(ChatGPTUsageError.networkUnavailable)
        )
        await appModel.refreshAdditionalChatGPTAccounts()

        XCTAssertEqual(
            appModel.chatGPTAccountUsage[Self.userB]?.rows.first?.usedPercent,
            12,
            "A failed poll must not discard the account's last-good usage"
        )
        XCTAssertEqual(
            appModel.chatGPTAccountErrors[Self.userB],
            ChatGPTUsageError.networkUnavailable.localizedDescription
        )
    }

    func test_refreshAdditionalChatGPTAccounts_dropsStateForDisconnectedAccounts() async throws {
        let usageService = MultiChatGPTUsageServiceStub(byAccount: [:])
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.isChatGPTUsageShown = true
        appModel.chatGPTAccountUsage[Self.userB] = usage(12)
        appModel.chatGPTAccountErrors[Self.userB] = "stale"

        await appModel.refreshAdditionalChatGPTAccounts()

        XCTAssertTrue(appModel.chatGPTAccountUsage.isEmpty)
        XCTAssertTrue(appModel.chatGPTAccountErrors.isEmpty)
    }

    // MARK: - Menu bar and broker surfaces

    func test_usageQuotaBars_labelEveryConnectedChatGPTAccount() async throws {
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]
        appModel.chatGPTUsageData = usage(34)
        appModel.chatGPTAccountUsage[Self.userB] = usage(12)

        let bars = appModel.usageQuotaBars
        XCTAssertEqual(bars.map(\.owner), ["a@example.com", "b@example.com"])
        XCTAssertEqual(bars.map(\.label), ["a@example.com Codex weekly", "b@example.com Codex weekly"])
        XCTAssertEqual(bars.map(\.percentage), [34, 12])
        XCTAssertEqual(
            bars.map(\.renameTarget),
            [.chatGPTAccount(id: Self.userA), .chatGPTAccount(id: Self.userB)]
        )
    }

    func test_singleChatGPTAccount_keepsUnlabeledProviderPresentation() async throws {
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        ]
        appModel.chatGPTUsageData = usage(34)

        let bars = appModel.usageQuotaBars
        XCTAssertEqual(bars.map(\.label), ["Codex weekly"])
        XCTAssertEqual(bars.map(\.owner), ["ChatGPT"])
        XCTAssertEqual(bars.map(\.renameTarget), [.provider(.chatGPT)])
        XCTAssertEqual(appModel.chatGPTUsageSections.map(\.title), ["ChatGPT"])
    }

    func test_oracleSnapshot_carriesRowsFromEveryConnectedChatGPTAccount() async throws {
        let broker = OracleRecordingBrokerService()
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound)),
            brokerService: broker
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]
        appModel.chatGPTUsageData = usage(34)
        appModel.chatGPTAccountUsage[Self.userB] = usage(12)

        await appModel.exportAggregateUsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        let pushed = await broker.pushedOracleSnapshots
        let snapshot = try XCTUnwrap(pushed.last.flatMap { $0 })

        XCTAssertEqual(snapshot.chatGPTRows.map(\.account), [Self.userA, Self.userB])
        XCTAssertEqual(snapshot.chatGPTRows.map(\.usedPercent), [34, 12])
        // A lane needle naming an account selects only that account's rows.
        XCTAssertEqual(
            snapshot.chatGPTRows.filter { $0.matchText.lowercased().contains(Self.userB) }.count,
            1
        )
    }

    // MARK: - Scan exclusion holds across upgrade and before identity resolves

    /// A user who excluded ChatGPT on a build that predates multi-account has
    /// the exclusion keyed by the legacy Keychain slot, which no real account
    /// id can match. Reconnecting them on the next scan would silently reverse
    /// a disconnect they chose.
    func test_connectChatGPTAccounts_honoursAnExclusionRecordedBeforeMultiAccount() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com"))]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.scanExcludedAccounts = [ScanExcludedAccount(
            provider: .chatGPT,
            accountId: ChatGPTAccount.primaryKeychainAccount,
            displayLabel: "ChatGPT"
        )]

        do {
            _ = try await appModel.connectChatGPTAccounts(importedCookies: [
                ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default")
            ])
            XCTFail("Expected the excluded account to be refused")
        } catch SessionKeyImportError.allDiscoveredAccountsExcluded {
            // expected
        }

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
    }

    /// An exclusion taken against a migrated account before its first poll is
    /// keyed by the unidentified placeholder, and must hold just as firmly.
    func test_connectChatGPTAccounts_honoursAnExclusionTakenBeforeIdentityResolved() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com"))]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.scanExcludedAccounts = [ScanExcludedAccount(
            provider: .chatGPT,
            accountId: ChatGPTAccount.unidentifiedId,
            displayLabel: "ChatGPT"
        )]

        do {
            _ = try await appModel.connectChatGPTAccounts(importedCookies: [
                ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default")
            ])
            XCTFail("Expected the excluded account to be refused")
        } catch SessionKeyImportError.allDiscoveredAccountsExcluded {
            // expected
        }
        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
    }

    /// An exclusion keyed by a real account id blocks that account and only
    /// that account.
    func test_connectChatGPTAccounts_excludesOneAccountAndConnectsTheOther() async throws {
        let answerB = (usage(12), identity(userId: Self.userB, email: "b@example.com"))
        let usageService = MultiChatGPTUsageServiceStub(
            byCookie: [
                Self.cookieA: (usage(34), identity(userId: Self.userA, email: "a@example.com")),
                Self.cookieB: answerB,
            ],
            // B is the only account that connects, so B is what the primary
            // slot answers with when the post-connect refresh re-reads it.
            byAccount: [ChatGPTAccount.primaryKeychainAccount: .success(answerB)]
        )
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.scanExcludedAccounts = [ScanExcludedAccount(
            provider: .chatGPT,
            accountId: Self.userA,
            displayLabel: "a@example.com"
        )]

        _ = try await appModel.connectChatGPTAccounts(importedCookies: [
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default"),
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieB, sourceDescription: "Chrome Profile 2"),
        ])

        XCTAssertEqual(appModel.settings.chatGPTAccounts.map(\.id), [Self.userB])
    }

    // MARK: - Unvalidated-cookie fallback

    /// Connecting has never required a successful poll, so a lone cookie is
    /// still saved when validation fails. It must keep the account it belongs
    /// to rather than landing under the unidentified placeholder, which would
    /// drop the user's rename.
    func test_connectChatGPTAccounts_unvalidatedFallbackKeepsTheExistingAccountIdentity() async throws {
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byCookie: [:]),
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.chatGPTAccounts = [ChatGPTAccount(
            id: Self.userA,
            label: "a@example.com",
            planType: "pro",
            keychainAccount: ChatGPTAccount.primaryKeychainAccount,
            customLabel: "Work GPT"
        )]

        _ = try await appModel.connectChatGPTAccounts(importedCookies: [
            ImportedChatGPTSessionCookie(cookieHeader: Self.cookieA, sourceDescription: "Chrome Default")
        ])

        let account = try XCTUnwrap(appModel.settings.chatGPTAccounts.first)
        XCTAssertEqual(account.id, Self.userA)
        XCTAssertEqual(account.customLabel, "Work GPT")
        XCTAssertEqual(account.label, "a@example.com", "A failed poll must not downgrade a known label")
        XCTAssertEqual(account.planType, "pro")
    }

    /// With two accounts connected and only one cookie still discoverable, the
    /// fallback would write that cookie into the primary slot and delete the
    /// other account's, replacing one credential with another under the first
    /// account's label. It must refuse instead.
    func test_connectChatGPTAccounts_unvalidatedFallbackRefusesWhenSeveralAccountsAreConnected() async throws {
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieB), account: Self.userB)
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byCookie: [:]),
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]

        do {
            _ = try await appModel.connectChatGPTAccounts(importedCookies: [
                ImportedChatGPTSessionCookie(cookieHeader: Self.cookieB, sourceDescription: "Chrome Profile 2")
            ])
            XCTFail("Expected the ambiguous fallback to be refused")
        } catch SessionKeyImportError.invalidImportedChatGPTSessionCookie {
            // expected
        }

        XCTAssertEqual(appModel.settings.chatGPTAccounts.map(\.id), [Self.userA, Self.userB])
        let primary = try await sessionRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertEqual(primary.sessionCookie, Self.cookieA, "Account A's credential must survive untouched")
        let additional = try await sessionRepository.load(account: Self.userB)
        XCTAssertEqual(additional.sessionCookie, Self.cookieB)
    }

    // MARK: - Broker surface carries no provider-reported email

    func test_oracleSnapshot_usesANonPIIAccountKey() async throws {
        let broker = OracleRecordingBrokerService()
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: MultiChatGPTSessionRepositoryFake(),
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound)),
            brokerService: broker
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB, customLabel: "Side"),
        ]
        appModel.chatGPTUsageData = usage(34)
        appModel.chatGPTAccountUsage[Self.userB] = usage(12)

        await appModel.exportAggregateUsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        let pushed = await broker.pushedOracleSnapshots
        let snapshot = try XCTUnwrap(pushed.last.flatMap { $0 })

        // The oracle block is served over the loopback MCP port and written to
        // the audit log, so the account email must never appear there.
        XCTAssertEqual(snapshot.chatGPTRows.map(\.account), [Self.userA, "Side"])
        XCTAssertFalse(
            snapshot.chatGPTRows.contains { $0.account?.contains("@") == true },
            "No provider-reported email may reach the broker oracle"
        )
        // The popover keeps showing the email, which is how accounts are told apart.
        XCTAssertEqual(appModel.chatGPTUsageSections.map(\.title), ["a@example.com", "Side"])
    }

    // MARK: - Legacy migration and teardown

    func test_applyChatGPTIdentity_fillsInRealIdForMigratedLegacyAccount() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byAccount: [
                ChatGPTAccount.primaryKeychainAccount: .success((
                    usage(34),
                    identity(userId: Self.userA, email: "a@example.com")
                ))
            ]
        )
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [.legacyPrimary(customLabel: "Work GPT")]

        await appModel.refreshChatGPTUsage()

        let migrated = try XCTUnwrap(appModel.settings.chatGPTAccounts.first)
        XCTAssertEqual(migrated.id, Self.userA)
        XCTAssertEqual(migrated.label, "a@example.com")
        XCTAssertEqual(migrated.customLabel, "Work GPT", "A rename survives the identity being filled in")
        XCTAssertTrue(migrated.isPrimary)
    }

    func test_removeChatGPTAccount_promotesAnotherAccountIntoThePrimarySlot() async throws {
        let usageService = MultiChatGPTUsageServiceStub(
            byAccount: [
                ChatGPTAccount.primaryKeychainAccount: .success((usage(12), identity(userId: Self.userB, email: "b@example.com")))
            ]
        )
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieB), account: Self.userB)
        let appModel = makeAppModel(
            usageService: usageService,
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]

        try await appModel.removeChatGPTAccount(id: Self.userA)

        XCTAssertEqual(appModel.settings.chatGPTAccounts.map(\.id), [Self.userB])
        XCTAssertTrue(appModel.settings.chatGPTAccounts[0].isPrimary)
        let promoted = try await sessionRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertEqual(promoted.sessionCookie, Self.cookieB)
        let clearedSlots = await sessionRepository.storedAccounts
        XCTAssertFalse(clearedSlots.contains(Self.userB), "The promoted account's old slot is released")
    }

    func test_removeLastChatGPTAccount_clearsTheProviderEntirely() async throws {
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound))
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount)
        ]

        try await appModel.removeChatGPTAccount(id: Self.userA)

        XCTAssertTrue(appModel.settings.chatGPTAccounts.isEmpty)
        XCTAssertFalse(appModel.hasChatGPTSessionCookie)
        XCTAssertFalse(appModel.settings.isChatGPTUsageShown)
        let remaining = await sessionRepository.storedAccounts
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Gemini multi-key

    func test_addGeminiAPIKey_connectsSecondKeyAlongsideTheFirst() async throws {
        let keyRepository = MultiGeminiAPIKeyRepositoryFake()
        let usageService = MultiGeminiUsageServiceStub(
            byAccount: [
                GeminiAccount.primaryKeychainAccount: geminiUsage(10),
            ]
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "claude unused"))),
            geminiUsageService: usageService,
            geminiAPIKeyRepository: keyRepository,
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in }
        )

        let firstConnected = try await appModel.addGeminiAPIKey(Self.firstKey)
        let secondConnected = try await appModel.addGeminiAPIKey(
            Self.secondKey,
            label: "Side project"
        )
        XCTAssertTrue(firstConnected)
        XCTAssertTrue(secondConnected)

        XCTAssertEqual(appModel.settings.geminiAccounts.count, 2)
        let primary = try XCTUnwrap(appModel.settings.geminiAccounts.first { $0.isPrimary })
        let additional = try XCTUnwrap(appModel.settings.geminiAccounts.first { !$0.isPrimary })
        XCTAssertEqual(additional.displayLabel, "Side project")
        XCTAssertNotEqual(primary.keychainAccount, additional.keychainAccount)

        let storedAdditional = try await keyRepository.load(account: additional.keychainAccount)
        XCTAssertEqual(storedAdditional.value, Self.secondKey)
        XCTAssertEqual(appModel.geminiUsageSections.map(\.title), ["Gemini", "Side project"])
    }

    func test_addGeminiAPIKey_rejectsAKeyThatIsAlreadyConnected() async throws {
        let keyRepository = MultiGeminiAPIKeyRepositoryFake()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "claude unused"))),
            geminiUsageService: MultiGeminiUsageServiceStub(byAccount: [:]),
            geminiAPIKeyRepository: keyRepository,
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in }
        )

        let firstConnected = try await appModel.addGeminiAPIKey(Self.firstKey)
        let duplicateConnected = try await appModel.addGeminiAPIKey(Self.firstKey)
        XCTAssertTrue(firstConnected)
        XCTAssertFalse(duplicateConnected, "The same key must not connect twice")
        XCTAssertEqual(appModel.settings.geminiAccounts.count, 1)
    }

    func test_removeGeminiAccount_promotesAnotherKeyIntoThePrimarySlot() async throws {
        let keyRepository = MultiGeminiAPIKeyRepositoryFake()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "claude unused"))),
            geminiUsageService: MultiGeminiUsageServiceStub(byAccount: [:]),
            geminiAPIKeyRepository: keyRepository,
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in }
        )
        _ = try await appModel.addGeminiAPIKey(Self.firstKey)
        _ = try await appModel.addGeminiAPIKey(Self.secondKey, label: "Side project")
        let primaryId = try XCTUnwrap(appModel.settings.geminiAccounts.first { $0.isPrimary }?.id)

        try await appModel.removeGeminiAccount(id: primaryId)

        XCTAssertEqual(appModel.settings.geminiAccounts.count, 1)
        XCTAssertTrue(appModel.settings.geminiAccounts[0].isPrimary)
        XCTAssertEqual(appModel.settings.geminiAccounts[0].displayLabel, "Side project")
        let promoted = try await keyRepository.load(account: GeminiAccount.primaryKeychainAccount)
        XCTAssertEqual(promoted.value, Self.secondKey)
    }

    /// `GeminiUsageService` purges a key the provider rejects, while its
    /// settings entry survives. Taking that entry as the successor and failing
    /// to load it used to fall through to `clearGeminiAPIKey()`, which deletes
    /// every remaining key: removing one key destroyed an unrelated one.
    func test_removeGeminiAccount_skipsASuccessorWhoseKeyWasAlreadyPurged() async throws {
        let keyRepository = MultiGeminiAPIKeyRepositoryFake()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "claude unused"))),
            geminiUsageService: MultiGeminiUsageServiceStub(byAccount: [:]),
            geminiAPIKeyRepository: keyRepository,
            notificationService: NotificationServiceSpy(),
            runningBrowserSources: { [] },
            browserLoginPrompt: { _ in }
        )
        _ = try await appModel.addGeminiAPIKey(Self.firstKey)
        _ = try await appModel.addGeminiAPIKey(Self.secondKey, label: "Revoked")
        _ = try await appModel.addGeminiAPIKey(Self.thirdKey, label: "Still good")

        let primaryId = try XCTUnwrap(appModel.settings.geminiAccounts.first { $0.isPrimary }?.id)
        let revoked = try XCTUnwrap(appModel.settings.geminiAccounts.first { $0.displayLabel == "Revoked" })
        let stillGood = try XCTUnwrap(appModel.settings.geminiAccounts.first { $0.displayLabel == "Still good" })
        // The provider rejected the second key, so the service purged it while
        // its settings entry stayed behind.
        try await keyRepository.clear(account: revoked.keychainAccount)

        try await appModel.removeGeminiAccount(id: primaryId)

        XCTAssertEqual(
            appModel.settings.geminiAccounts.first { $0.isPrimary }?.id,
            stillGood.id,
            "Promotion must skip the key that no longer loads"
        )
        let promoted = try await keyRepository.load(account: GeminiAccount.primaryKeychainAccount)
        XCTAssertEqual(promoted.value, Self.thirdKey, "The unrelated key must survive")
        XCTAssertTrue(
            appModel.settings.geminiAccounts.contains { $0.id == revoked.id },
            "The purged entry stays listed so the user can see and remove it"
        )
    }

    /// The primary cache file still holds the REMOVED account's rows after a
    /// promotion. The refresh only rewrites it on a successful poll, so
    /// removing an account while offline left the next launch showing one
    /// account's quota under another account's label.
    func test_removeChatGPTAccount_doesNotLeaveTheRemovedAccountsUsageInThePrimaryCache() async throws {
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieB), account: Self.userB)
        let cacheRepository = ChatGPTUsageCacheRepositoryFake()
        // The removed account's rows, as the last successful poll left them.
        await cacheRepository.save(usage(99), account: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            // Every poll fails, standing in for being offline during removal.
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound)),
            cacheRepository: cacheRepository
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]
        appModel.chatGPTUsageData = usage(99)
        appModel.chatGPTAccountUsage[Self.userB] = usage(12)

        try await appModel.removeChatGPTAccount(id: Self.userA)

        let persisted = await cacheRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertEqual(
            persisted?.rows.first?.usedPercent,
            12,
            "The primary cache must hold the promoted account's usage, not the removed account's"
        )
    }

    /// Same hazard with nothing to promote in its place: the removed account's
    /// rows must not survive on disk at all.
    func test_removeChatGPTAccount_clearsThePrimaryCacheWhenTheSuccessorHasNoUsageYet() async throws {
        let sessionRepository = MultiChatGPTSessionRepositoryFake()
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieA), account: ChatGPTAccount.primaryKeychainAccount)
        try await sessionRepository.save(ChatGPTSession(sessionCookie: Self.cookieB), account: Self.userB)
        let cacheRepository = ChatGPTUsageCacheRepositoryFake()
        await cacheRepository.save(usage(99), account: ChatGPTAccount.primaryKeychainAccount)
        let appModel = makeAppModel(
            usageService: MultiChatGPTUsageServiceStub(byAccount: [:]),
            sessionRepository: sessionRepository,
            importService: SessionKeyImportServiceStub(result: .failure(SessionKeyImportError.noSessionKeyFound)),
            cacheRepository: cacheRepository
        )
        appModel.hasChatGPTSessionCookie = true
        appModel.settings.isChatGPTUsageShown = true
        appModel.settings.chatGPTAccounts = [
            ChatGPTAccount(id: Self.userA, label: "a@example.com", keychainAccount: ChatGPTAccount.primaryKeychainAccount),
            ChatGPTAccount(id: Self.userB, label: "b@example.com", keychainAccount: Self.userB),
        ]
        appModel.chatGPTUsageData = usage(99)

        try await appModel.removeChatGPTAccount(id: Self.userA)

        let persisted = await cacheRepository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertNil(persisted, "A disconnected account's usage must not stay on disk")
        XCTAssertNil(appModel.chatGPTUsageData)
    }

    private func geminiUsage(_ percent: Double) -> GeminiUsageData {
        GeminiUsageData(
            label: "Gemini API quota",
            usedPercent: percent,
            resetAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )
    }
}

// MARK: - Test doubles

/// A ChatGPT usage service that answers per cookie and per Keychain account, so
/// a test can tell two connected accounts apart.
private actor MultiChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    typealias Answer = (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity)

    private var byCookie: [String: Answer]
    private var byAccount: [String: Result<Answer, Error>]

    init(byCookie: [String: Answer] = [:], byAccount: [String: Result<Answer, Error>] = [:]) {
        self.byCookie = byCookie
        self.byAccount = byAccount
        // Connecting saves a cookie into a slot and then polls that slot, so a
        // cookie-keyed stub answers account lookups through the same data.
        if byAccount.isEmpty, !byCookie.isEmpty {
            let sorted = byCookie.sorted { $0.key < $1.key }
            self.byAccount[ChatGPTAccount.primaryKeychainAccount] = .success(sorted[0].value)
            for entry in sorted.dropFirst() {
                if let id = entry.value.identity.stableId {
                    self.byAccount[id] = .success(entry.value)
                }
            }
        }
    }

    func setAccountResult(_ account: String, _ result: Result<Answer, Error>) {
        byAccount[account] = result
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        try await fetchUsage(account: ChatGPTAccount.primaryKeychainAccount)
    }

    func fetchUsage(account: String) async throws -> ChatGPTUsageData {
        try await fetchUsageAndIdentity(account: account).usage
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try await fetchUsageAndIdentity(sessionCookie: sessionCookie).usage
    }

    func fetchUsageAndIdentity(account: String) async throws -> Answer {
        guard let result = byAccount[account] else { throw ChatGPTUsageError.missingSessionCookie }
        return try result.get()
    }

    func fetchUsageAndIdentity(sessionCookie: String) async throws -> Answer {
        guard let answer = byCookie[sessionCookie] else { throw ChatGPTUsageError.invalidSessionCookie }
        return answer
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        byCookie[sessionCookie] != nil
    }
}

private actor MultiChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]

    var storedAccounts: Set<String> { Set(sessions.keys) }

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

private actor MultiGeminiAPIKeyRepositoryFake: GeminiAPIKeyRepositoryProtocol {
    private var keys: [String: GeminiAPIKey] = [:]

    func save(_ apiKey: GeminiAPIKey, account: String) async throws {
        keys[account] = apiKey
    }

    func load(account: String) async throws -> GeminiAPIKey {
        guard let key = keys[account] else { throw GeminiAPIKeyRepositoryError.notFound }
        return key
    }

    func validate(account: String) async -> GeminiAPIKeyAcquisitionStatus {
        keys[account] == nil
            ? GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            : GeminiAPIKeyAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func clear(account: String) async throws {
        keys[account] = nil
    }
}

private actor MultiGeminiUsageServiceStub: GeminiUsageServiceProtocol {
    private let byAccount: [String: GeminiUsageData]

    init(byAccount: [String: GeminiUsageData]) {
        self.byAccount = byAccount
    }

    func fetchUsage() async throws -> GeminiUsageData {
        try await fetchUsage(account: GeminiAccount.primaryKeychainAccount)
    }

    func fetchUsage(account: String) async throws -> GeminiUsageData {
        guard let usage = byAccount[account] else { throw GeminiUsageError.quotaUnavailable }
        return usage
    }

    func fetchUsage(apiKey: GeminiAPIKey) async throws -> GeminiUsageData {
        throw GeminiUsageError.quotaUnavailable
    }

    func validateAPIKey(_ apiKey: GeminiAPIKey) async throws -> Bool {
        true
    }
}

/// Records what `AppModel` pushes into the broker. Only the oracle push is
/// modeled; every other lifecycle call is a no-op.
private actor OracleRecordingBrokerService: BrokerLifecycleProtocol {
    private(set) var pushedOracleSnapshots: [OracleSnapshot?] = []

    func updatePolicy(_ policy: BrokerPolicy) async {}
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async { pushedOracleSnapshots.append(oracle) }
    func updateT3Liveness(_ liveness: [String: T3Liveness]) async {}
    func updateServerState(_ state: BrokerUIState.ServerState) async {}
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) async {}
    func uiStateUpdates() async -> AsyncStream<BrokerUIState> { AsyncStream { $0.finish() } }

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        throw BrokerError.configError("unused")
    }

    func pick(role: String, caller: String?, overrideCandidate: String) async throws -> BrokerDecision {
        throw BrokerError.configError("unused")
    }

    func status() async -> BrokerStatus {
        BrokerStatus(
            running: false,
            port: nil,
            oracle: BrokerStatus.OracleFreshness(present: false, stale: false, ageSeconds: nil, accounts: []),
            cooldowns: [],
            t3: [],
            roles: [],
            recentPicksCount: 0
        )
    }
    func down(target: String, minutes: Int?) async throws {}
    func up(target: String) async throws {}
    func refresh() async throws {}
}
