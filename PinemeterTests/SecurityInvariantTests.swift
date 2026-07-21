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
        settings.isSonnetUsageShown = true
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

    private func sourceContents(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = relativePath.split(separator: "/").reduce(repositoryRoot) { url, component in
            url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: sourceURL, encoding: .utf8)
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
