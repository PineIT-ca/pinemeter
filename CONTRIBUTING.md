# Contributing to Pinemeter

Thanks for helping improve Pinemeter. This project is a macOS menu bar app that reads local provider session/API state to show usage and quota information, so high-quality reports need to separate user-visible behavior from private credentials.

## Before opening an issue

1. Search existing issues for similar reports or requests.
2. Check the README troubleshooting section for provider-specific reset paths.
3. Update to the latest release, or mention the commit/build you tested from source.
4. Do not paste Claude session keys, ChatGPT cookies, Gemini API keys, Cookie headers, request headers, or screenshots that expose account identifiers.

## Reporting bugs

Use the **Bug report** issue form or the portable Markdown checklist in [`.github/ISSUE_TEMPLATE/bug_report.md`](.github/ISSUE_TEMPLATE/bug_report.md). Include:

- Pinemeter version or commit SHA.
- macOS version and Mac architecture.
- Provider affected: Claude, ChatGPT, Gemini, or app-wide.
- Setup path used: browser import, manual credential entry, API key, source build via `xcodebuild`, upgrade from existing settings, or not configured.
- Expected behavior and actual behavior.
- Sanitized provider state such as configured/not configured, connected/disconnected, quota visible/not visible, or sanitized error category.
- Steps to reproduce.
- Logs or screenshots only after redacting or removing secrets, tokens, cookies, session identifiers, request headers, account identifiers, and private workspace names.

For credential, privacy, or vulnerability concerns, do **not** open a public issue. Use the private reporting path in [SECURITY.md](SECURITY.md).

## Requesting features

Use the **Feature request** issue form or the portable Markdown checklist in [`.github/ISSUE_TEMPLATE/feature_request.md`](.github/ISSUE_TEMPLATE/feature_request.md). Describe the user problem, proposed behavior, expected benefit, alternatives considered, and any privacy/security implications. Provider integrations should explain what user-visible value they add and what local credential/session material would be required.

## Working on code

- Build with Xcode 16 or later.
- Keep SwiftUI UI state on `@MainActor @Observable` types.
- Keep non-UI work in actor services/repositories.
- Persist new user-facing settings through `SettingsRepository`, expose them in `SettingsView` when appropriate, and decode older saved settings safely.
- Treat provider credentials, cookies, tokens, and headers as secret material. Do not log or persist raw values outside their intended secure storage boundary.

Useful local commands:

```bash
xcodebuild clean build -project Pinemeter.xcodeproj -scheme Pinemeter -configuration Debug

xcodebuild test \
  -project Pinemeter.xcodeproj \
  -scheme Pinemeter \
  -configuration Debug \
  -skip-testing:PinemeterTests/MenuBarIconSnapshotTests \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

## Pull requests

Pull requests should include:

- A short description of the user-facing change.
- Verification performed, including build/test commands or manual checks.
- Notes about credential handling or diagnostics when the change touches provider setup, import, storage, logging, or error reporting.
- Screenshots for visible UI changes when practical.

Please keep pull requests focused. Split unrelated behavior, UI, and documentation changes when that makes review easier.
