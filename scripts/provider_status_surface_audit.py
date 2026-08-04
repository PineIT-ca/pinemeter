#!/usr/bin/env python3
"""Verify provider credential status surfaces stay centralized and sanitized.

This check is intentionally static: it guards the SwiftUI setup/settings surfaces from
regressing to direct credential reads or raw cookie/session-key presentation while the
provider credential status UI is being polished.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

APP_MODEL = ROOT / "Pinemeter" / "App" / "AppModel.swift"
SETTINGS_VIEW = ROOT / "Pinemeter" / "Views" / "Settings" / "SettingsView.swift"
SETUP_VIEW = ROOT / "Pinemeter" / "Views" / "Setup" / "SetupWizardView.swift"
APP_MODEL_TESTS = ROOT / "PinemeterTests" / "AppModelTests.swift"
PROVIDER_WORKFLOW_TESTS = ROOT / "PinemeterTests" / "ProviderErrorWorkflowTests.swift"

FORBIDDEN_UI_PATTERNS = {
    "loadSessionKey direct UI read": r"\bloadSessionKey\s*\(",
    "loadChatGPTSessionCookie direct UI read": r"\bloadChatGPTSessionCookie\s*\(",
    "raw imported cookie header UI reference": r"\bcookieHeader\b",
    "session key variable UI reference": r"\bsessionKey\b",
}

REQUIRED_SNIPPETS = {
    APP_MODEL: [
        "struct AppProviderCredentialStatus",
        "var providerCredentialStatuses: [AppProviderCredentialStatus]",
        "identity: CredentialIdentity(provider: .claude, kind: .sessionKey)",
        "identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie)",
        "var stateText: String",
        "var detailText: String",
        "let actions: [Action]",
        "recoverySuggestion",
        "setupAccessibilityLabel",
    ],
    SETTINGS_VIEW: [
        "ForEach(appModel.providerCredentialStatuses)",
        "providerCredentialRow(_ status: AppProviderCredentialStatus)",
        "never show saved credential values",
        "Text(status.detailText)",
        "Text(status.stateText)",
        "let visibleActions = status.actions.filter { $0.kind != .reconnect }",
        "if let recoverySuggestion = status.recoverySuggestion",
        "CopyableErrorText(recoverySuggestion",
    ],
    SETUP_VIEW: [
        "let statuses = appModel.providerCredentialStatuses",
        "credentialStatusCard(_ status: AppProviderCredentialStatus)",
        "Text(status.setupPromptTitle)",
        "Text(status.detailText)",
        "Text(status.stateText)",
        "providerCredentialStatusActions(for: status)",
        "let visibleActions = status.actions.filter { $0.kind != .reconnect }",
        ".accessibilityElement(children: .contain)",
    ],
    APP_MODEL_TESTS: [
        "test_providerCredentialStatusViewModelsExposeSanitizedClaudeAndChatGPTState",
        "test_providerCredentialStatusSetupPromptsDistinguishReadyMissingAndRepairableCredentials",
        "test_providerCredentialStatusesExposeRecoveryActionsForBoundaryStates",
        "XCTAssertFalse(claude.searchableText.contains(\"sk-ant-secret\"))",
    ],
    PROVIDER_WORKFLOW_TESTS: [
        "test_settingsAndSetupRenderSharedProviderCredentialStatusModel",
        "test_setupProviderStatusCardsExposeSharedRepairAndClearActionsWithoutManualCredentials",
        "XCTAssertTrue(source.contains(\"providerCredentialStatuses\"))",
        "XCTAssertTrue(source.contains(\"status.stateText\"))",
        "XCTAssertTrue(source.contains(\"status.detailText\"))",
        "XCTAssertTrue(source.contains(\"handleCredentialAction(action.kind, for: status)\"))",
        "XCTAssertFalse(source.contains(\"SecureField\"))",
        "XCTAssertFalse(source.contains(\"__Secure-next-auth.session-token\"))",
        "XCTAssertTrue(setupSource.contains(\"private func providerCredentialStatusActions(for status: AppProviderCredentialStatus) -> some View\"))",
        "XCTAssertTrue(setupSource.contains(\"let visibleActions = status.actions.filter { $0.kind != .reconnect }\"))",
        "XCTAssertFalse(setupSource.contains(\"TextField\"))",
        "XCTAssertFalse(setupSource.contains(\"validateAndSaveChatGPTSessionCookie\"))",
    ],
}


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise AssertionError(f"failed to read {path.relative_to(ROOT)}: {error}") from error


def assert_required_snippets() -> list[str]:
    failures: list[str] = []
    for path, snippets in REQUIRED_SNIPPETS.items():
        source = read(path)
        for snippet in snippets:
            if snippet not in source:
                failures.append(f"{path.relative_to(ROOT)} missing required snippet: {snippet}")
    return failures


def assert_ui_does_not_read_raw_credentials() -> list[str]:
    failures: list[str] = []
    for path in [SETTINGS_VIEW, SETUP_VIEW]:
        source = read(path)
        for label, pattern in FORBIDDEN_UI_PATTERNS.items():
            for match in re.finditer(pattern, source):
                line = source.count("\n", 0, match.start()) + 1
                failures.append(f"{path.relative_to(ROOT)}:{line} forbidden {label}: {match.group(0)}")
    return failures


def main() -> int:
    failures = assert_required_snippets()
    failures.extend(assert_ui_does_not_read_raw_credentials())

    if failures:
        print("provider status surface audit: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("provider status surface audit: PASS")
    print("- AppModel exposes centralized providerCredentialStatuses for Claude and ChatGPT.")
    print("- SettingsView and SetupWizardView render status rows/cards from sanitized status view models.")
    print("- Setup/settings UI sources do not directly read session keys, cookie headers, or raw credential values.")
    print("- Tests include provider status sanitization, prompt, recovery-action, and shared setup/settings rendering coverage.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
