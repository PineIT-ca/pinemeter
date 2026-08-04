import XCTest
@testable import Pinemeter

final class ProviderErrorWorkflowTests: XCTestCase {
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
            ChatGPTUsageError.networkUnavailable.localizedDescription
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

    func test_settingsAndSetupRenderSharedProviderCredentialStatusModel() throws {
        let settingsSource = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")

        for source in [settingsSource, setupSource] {
            XCTAssertTrue(source.contains("providerCredentialStatuses"))
            XCTAssertTrue(source.contains("status.stateText"))
            XCTAssertTrue(source.contains("status.detailText"))
            XCTAssertTrue(source.contains("status.lastFailureTitle"))
            XCTAssertTrue(source.contains("handleCredentialAction(action.kind, for: status)"))
            XCTAssertFalse(source.contains("status.setupAccessibilityLabel"))
            XCTAssertFalse(source.contains("sk-ant-"))
            XCTAssertFalse(source.contains("__Secure-next-auth.session-token"))
        }

        // Setup stays strictly scan-only: no credential-entry fields at all.
        XCTAssertFalse(setupSource.contains("SecureField"))

        // Settings deliberately relaxes the scan-only invariant for Gemini ONLY:
        // a Google AI Studio API key has no browser cookie to scan, so paste is
        // the only mechanism. Claude/ChatGPT remain scan-only.
        let settingsSecureFieldCount = settingsSource.components(separatedBy: "SecureField(").count - 1
        XCTAssertEqual(settingsSecureFieldCount, 1)
        XCTAssertTrue(settingsSource.contains("SecureField(\"API key\", text: $geminiAPIKeyDraft)"))
    }

    func test_setupProviderStatusCardsExposeSharedRepairAndClearActionsWithoutManualCredentials() throws {
        let settingsSource = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        let setupSource = try sourceContents(relativePath: "Pinemeter/Views/Setup/SetupWizardView.swift")

        XCTAssertTrue(setupSource.contains("private func providerCredentialStatusActions(for status: AppProviderCredentialStatus) -> some View"))
        XCTAssertTrue(setupSource.contains("let visibleActions = status.actions.filter { $0.kind != .reconnect }"))
        XCTAssertTrue(setupSource.contains("activeCredentialActionProvider"))
        XCTAssertTrue(setupSource.contains("await performProviderCredentialAction(kind, for: status)"))
        XCTAssertTrue(setupSource.contains("try await appModel.performProviderCredentialAction(kind, for: status.provider)"))
        XCTAssertTrue(setupSource.contains("Reconnecting credentials from the signed-in browser session."))
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
        // Every TextField in SettingsView must be the account-label rename
        // field; no manual credential entry fields may exist.
        let settingsTextFieldCount = settingsSource.components(separatedBy: "TextField(").count - 1
        let accountLabelFieldCount = settingsSource
            .components(separatedBy: "TextField(account.label, text: accountLabelBinding(for: account.id))")
            .count - 1
        XCTAssertEqual(settingsTextFieldCount, accountLabelFieldCount)
        XCTAssertTrue(settingsSource.contains("TextField(account.label, text: accountLabelBinding(for: account.id))"))
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
