import XCTest
@testable import Pinemeter

final class SecurityInvariantTests: XCTestCase {
    private let forbiddenCredentialFragments = [
        "sk-ant-test-synthetic-session-key",
        "__Secure-next-auth.session-token=synthetic-cookie",
        "Cookie:",
        "Bearer synthetic-access-token",
        "access-token-synthetic-secret",
        "gemini-api-key-redaction-sentinel"
    ]

    func test_appSettingsPersistenceDoesNotEncodeCredentialMaterial() async throws {
        let suiteName = "SecurityInvariantTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        settings.refreshInterval = 300
        settings.hasNotificationsEnabled = false
        settings.isFirstLaunch = false
        settings.cachedOrganizationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        settings.isFableUsageShown = false
        settings.isChatGPTUsageShown = true
        settings.iconStyle = .dualBar
        settings.isColoredIcon = false

        let repository = SettingsRepository(userDefaults: userDefaults)
        try await repository.save(settings)

        let persistedData = try XCTUnwrap(userDefaults.data(forKey: "app_settings"))
        let persistedPayload = try XCTUnwrap(String(data: persistedData, encoding: .utf8))

        assertNoCredentialPersistenceFragments(in: persistedPayload)
    }

    func test_appSettingsCodingKeysDoNotPersistCredentialStateBoundaryFields() throws {
        let encodedSettings = try JSONEncoder().encode(AppSettings.default)
        let persistedPayload = try XCTUnwrap(String(data: encodedSettings, encoding: .utf8))

        let credentialBoundaryFragments = [
            "CredentialState",
            "CredentialIdentity",
            "CredentialHealthState",
            "ProviderCredentialStatus",
            "credential_status",
            "credential_state",
            "credential_identity",
            "failure_category",
            "checked_at",
            "session_key",
            "session_cookie",
            "access_token"
        ]

        for forbiddenFragment in credentialBoundaryFragments {
            XCTAssertFalse(
                persistedPayload.contains(forbiddenFragment),
                "AppSettings persistence must stay credential-state free: \(forbiddenFragment)"
            )
        }
    }

    func test_chatGPTAcquisitionStatusPersistenceIsSanitizedAndSeparateFromAppSettings() async throws {
        let suiteName = "SecurityInvariantTests.ChatGPTStatus.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let account = "SecurityInvariantTests.ChatGPTStatus.\(UUID().uuidString)"
        let repository = ChatGPTSessionRepository(userDefaults: userDefaults)

        try await repository.save(
            ChatGPTSession(
                sessionCookie: "__Secure-next-auth.session-token=synthetic-cookie-redaction-sentinel; cf_clearance=synthetic-cookie-redaction-sentinel",
                accessToken: "Bearer synthetic-access-token-redaction-sentinel"
            ),
            account: account
        )

        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .available)
        XCTAssertNil(status.lastErrorCategory)

        let persistedDomain = userDefaults.persistentDomain(forName: suiteName) ?? [:]
        let persistedDiagnosticPayload = String(describing: persistedDomain)
        let persistedAppSettingsPayload = userDefaults.data(forKey: "app_settings")
            .flatMap { String(data: $0, encoding: .utf8) }

        XCTAssertNil(persistedAppSettingsPayload, "ChatGPT acquisition diagnostics must not be stored inside AppSettings persistence.")
        assertNoChatGPTCredentialDisclosure(in: [String(describing: status), status.debugDescription, persistedDiagnosticPayload])

