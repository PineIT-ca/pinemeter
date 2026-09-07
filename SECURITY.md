# Security and Privacy Reporting

Pinemeter handles local provider credential material, including Claude session keys, optional ChatGPT session cookies, and optional Gemini API keys. Please report credential handling, privacy, or vulnerability concerns privately rather than opening a public issue.

## What to report privately

Use the private reporting path for issues such as:

- Raw provider credentials, cookies, tokens, API keys, or request headers being logged, displayed, exported, or written outside the intended secure storage boundary.
- Keychain storage, access-control, or credential repair behavior that could expose another account's provider material.
- Browser import behavior that reads more data than needed for the selected provider.
- Diagnostics, screenshots, crash logs, or issue templates that could encourage users to disclose secrets.
- A reproducible vulnerability in the app, release artifacts, or update/distribution process.

## How to report

If GitHub private vulnerability reporting is enabled for this repository, use **Security advisories > Report a vulnerability**.

If private vulnerability reporting is unavailable, contact the maintainer using the repository owner's published GitHub contact path and include **Pinemeter security report** in the subject or first line. Do not include working secrets in the first message.

## What to include

Please include sanitized details only:

- Pinemeter version or commit SHA.
- macOS version and Mac architecture.
- Provider affected: Claude, ChatGPT, Gemini, browser import, release signing, or app-wide.
- Reproduction steps using dummy, expired, or redacted values.
- The observed impact and what secret or private data could be exposed.
- Any relevant sanitized logs, screenshots, or diagnostics.

## What not to include

Do not send real Claude session keys, ChatGPT cookies, Gemini API keys, Cookie headers, Authorization headers, browser cookie database files, or screenshots that expose account identifiers unless explicitly requested over a private channel.

## Public issues

For ordinary bugs and feature requests that do not involve sensitive material, use the GitHub issue templates. Public issues should include sanitized app status and reproduction details only.
