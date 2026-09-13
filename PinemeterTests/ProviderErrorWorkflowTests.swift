import XCTest
@testable import Pinemeter

final class ProviderErrorWorkflowTests: XCTestCase {
    @MainActor
    func test_emptyOracleEnvelopeDoesNotClaimPreviouslyFetchedUsageIsStale() {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(), notificationService: NotificationServiceSpy())
        model.brokerUIState = BrokerUIState(serverState: .running(port: 43117), lastPickSummary: nil, lastPickDegraded: false, routeHealth: [], oracleFreshness: .init(present: false, stale: false, ageSeconds: nil, accounts: []))
        model.brokerUIState?.oracleFreshness = BrokerStatus.OracleFreshness(
            present: true, stale: true, ageSeconds: nil, accounts: [])
        XCTAssertEqual(BrokerStatusHeader(appModel: model).oracleText, "No usage data")
        model.brokerUIState?.oracleFreshness = BrokerStatus.OracleFreshness(
            present: true, stale: true, ageSeconds: 7200, accounts: [])
        XCTAssertEqual(BrokerStatusHeader(appModel: model).oracleText, "Usage data 2h old (stale)")
    }

    @MainActor
    func test_firstBrokerSetupDoesNotClaimInstructionsHaveChanged() {
        let model = AppModel(settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(), notificationService: NotificationServiceSpy())
        model.settings.broker.presetManifest.sources = [
            BrokerPresetManifestSource(urlString: "https://example.com/presets.json",
                cachedAgentSetup: BrokerAgentSetupNotice(revision: 1, changedAt: nil, summary: "Roles changed"))
        ]
        XCTAssertNotNil(model.settings.broker.effectiveAgentSetup)
        XCTAssertNil(BrokerInstructionsPane(appModel: model, hasLoadedCheck: true).pendingAgentSetupNotice)
    }

    @MainActor
    func test_accountStatusUsesUsageWithoutHidingCredentialFailures() {
        XCTAssertEqual(SettingsView.accountHealth(credentialHealth: .unknown, hasUsage: true, hasError: false), .valid)
        XCTAssertEqual(SettingsView.accountHealth(credentialHealth: nil, hasUsage: true, hasError: false), .valid)
        XCTAssertEqual(SettingsView.accountHealth(credentialHealth: .expired, hasUsage: true, hasError: false), .expired)
        XCTAssertEqual(SettingsView.accountHealth(credentialHealth: .valid, hasUsage: true, hasError: true), .unavailable)
        XCTAssertEqual(SettingsView.accountHealth(credentialHealth: nil, hasUsage: false, hasError: false), .unknown)
        XCTAssertEqual(SettingsView.accountStatusText(.valid), "Connected")
        XCTAssertEqual(SettingsView.accountStatusText(.unknown), "Waiting for usage")
    }

    func test_appError_noSessionKey_usesClaudeSpecificCredentialCopy() {
        XCTAssertEqual(AppError.noSessionKey.errorDescription, "No Claude session key found. Please complete setup.")
        XCTAssertEqual(AppError.noSessionKey.recoveryAction, "Complete Claude Setup")
    }

    func test_appError_sessionKeyInvalid_usesClaudeSpecificCredentialCopy() {
        XCTAssertEqual(AppError.sessionKeyInvalid.errorDescription, "Claude session key is invalid or expired. Please update in settings.")
        XCTAssertEqual(AppError.sessionKeyInvalid.recoveryAction, "Update Claude Session Key")
    }

    func test_networkAuthenticationFailed_usesClaudeSpecificCredentialCopy() {
        XCTAssertEqual(NetworkError.authenticationFailed.errorDescription, "Claude session key is invalid or expired")
    }

    func test_claudeRecoveryCopy_detectsOnlyClaudeCredentialAuthenticationMessages() {
        XCTAssertTrue(ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: "Claude session key is invalid or expired"))
        XCTAssertTrue(ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: "Claude authentication failed"))

        XCTAssertFalse(ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: "ChatGPT session token is invalid"))
        XCTAssertFalse(ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: "ChatGPT authentication failed"))
        XCTAssertFalse(ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: "Network timeout"))
    }

    func test_claudeRecoveryCopy_usesClaudeSpecificButtonLabel() {
        XCTAssertEqual(ClaudeCredentialRecoveryCopy.updateButtonTitle, "Update Claude Session Key")
    }

    func test_chatGPTUsageErrorsDoNotEchoCookieOrBearerTokenSentinels() {
        let forbiddenFragments = [
            "__Secure-next-auth.session-token=synthetic-cookie-redaction-sentinel",
            "synthetic-cookie-redaction-sentinel",
            "Bearer synthetic-access-token-redaction-sentinel",
            "synthetic-access-token-redaction-sentinel"
        ]
        let descriptions = [
            ChatGPTUsageError.missingSessionCookie.localizedDescription,
            ChatGPTUsageError.invalidSessionCookie.localizedDescription,
            ChatGPTUsageError.invalidResponse.localizedDescription,
            ChatGPTUsageError.httpError(statusCode: 401).localizedDescription,
            ChatGPTUsageError.networkUnavailable.localizedDescription,
            ChatGPTUsageError.secureStorageUnavailable.localizedDescription
        ]

        for description in descriptions {
            for forbiddenFragment in forbiddenFragments {
                XCTAssertFalse(
                    description.contains(forbiddenFragment),
                    "ChatGPT user-facing errors must not echo credential material: \(forbiddenFragment)"
                )
            }
        }
    }

    func test_chatGPTInvalidCredentialStatusKeepsRecoveryProviderSpecificAndSanitized() {
        let status = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            actions: [.init(kind: .reconnect), .init(kind: .clear)]
        )

        XCTAssertEqual(status.providerName, "ChatGPT")
        XCTAssertEqual(status.credentialName, "ChatGPT session cookie")
        XCTAssertEqual(status.setupPromptTitle, "Recover ChatGPT session cookie")
        XCTAssertEqual(status.setupPromptDescription, "Update the credential and try again.")
        XCTAssertEqual(status.actions.map { $0.displayTitle }, ["Reconnect", "Clear"])
        XCTAssertTrue(status.setupAccessibilityLabel.contains("ChatGPT session cookie status: Invalid"))
        XCTAssertFalse(status.setupAccessibilityLabel.contains("synthetic-chatgpt-session-cookie"))
    }

    func test_geminiCredentialStatusesCoverMissingConfiguredInvalidAndRetryCopy() {
        let missing = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .missing,
                failureCategory: .missing,
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            actions: []
        )
        let configured = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .valid,
                checkedAt: Date(timeIntervalSince1970: 1)
            ),
            actions: [.init(kind: .clear)]
        )
        let invalid = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date(timeIntervalSince1970: 2)
            ),
            actions: [.init(kind: .clear)]
        )
        let retryLater = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .unavailable,
                failureCategory: .networkUnavailable,
                checkedAt: Date(timeIntervalSince1970: 3)
            ),
            actions: [.init(kind: .clear)]
        )

        XCTAssertEqual(missing.setupPromptTitle, "Connect Gemini")
        XCTAssertEqual(missing.setupPromptDescription, "Add a Gemini API key in Settings.")
        XCTAssertTrue(missing.actions.isEmpty)

        XCTAssertEqual(configured.setupPromptTitle, "Saved Gemini API key is ready")
        XCTAssertEqual(configured.setupPromptDescription, "Saved Gemini API key is ready.")
        XCTAssertEqual(configured.actions.map(\.kind), [.clear])

        XCTAssertEqual(invalid.setupPromptTitle, "Recover Gemini API key")
        XCTAssertEqual(invalid.setupPromptDescription, "Update the credential and try again.")
        XCTAssertEqual(invalid.lastFailureTitle, "Credential rejected")
        XCTAssertEqual(invalid.actions.map(\.displayTitle), ["Clear"])

        XCTAssertEqual(retryLater.setupPromptDescription, "Try again later.")
        XCTAssertEqual(retryLater.actions.map(\.kind), [.clear])
        for status in [missing, configured, invalid, retryLater] {
            XCTAssertFalse(status.searchableText.contains("AIza"))
            XCTAssertFalse(status.setupAccessibilityLabel.contains("gemini-api-key-redaction-sentinel"))
        }
    }

    func test_credentialRecoverySetupCopyDoesNotExposeRawCredentialMaterial() {
        let status = AppProviderCredentialStatus(
            state: CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: .unavailable,
                failureCategory: .storageUnavailable,
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            actions: [.init(kind: .reconnect), .init(kind: .repair), .init(kind: .clear)]
        )

        XCTAssertEqual(status.setupPromptTitle, "Recover Claude session key")
        XCTAssertEqual(status.setupPromptDescription, "Check Keychain access and try again.")
        XCTAssertTrue(status.setupAccessibilityLabel.contains("Claude session key status: Unavailable"))
        XCTAssertFalse(status.setupAccessibilityLabel.contains("sk-ant-"))
    }

    func test_settingsRenderSharedCredentialStatusAndSetupLinksToAccountRecovery() throws {
        let settingsSource = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")

        for source in [settingsSource] {
            XCTAssertTrue(source.contains("providerCredentialStatuses"))
            XCTAssertTrue(source.contains("Self.accountHealth("))
            XCTAssertTrue(source.contains("Text(statusText)"))
            XCTAssertTrue(source.contains("status.lastFailureTitle"))
            XCTAssertTrue(source.contains("handleCredentialAction(action.kind, for: status)"))
            XCTAssertFalse(source.contains("status.setupAccessibilityLabel"))
            XCTAssertFalse(source.contains("sk-ant-"))
            XCTAssertFalse(source.contains("__Secure-next-auth.session-token"))
        }

        XCTAssertTrue(setupSource.contains("openSettings(.accounts)"))
        XCTAssertTrue(setupSource.contains("CopyableErrorText(errorMessage"))
        XCTAssertFalse(setupSource.contains("sk-ant-"))
        XCTAssertFalse(setupSource.contains("__Secure-next-auth.session-token"))

        // Setup stays strictly scan-only: no credential-entry fields at all.
        XCTAssertFalse(setupSource.contains("SecureField"))

        // Settings deliberately relaxes the scan-only invariant for Gemini ONLY:
        // a Google AI Studio API key has no browser cookie to scan, so paste is
        // the only mechanism. Claude/ChatGPT remain scan-only.
        let settingsSecureFieldCount = settingsSource.components(separatedBy: "SecureField(").count - 1
        XCTAssertEqual(settingsSecureFieldCount, 1)
        XCTAssertTrue(settingsSource.contains("SecureField(\"API key\", text: $geminiAPIKeyDraft)"))
    }

    func test_setupRoutesMaintenanceToConfirmedSettingsActionsWithoutManualCredentials() throws {
        let settingsSource = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")

        XCTAssertTrue(setupSource.contains("openSettings(.accounts)"))
        XCTAssertTrue(setupSource.contains("openSettings(.broker)"))
        XCTAssertTrue(setupSource.contains("onScanStarted()"))
        XCTAssertTrue(setupSource.contains("Continue to dashboard"))
        XCTAssertFalse(setupSource.contains("performProviderCredentialAction"))
        XCTAssertTrue(settingsSource.contains(".confirmationDialog("))
        XCTAssertTrue(settingsSource.contains("Button(\"Remove\", role: .destructive)"))
        XCTAssertFalse(setupSource.contains("await importProviderSessions(from: .defaultBrowser)"))
        XCTAssertFalse(setupSource.contains("await repairClaudeSessionKey()"))
        XCTAssertFalse(setupSource.contains("await clearSavedCredential(for: status.provider)"))
        XCTAssertTrue(setupSource.contains(".accessibilityElement(children: .contain)"))
        XCTAssertFalse(setupSource.contains("TextField"))
        XCTAssertFalse(setupSource.contains("validateAndSaveSessionKey"))
        XCTAssertFalse(setupSource.contains("validateAndSaveChatGPTSessionCookie"))

        XCTAssertTrue(settingsSource.contains("activeCredentialActionProvider"))
        XCTAssertTrue(settingsSource.contains("await performProviderCredentialAction(kind, for: status)"))
        XCTAssertTrue(settingsSource.contains("try await appModel.performProviderCredentialAction(kind, for: status.provider)"))
        XCTAssertTrue(settingsSource.contains("Reconnecting credentials from the signed-in browser session."))
        XCTAssertFalse(settingsSource.contains("case (.claude, .repair):"))
        XCTAssertFalse(settingsSource.contains("case (.chatGPT, .clear):"))
        XCTAssertFalse(settingsSource.contains("await repairClaudeSessionKey()"))
        XCTAssertFalse(settingsSource.contains("await clearSavedCredential(for: status.provider)"))
        // Every TextField in SettingsView must be an account-label rename
        // field, one per provider with renameable accounts; no manual
        // credential entry field may exist. The Gemini API key is the sole
        // credential input and uses SecureField, which this count excludes by
        // construction ("SecureField(" does not contain "TextField(").
        let accountLabelFields = [
            "TextField(account.label, text: accountLabelBinding(for: account.id))",
            "TextField(account.label, text: chatGPTAccountLabelBinding(for: account.id))",
            "TextField(account.label, text: geminiAccountLabelBinding(for: account.id))",
        ]
        let settingsTextFieldCount = settingsSource.components(separatedBy: "TextField(").count - 1
        let accountLabelFieldCount = accountLabelFields.reduce(0) { total, field in
            total + settingsSource.components(separatedBy: field).count - 1
        }
        XCTAssertEqual(settingsTextFieldCount, accountLabelFieldCount)
        for field in accountLabelFields {
            XCTAssertTrue(settingsSource.contains(field), "Missing account label field: \(field)")
        }
        XCTAssertFalse(settingsSource.contains("validateAndSaveSessionKey"))
        XCTAssertFalse(settingsSource.contains("validateAndSaveChatGPTSessionCookie"))
    }

    func test_clearCredentialWorkflowCopyIsProviderSpecificAndCredentialFree() {
        let statuses = [
            AppProviderCredentialStatus(
                state: CredentialState(
                    identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                    health: .invalid,
                    failureCategory: .providerRejected,
                    checkedAt: Date(timeIntervalSince1970: 0)
                ),
                actions: [.init(kind: .clear)]
            ),
            AppProviderCredentialStatus(
                state: CredentialState(
                    identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                    health: .invalid,
                    failureCategory: .providerRejected,
                    checkedAt: Date(timeIntervalSince1970: 0)
                ),
                actions: [.init(kind: .clear)]
            )
        ]
        let forbiddenFragments = [
            "sk-ant-test-reset-sentinel",
            "__Secure-next-auth.session-token=synthetic-reset-cookie",
            "Cookie:",
            "Bearer synthetic-reset-access-token"
        ]

        XCTAssertEqual(statuses.map(\.providerName), ["Claude", "ChatGPT"])
        XCTAssertEqual(statuses.map(\.credentialName), ["Claude session key", "ChatGPT session cookie"])
        XCTAssertEqual(statuses.map { $0.actions.map(\.displayTitle) }, [["Clear"], ["Clear"]])

        let userFacingCopy = statuses.flatMap { status in
            [
                status.providerName,
                status.credentialName,
                status.setupPromptTitle,
                status.setupPromptDescription,
                status.setupAccessibilityLabel
            ] + status.actions.map(\.displayTitle)
        }

        for copy in userFacingCopy {
            for forbiddenFragment in forbiddenFragments {
                XCTAssertFalse(
                    copy.contains(forbiddenFragment),
                    "Credential reset workflow copy must not expose synthetic credential material: \(forbiddenFragment)"
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

}