        try await repository.clear(account: account)
    }

    func test_chatGPTInvalidAcquisitionDiagnosticsPersistOnlyFailureCategory() async throws {
        let suiteName = "SecurityInvariantTests.ChatGPTInvalidStatus.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let account = "SecurityInvariantTests.ChatGPTInvalidStatus.\(UUID().uuidString)"
        let repository = ChatGPTSessionRepository(userDefaults: userDefaults)
        do {
            try await repository.save(
                ChatGPTSession(
                    sessionCookie: "   ",
                    accessToken: "Bearer synthetic-access-token-redaction-sentinel"
                ),
                account: account
            )
            XCTFail("Expected blank ChatGPT session cookie to be rejected")
        } catch ChatGPTSessionRepositoryError.invalidSessionCookie {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .invalid)
        XCTAssertEqual(status.lastErrorCategory, .invalidSessionCookie)

        let persistedDomain = userDefaults.persistentDomain(forName: suiteName) ?? [:]
        assertNoChatGPTCredentialDisclosure(in: [String(describing: status), status.debugDescription, String(describing: persistedDomain)])
    }

    func test_geminiAcquisitionStatusPersistenceIsSanitizedAndSeparateFromAppSettings() async throws {
        let suiteName = "SecurityInvariantTests.GeminiStatus.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let account = "SecurityInvariantTests.GeminiStatus.\(UUID().uuidString)"
        let repository = GeminiAPIKeyRepository(userDefaults: userDefaults)

        try await repository.save(try GeminiAPIKey("gemini-api-key-redaction-sentinel"), account: account)

        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .available)
        XCTAssertNil(status.lastErrorCategory)

        let persistedDomain = userDefaults.persistentDomain(forName: suiteName) ?? [:]
        let persistedDiagnosticPayload = String(describing: persistedDomain)
        let persistedAppSettingsPayload = userDefaults.data(forKey: "app_settings")
            .flatMap { String(data: $0, encoding: .utf8) }

        XCTAssertNil(persistedAppSettingsPayload, "Gemini acquisition diagnostics must not be stored inside AppSettings persistence.")
        assertNoCredentialDisclosure(in: [String(describing: status), status.debugDescription, persistedDiagnosticPayload])

        try await repository.clear(account: account)
    }

    func test_userFacingGeminiErrorDescriptionsDoNotDiscloseCredentialShapedFragments() {
        let errors: [LocalizedError] = [
            GeminiUsageError.missingAPIKey,
            GeminiUsageError.invalidAPIKey,
            GeminiUsageError.quotaUnavailable,
            GeminiUsageError.invalidResponse,
            GeminiUsageError.httpError(statusCode: 403),
            GeminiUsageError.networkUnavailable
        ]

        assertNoCredentialDisclosure(in: errors.map { $0.localizedDescription })
    }

    func test_aggregateQuotaSnapshotContainsOnlyNormalizedQuotaFields() throws {
        let usage = UsageData(
            sessionUsage: UsageLimit(utilization: 42, resetAt: .now),
            weeklyUsage: UsageLimit(utilization: 10, resetAt: .now),
            sonnetUsage: nil,
            lastUpdated: .now
        )
        let snapshot = AggregateQuotaSnapshot(
            generatedAt: .now,
            primaryUsage: usage,
            claudeAccounts: [ClaudeAccountQuotaSnapshot(id: "account", label: "Claude", isPrimary: true, state: .error, usage: usage)],
            chatGPT: ChatGPTQuotaSnapshot(label: "ChatGPT", state: .error, lastUpdated: nil, rows: []),
            gemini: GeminiQuotaSnapshot(label: "Gemini", state: .unavailable, quota: nil)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try XCTUnwrap(String(data: encoder.encode(snapshot), encoding: .utf8))

        for forbiddenField in ["credential", "session_key", "session_cookie", "access_token", "error_message", "error_description", "raw_response"] {
            XCTAssertFalse(payload.contains(forbiddenField), "Aggregate snapshot must not expose \(forbiddenField).")
        }
    }

    /// D-07: the broker `status` tool discloses only labels, percentages, ISO
    /// timestamps and candidate/instance ids — never keychain account names,
    /// session keys, or cookie fragments, even with a realistic ClaudeAccount
    /// label and organization-shaped id flowing through the oracle block.
    func test_brokerStatusPayload_containsOnlyWhitelistedFieldsAndNoCredentialMaterial() throws {
        let status = BrokerStatus(
            running: true,
            port: 4123,
            oracle: BrokerStatus.OracleFreshness(
                present: true,
                stale: false,
                ageSeconds: 12,
                accounts: [
                    BrokerStatus.AccountFreshness(
                        id: "org-00000000-0000-0000-0000-000000000001",
                        label: "Claude (Autimo)",
                        state: "fresh"
                    ),
                ]
            ),
            cooldowns: [
                BrokerStatus.CooldownEntry(key: "t3:claude_autimo/claude-fable-5", availableAt: .now),
            ],
            t3: [
                BrokerStatus.RouteHealth(instanceId: "claude_autimo", reachable: true, why: "http 200"),
            ],
            roles: ["planning", "execution"],
            recentPicksCount: 3
        )

        let payload = try status.jsonString()
        assertNoCredentialDisclosure(in: [payload])
    }

    /// D-07: the broker `pick` tool's decision JSON — including the full
    /// candidatesTried audit trail and reason strings — discloses only
    /// labels, percentages, ISO timestamps and candidate ids.
    func test_brokerPickDecisionPayload_containsOnlyWhitelistedFieldsAndNoCredentialMaterial() throws {
        let decision = BrokerDecision(
            role: "planning",
            caller: "claude-code",
            model: "t3:claude_autimo/claude-fable-5",
            route: .t3,
            agentModel: nil,
            invocation: .t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo"),
            reason: "t3:claude_autimo/claude-fable-5 account \"Claude (Autimo)\" weekly 42% < 85% ok",
            source: .policy,
            oracle: BrokerOracleBlock(
                present: true, stale: false, ageSeconds: 12, session: 10, weekly: 42, sonnet: nil, fable: nil
            ),
            degraded: false,
            candidatesTried: [
                BrokerCandidateTried(
                    candidate: "native/claude-fable-5",
                    available: false,
                    why: "native weekly 91% >= 85%"
                ),
                BrokerCandidateTried(
                    candidate: "t3:claude_autimo/claude-fable-5",
                    available: true,
                    why: "t3:claude_autimo/claude-fable-5 account \"Claude (Autimo)\" weekly 42% < 85% ok"
                ),
            ]
        )

        let payload = try decision.jsonString()
        assertNoCredentialDisclosure(in: [payload])
    }

    /// D-07: the hand-rolled broker HTTP parser must never log request bodies
    /// — a request line/status/method log is fine, the body variable itself
    /// (which can carry a `pick`/`down` tool call's arguments) must not be.
    func test_loopbackHTTPServerDoesNotLogRequestBodies() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/LoopbackHTTPServer.swift")

        let loggerLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("logger.") }
        for loggerLine in loggerLines {
            XCTAssertFalse(
                loggerLine.contains("body"),
                "LoopbackHTTPServer must never log a request body: \(loggerLine)"
            )
        }
    }

    func test_settingsRepositoryDoesNotReferenceCredentialStateOrCredentialMaterial() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Repositories/SettingsRepository.swift")
        let forbiddenRepositoryFragments = [
            "CredentialState",
            "ProviderCredentialStatus",
            "CredentialStatusService",
            "sessionKey",
            "sessionCookie",
            "accessToken",
            "Bearer",
            "Cookie",
            "__Secure-next-auth",
            "sk-ant-"
        ]

        for forbiddenFragment in forbiddenRepositoryFragments {
            XCTAssertFalse(
                source.contains(forbiddenFragment),
                "SettingsRepository must remain free of credential state and credential material: \(forbiddenFragment)"
            )
        }
    }

    func test_settingsViewDoesNotOfferManualCredentialEntry() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let forbiddenSettingsFragments = [
            "TextField(\"sk-ant-",
            "__Secure-next-auth.session-token",
            "chatGPTSessionTokenPart",
            "chatGPTFullCookieHeader",
            "paste your Claude session",
            "Paste a ChatGPT session cookie",
            "validateAndSaveChatGPTSessionCookie"
        ]

        for forbiddenFragment in forbiddenSettingsFragments {
            XCTAssertFalse(
                source.contains(forbiddenFragment),
                "Settings must use browser/provider credential actions instead of manual credential entry: \(forbiddenFragment)"
            )
        }

        // Cookie-scan providers (Claude/ChatGPT) stay scan-only. Gemini is the
        // sole deliberate exception: its Google AI Studio API key has no browser
        // cookie to scan, so exactly one SecureField (the Gemini key) is allowed.
        let secureFieldCount = source.components(separatedBy: "SecureField(").count - 1
        XCTAssertEqual(secureFieldCount, 1)
        XCTAssertTrue(source.contains("SecureField(\"API key\", text: $geminiAPIKeyDraft)"))
    }

    func test_setupWizardUsesOpenBrowserScan() throws {
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")
        let importSource = try sourceContents(relativePath: "Pinemeter/Services/Protocols/SessionKeyImportServiceProtocol.swift")

        XCTAssertTrue(setupSource.contains("scanOpenBrowsers"))
        XCTAssertTrue(importSource.contains("scanTargets"))
        XCTAssertTrue(importSource.contains("Chrome"))
        XCTAssertTrue(importSource.contains("Safari"))
        XCTAssertTrue(importSource.contains("Firefox"))
        XCTAssertFalse(setupSource.contains("Open Claude Sign In"))
        XCTAssertFalse(setupSource.contains("Open ChatGPT Sign In"))
        XCTAssertFalse(setupSource.contains("Import Claude from"))
        XCTAssertFalse(setupSource.contains("Import ChatGPT from"))
    }

    func test_userFacingAppErrorDescriptionsDoNotDiscloseCredentialShapedFragments() {
        let errors: [LocalizedError] = [
            AppError.noSessionKey,
            AppError.networkError(.authenticationFailed),
            AppError.networkError(.httpError(statusCode: 401)),
            AppError.networkError(.decodingFailed(underlyingError: SyntheticCredentialError())),
            AppError.keychainError(.saveFailed(OSStatus: -34018)),
            AppError.keychainError(.updateFailed(OSStatus: -50)),
            AppError.sessionKeyInvalid,
            AppError.apiResponseInvalid,
            AppError.organizationNotFound,
            AppError.cacheCorrupted
        ]

        assertNoCredentialDisclosure(in: errors.map { $0.localizedDescription })
    }

    func test_userFacingChatGPTErrorDescriptionsDoNotDiscloseCredentialShapedFragments() {
        let errors: [LocalizedError] = [
            ChatGPTUsageError.missingSessionCookie,
            ChatGPTUsageError.invalidSessionCookie,
            ChatGPTUsageError.invalidResponse,
            ChatGPTUsageError.httpError(statusCode: 403),
            ChatGPTUsageError.networkUnavailable
        ]

        assertNoCredentialDisclosure(in: errors.map { $0.localizedDescription })
    }

    func test_userFacingNetworkAndKeychainDescriptionsDoNotDiscloseCredentialShapedFragments() {
        let errors: [LocalizedError] = [
            NetworkError.invalidURL,
            NetworkError.invalidResponse,
            NetworkError.authenticationFailed,
            NetworkError.rateLimitExceeded,
            NetworkError.httpError(statusCode: 500),
            NetworkError.decodingFailed(underlyingError: SyntheticCredentialError()),
            NetworkError.networkUnavailable,
            NetworkError.timeout,
            KeychainError.saveFailed(OSStatus: -34018),
            KeychainError.notFound,
            KeychainError.updateFailed(OSStatus: -50),
            KeychainError.deleteFailed(OSStatus: -25300)
        ]

        assertNoCredentialDisclosure(in: errors.map { $0.localizedDescription })
    }

    func test_keychainServiceIdentifierIsThePineitCredentialInvariant() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Repositories/KeychainRepository.swift")

        XCTAssertTrue(
            source.contains("ca.pineit.pinemeter.sessionkey"),
            "The Keychain service identifier is a credential invariant. Renaming it orphans every stored Claude session key."
        )
        XCTAssertFalse(
            source.contains("com.claudemeter"),
            "Legacy ClaudeMeter credential identifiers were deliberately retired; do not reintroduce them."
        )
    }

    /// The Claude session key is injected as a WebView cookie on every
    /// request. A persistent data store writes that credential to disk in
    /// WebKit's cookie jar, outside the Keychain, where nothing purges it on
    /// disconnect. Keychain must remain the only at-rest home for it.
    func test_webViewSessionCookieStoreIsNonPersistent() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/WebViewNetworkService.swift")

        XCTAssertTrue(
            source.contains("WKWebsiteDataStore.nonPersistent()"),
            "The WebView must use a non-persistent data store so the injected sessionKey cookie never reaches disk."
        )
        XCTAssertFalse(
            source.contains("config.websiteDataStore = WKWebsiteDataStore.default()"),
            "Assigning the persistent default store to the WebView config writes the sessionKey cookie to disk."
        )
        XCTAssertTrue(
            source.contains("purgeLegacyPersistentSessionKeyCookie"),
            "Installs upgrading from a persistent-store build need their on-disk sessionKey cookie purged."
        )
    }

    func test_keychainAccessGroupIsThePineitCredentialInvariant() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Resources/Pinemeter.entitlements")

        XCTAssertTrue(
            source.contains("$(AppIdentifierPrefix)ca.pineit.Pinemeter"),
            "The Keychain access group is a credential invariant. Renaming it orphans every stored credential."
        )
        XCTAssertFalse(
            source.contains("com.claudemeter"),
            "Legacy ClaudeMeter access groups were deliberately retired; do not reintroduce them."
        )
    }

    func test_signedPinemeterBuildsUseDeveloperIDIdentityForClaudeKeychainRepair() throws {
        // The exact signing identity and team are pinned by the private
        // release pipeline, not by unit tests, so the public repo builds with
        // any Developer ID. This test only guards against ad-hoc defaults.
        let project = try sourceContents(relativePath: "Pinemeter.xcodeproj/project.pbxproj")

        XCTAssertTrue(
            project.contains("CODE_SIGN_STYLE = Manual;"),
            "Signed Pinemeter builds must use an explicit identity so Claude Keychain repair runs under a stable trusted app identity."
        )
        XCTAssertTrue(
            project.contains("CODE_SIGN_IDENTITY = \"Developer ID Application"),
            "Claude Keychain repair depends on re-saving credentials under a Developer ID signed app identity, not an ad-hoc or local identity."
        )
        XCTAssertFalse(
            project.contains("CODE_SIGN_IDENTITY = \"-\";"),
            "Ad-hoc signing must not be the project default for builds that exercise Claude Keychain repair."
        )
    }

    func test_claudeSessionRepairKeepsLegacyServiceIdentifierAndAvoidsAccessGroupRewrite() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Repositories/KeychainRepository.swift")
        let repairBody = try XCTUnwrap(
            source.range(of: "func repairClaudeSessionKey")
                .flatMap { startRange in
                    source.range(of: "    /// Retrieve session key from Keychain", range: startRange.lowerBound..<source.endIndex)
                        .map { endRange in String(source[startRange.lowerBound..<endRange.lowerBound]) }
                }
        )

        XCTAssertTrue(
            repairBody.contains("kSecAttrService as String: serviceName"),
            "Claude credential repair must re-save under the existing legacy service identifier so old prompt-triggering items remain repairable."
        )
        XCTAssertFalse(
            repairBody.contains("kSecAttrAccessGroup"),
            "Repair must not rewrite credentials into a new hard-coded access group; the signed app identity and entitlements should scope access."
        )
        XCTAssertFalse(
            repairBody.contains("SecItemDelete"),
            "Repair must not delete broad Keychain state while recovering from an ad-hoc-to-official signing prompt path."
        )
    }

    func test_credentialLifecycleSourcesKeepSyntheticCredentialMaterialOutOfDiagnostics() throws {
        let lifecycleSources = [
            try sourceContents(relativePath: "Pinemeter/App/AppModel.swift"),
            try sourceContents(relativePath: "Pinemeter/Services/ChatGPTUsageService.swift"),
            try sourceContents(relativePath: "Pinemeter/Repositories/KeychainRepository.swift")
        ].joined(separator: "\n")
        let syntheticCredentialFragments = [
            "synthetic-chatgpt-session-cookie",
            "sk-ant-test-session-key",
            "Bearer synthetic-access-token"
        ]

        for forbiddenFragment in syntheticCredentialFragments {
            XCTAssertFalse(
                lifecycleSources.contains(forbiddenFragment),
                "Credential lifecycle code must not bake credential-shaped test material into diagnostics: \(forbiddenFragment)"
            )
        }
    }

    func test_providerCredentialResetSourcesStayScopedToSafeRepositoryBoundaries() throws {
        let appModelSource = try sourceContents(relativePath: "Pinemeter/App/AppModel.swift")
        let settingsSource = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")

        XCTAssertTrue(
            appModelSource.contains("case (.claude, .clear):\n            try await clearSessionKey()"),
            "Claude reset must stay routed through AppModel.clearSessionKey so automated checks can use synthetic repository accounts."
        )
        XCTAssertTrue(
            appModelSource.contains("case (.chatGPT, .clear):\n            try await clearChatGPTSessionCookie()"),
            "ChatGPT reset must stay routed through AppModel.clearChatGPTSessionCookie so automated checks never delete unrelated credentials."
        )

        let claudeResetBody = try functionBody(
            named: "clearSessionKey",
            in: appModelSource,
            endingBefore: "    // MARK: - Notifications"
        )
        XCTAssertTrue(
            claudeResetBody.contains("try await keychainRepository.delete(account: \"default\")"),
            "Claude reset should delete only the app's selected Claude account through the repository abstraction."
        )
        XCTAssertFalse(
            claudeResetBody.contains("SecItemDelete"),
            "Claude reset tests must not rely on broad Keychain deletion APIs."
        )

        let chatGPTResetBody = try functionBody(
            named: "clearChatGPTSessionCookie",
            in: appModelSource,
            endingBefore: "    // MARK: - Session Key"
        )
        XCTAssertTrue(
            chatGPTResetBody.contains("try await chatGPTSessionRepository.clear(account: ChatGPTUsageService.defaultSessionAccount)"),
            "ChatGPT reset should delete only the app's selected ChatGPT account through the repository abstraction."
        )
        XCTAssertFalse(
            chatGPTResetBody.contains("keychainRepository.delete"),
            "ChatGPT reset must not delete Claude session key state."
        )
        XCTAssertFalse(
            chatGPTResetBody.contains("SecItemDelete"),
            "ChatGPT reset tests must not rely on broad Keychain deletion APIs."
        )

        for uiSource in [settingsSource, setupSource] {
            XCTAssertFalse(uiSource.contains("keychainRepository.delete"))
            XCTAssertFalse(uiSource.contains("chatGPTSessionRepository.clear"))
            XCTAssertFalse(uiSource.contains("SecItemDelete"))
            XCTAssertFalse(uiSource.contains("removePersistentDomain"))
        }
    }

    func test_networkServiceDiagnosticsDoNotLogResponseBodiesOrCredentialFragments() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let networkServiceURL = repositoryRoot
            .appendingPathComponent("Pinemeter")
            .appendingPathComponent("Services")
            .appendingPathComponent("NetworkService.swift")
        let source = try String(contentsOf: networkServiceURL, encoding: .utf8)

        let prohibitedBodyLoggingPatterns = [
            "responseBody",
            "Response:",
            "String(data: data"
        ]

        for prohibitedPattern in prohibitedBodyLoggingPatterns {
            XCTAssertFalse(
                source.contains(prohibitedPattern),
                "NetworkService diagnostics must not log or construct response bodies: \(prohibitedPattern)"
            )
        }

        let diagnosticLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("logger.") }
        let prohibitedDiagnosticFragments = [
            "Cookie:",
            "sessionKey",
            "Bearer",
            "responseBody"
        ]

        for diagnosticLine in diagnosticLines {
            for prohibitedFragment in prohibitedDiagnosticFragments {
                XCTAssertFalse(
                    diagnosticLine.contains(prohibitedFragment),
                    "NetworkService diagnostic logs must not include credential-shaped fragments or response bodies: \(prohibitedFragment)"
                )
            }
        }
    }

    // MARK: - T3 discovery trust boundary (260814-pz4, T-pz4-01/02/03)

    func test_t3InstanceDiscoveryServiceSource_neverReferencesCredentialBearingT3Paths() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/T3InstanceDiscoveryService.swift")
        let prohibitedPathLiterals = [
            "settings.json", // <!-- planner-discipline-allow: settings.json -->
            "clerk-tokens", // <!-- planner-discipline-allow: clerk-tokens -->
            "state.sqlite", // <!-- planner-discipline-allow: state.sqlite -->
            "secrets/" // <!-- planner-discipline-allow: secrets/ -->
        ]
        for prohibited in prohibitedPathLiterals {
            XCTAssertFalse(
                source.contains(prohibited),
                "T3InstanceDiscoveryService must never reference a credential-bearing T3 path: \(prohibited)"
            )
        }
    }

    func test_t3InstanceDiscoveryServiceSource_loggerLinesCarryOnlyCountsNeverDecodedContents() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/T3InstanceDiscoveryService.swift")
        let loggerLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("logger.") }

        XCTAssertFalse(loggerLines.isEmpty, "expected at least one logger call to audit")

        let prohibitedInterpolationFragments = [
            "instanceId", "displayName", "driver", "auth", "email",
            "checkedAt", "modelSlugs", "discovered.", "raw.", "\\(url"
        ]
        for line in loggerLines {
            for fragment in prohibitedInterpolationFragments {
                XCTAssertFalse(
                    line.contains(fragment),
                    "T3 discovery logger lines must carry only counts, never decoded file contents: \(fragment) in '\(line)'"
                )
            }
        }
    }

    func test_t3InstanceDiscoveryServiceSource_neverReferencesProviderInstances() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/T3InstanceDiscoveryService.swift")
        XCTAssertFalse(
            source.contains("providerInstances"),
            "discovery must never swap its enumeration source for settings.json's providerInstances, which carries a server password"
        )
    }

    func test_discoveredT3Instance_authBlockWithEmail_neverSurvivesDecodeReencode() throws {
        let json = """
        {
          "displayName": "Codex",
          "enabled": true,
          "installed": true,
          "status": "ready",
          "checkedAt": "2026-08-15T01:42:30.729Z",
          "instanceId": "codex",
          "driver": "codex",
          "auth": {
            "status": "authenticated",
            "type": "synthetic",
            "label": "Synthetic Subscription",
            "email": "synthetic-fixture-user@example-nonexistent.test"
          },
          "models": [{"slug": "gpt-5.6-sol", "name": "GPT-5.6 Sol"}]
        }
        """
        let decoded = try JSONDecoder().decode(DiscoveredT3Instance.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedText = try XCTUnwrap(String(data: reencoded, encoding: .utf8))

        XCTAssertFalse(reencodedText.contains("auth"))
        XCTAssertFalse(reencodedText.contains("email"))
        XCTAssertFalse(reencodedText.contains("synthetic-fixture-user"))
    }

    func testPhase8SerializedStoresRespectSourceAndCorrelationBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase8Security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentinels = [
            "prompt-secret-sentinel",
            "message-secret-sentinel",
            "credential-secret-sentinel",
            "access-token-secret-sentinel",
            "transcript-path-secret-sentinel",
            "file-content-secret-sentinel",
            "fingerprint-secret-sentinel",
            "t3-source-session-secret-sentinel",
            "private-cache-secret-sentinel",
            "raw-request-object-secret-sentinel",
            "raw-error-object-secret-sentinel",
        ]
        let telemetryStore = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: telemetryStore, adapter: { _ in
            T3UsageSummaryV3(
                contractVersion: 3,
                readAt: "2026-08-15T12:00:00Z",
                timeZone: "UTC",
                sinceDay: "2026-08-15",
                untilDay: "2026-08-15",
                buckets: [
                    .init(
                        day: "2026-08-15",
                        provider: .claude,
                        model: "claude-fable-5",
                        totals: .init(
                            uncachedInputTokens: 1,
                            cachedInputTokens: 2,
                            cacheCreationTokens: 3,
                            outputTokens: 4,
                            reasoningTokens: 4
                        ),
                        costUsd: 0.01,
                        cacheSavingsUsd: 0.02,
                        costSource: .providerReported,
                        records: 1,
                        unpricedRecords: 0,
                        sessions: 1
                    ),
                ],
                sources: [
                    .init(
                        fingerprint: .init(
                            hostId: sentinels[7],
                            provider: .claude,
                            resolvedHomePath: "/private/\(sentinels[4])/\(sentinels[8])",
                            volumeId: sentinels[6]
                        ),
                        status: .partial,
                        scannedFiles: 1,
                        skippedFiles: 0,
                        malformedRecords: 0,
                        distinctSessions: 1,
                        message: [sentinels[0], sentinels[1], sentinels[2], sentinels[3],
                                  sentinels[5], sentinels[9], sentinels[10]].joined(separator: " ")
                    ),
                ],
                pricing: .init(status: .fresh, source: "provider", fetchedAt: nil, knownModels: 1),
                scanDurationMs: 1
            )
        })
        _ = await service.refresh(
            instanceAvailability: .reachable,
            request: .init(sinceDay: "2026-08-15", untilDay: "2026-08-15", timeZone: "UTC")
        )

        let auditStore = BrokerAuditStore(storeDirectory: directory)
        let decisionID = "decision-security"
        try await auditStore.append(
            decision: phase8AuditDecision(decisionID: decisionID),
            timestamp: Date(timeIntervalSince1970: 1_786_800_000)
        )
        let threadID = "caller-thread-123"
        let sessionID = "caller-session-456"
        let opaqueFailureSentinels = [
            "opaque-Q7vK4pL9xR2mT8cW5zN1",
            TestConstants.githubShapedSentinel,
            TestConstants.slackShapedSentinel,
        ]
        let uncappedReason = "\u{0000}\n  " + opaqueFailureSentinels.joined(separator: " ") + "\u{0007}  "
        let expectedReason = try XCTUnwrap(BrokerLifecycleText.sanitizedFailureReason(uncappedReason))
        let persistedThreadID = try XCTUnwrap(BrokerLifecycleText.persistedIdentifier(threadID))
        let persistedSessionID = try XCTUnwrap(BrokerLifecycleText.persistedIdentifier(sessionID))
        let result = try await auditStore.reportLifecycle(
            BrokerLifecycleReport(
                decisionID: decisionID,
                status: .failed,
                threadID: threadID,
                sessionID: sessionID,
                failureReason: uncappedReason
            )
        )
        XCTAssertEqual(result, .recorded)

        let encodedStores = try [UsageTelemetryStore.fileName, "broker-audit.json"]
            .map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        for sentinel in sentinels {
            XCTAssertFalse(encodedStores.contains(sentinel), "serialized stores exposed \(sentinel)")
        }
        for sentinel in opaqueFailureSentinels {
            XCTAssertFalse(encodedStores.contains(sentinel), "audit store exposed \(sentinel)")
        }
        XCTAssertFalse(encodedStores.contains(threadID))
        XCTAssertFalse(encodedStores.contains(sessionID))
        XCTAssertTrue(encodedStores.contains(persistedThreadID))
        XCTAssertTrue(encodedStores.contains(persistedSessionID))
        XCTAssertEqual(expectedReason, BrokerLifecycleText.persistedFailureReason)
        XCTAssertTrue(encodedStores.contains(BrokerLifecycleText.persistedFailureReason))

        let restarted = BrokerAuditStore(storeDirectory: directory)
        let restartedRecords = await restarted.recordsSnapshot
        let persisted = try XCTUnwrap(restartedRecords.first?.terminal)
        XCTAssertEqual(persisted.threadID, persistedThreadID)
        XCTAssertEqual(persisted.sessionID, persistedSessionID)
        XCTAssertEqual(persisted.failureReason, expectedReason)

        for rawField in ["raw_request", "raw_error"] {
            let rawObject = """
            {"decision_id":"d","status":"failed","\(rawField)":{"message":"secret"}}
            """
            XCTAssertThrowsError(
                try JSONDecoder().decode(BrokerLifecycleReport.self, from: Data(rawObject.utf8))
            )
        }
    }

    func test_t3UsageSourceHasNoPrivateCacheOrTokenIssuancePath() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/T3UsageService.swift")

        XCTAssertFalse(source.contains("usage-scan-cache.json"))
        XCTAssertFalse(source.contains("t3 auth session issue"))
    }

    private func sourceContents(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = relativePath.split(separator: "/").reduce(repositoryRoot) { url, component in
            url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func phase8AuditDecision(decisionID: String) -> BrokerDecision {
        BrokerDecision(
            role: "planning",
            caller: "claude-code",
            model: "native/claude-fable-5",
            route: .native,
            agentModel: "fable",
            invocation: .agent(model: "fable"),
            reason: "native quota available",
            source: .policy,
            oracle: .absent,
            degraded: false,
            candidatesTried: [
                .init(candidate: "native/claude-fable-5", available: true, why: "native quota available"),
            ],
            decisionID: decisionID
        )
    }

    private func functionBody(named functionName: String, in source: String, endingBefore endMarker: String) throws -> String {
        let startToken = "func \(functionName)("
        let startIndex = try XCTUnwrap(source.range(of: startToken)?.lowerBound)
        let searchRange = startIndex..<source.endIndex
        let endIndex = try XCTUnwrap(source.range(of: endMarker, range: searchRange)?.lowerBound)
        return String(source[startIndex..<endIndex])
    }

    private func assertNoCredentialDisclosure(in descriptions: [String], file: StaticString = #filePath, line: UInt = #line) {
        for description in descriptions {
            for forbiddenFragment in forbiddenCredentialFragments {
                XCTAssertFalse(
                    description.contains(forbiddenFragment),
                    "User-facing error descriptions must not include credential-shaped fragments: \(forbiddenFragment)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertNoChatGPTCredentialDisclosure(in descriptions: [String], file: StaticString = #filePath, line: UInt = #line) {
        let forbiddenChatGPTFragments = [
            "__Secure-next-auth.session-token=synthetic-cookie-redaction-sentinel",
            "cf_clearance=synthetic-cookie-redaction-sentinel",
            "synthetic-cookie-redaction-sentinel",
            "Bearer synthetic-access-token-redaction-sentinel",
            "synthetic-access-token-redaction-sentinel"
        ]

        for description in descriptions {
            for forbiddenFragment in forbiddenChatGPTFragments {
                XCTAssertFalse(
                    description.contains(forbiddenFragment),
                    "ChatGPT diagnostics and persisted settings must not include credential material: \(forbiddenFragment)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertNoCredentialPersistenceFragments(in payload: String, file: StaticString = #filePath, line: UInt = #line) {
        let forbiddenPersistenceFragments = [
            "sessionKey",
            "sessionCookie",
            "accessToken",
            "CredentialState",
            "ProviderCredentialStatus",
            "credential_state",
            "credential_status",
            "session_key",
            "session_cookie",
            "access_token",
            "__Secure-next-auth",
            "Cookie",
            "Bearer",
            "sk-ant-"
        ]

        for forbiddenFragment in forbiddenPersistenceFragments {
            XCTAssertFalse(
                payload.contains(forbiddenFragment),
                "Settings persistence must not encode credential-bearing fields or values: \(forbiddenFragment)",
                file: file,
                line: line
            )
        }
    }
}

private struct SyntheticCredentialError: LocalizedError {
    var errorDescription: String? {
        "Synthetic upstream failure with sk-ant-test-synthetic-session-key, Cookie: __Secure-next-auth.session-token=synthetic-cookie, Bearer synthetic-access-token, access-token-synthetic-secret"
    }
}
