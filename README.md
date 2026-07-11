# Pinemeter

**All your AI usage. One glance.**

<p align="center">
  <a href="https://github.com/PineIT-ca/pinemeter/releases/latest/download/Pinemeter.dmg">
    <img src="https://img.shields.io/badge/Download%20Pinemeter-for%20macOS-2D5A45?style=for-the-badge&logo=apple&logoColor=white" alt="Download Pinemeter for macOS" height="46">
  </a>
</p>
<p align="center"><sub>Universal • Apple Silicon &amp; Intel • Developer ID notarized • macOS 14+</sub></p>

Pinemeter is a macOS menu bar app that watches every quota that can stop you mid-flow: Claude's 5-hour and weekly windows across all your accounts, ChatGPT's plan limits, and Gemini API usage. Live meters in the menu bar, an annotated dashboard in the popover, and notifications before you hit a wall.

A [Pineit](https://pineit.ca) project.

<p align="center">
  <img src="docs/popover.png" width="604" alt="Pinemeter popover showing quota bars for two Claude accounts, ChatGPT, and Gemini">
</p>

The menu bar shows the same meters in miniature, in the same order, so the popover doubles as the legend:

<p align="center">
  <img src="docs/menubar-icon.png" width="150" alt="Pinemeter menu bar icon with one mini meter per quota">
</p>

## Features

- **Every quota as a live meter** - one bar per limit, colour-coded by how close you are to the ceiling, with reset countdowns
- **Multiple Claude accounts** - one click scans your open browsers (Chrome, Safari, Firefox, every profile) and connects each signed-in Claude subscription; 5-hour, weekly, and optional Sonnet-weekly bars per account
- **ChatGPT plan limits** - session and weekly quota rows imported from your browser session
- **Gemini API quota** - connect an API key to track usage
- **Threshold notifications** - native macOS alerts at configurable warning and critical levels, plus session-reset notices
- **Local JSON export** - `~/.pinemeter/usage.json` for scripts, shell prompts, and dashboards
- **Auto-refresh** - updates every 1, 5, or 10 minutes

## Privacy and security

Your credentials never leave your Mac:

- Browser sessions are imported from your own local browser cookie stores and saved in the **macOS Keychain**, never in files or preferences
- Credentials are sent only to the provider they belong to (claude.ai, chatgpt.com, Google), only to read usage data
- No analytics, no telemetry, no third-party servers
- Error messages and logs are sanitized so credential material can never leak into them - enforced by tests (`PinemeterTests/SecurityInvariantTests.swift`)

Pinemeter is not App-Sandboxed because its core import feature reads browser cookie databases, which live outside any app container. Safari imports additionally require Full Disk Access; the app will point you to the right System Settings pane when needed.

## Installation

### Build from source

Requires macOS 14+ and Xcode 16+.

```bash
git clone https://github.com/PineIT-ca/pinemeter.git
cd pinemeter
xcodebuild build \
  -project Pinemeter.xcodeproj \
  -scheme Pinemeter \
  -configuration Release
```

Then copy the built `Pinemeter.app` from the build products directory into `/Applications`.

### First run

1. Launch Pinemeter - a gauge icon appears in the menu bar.
2. Sign in to claude.ai (and optionally chatgpt.com) in your browser.
3. Click the icon and choose **Scan open browsers**. Every signed-in account is detected and connected.
4. Optionally add a Gemini API key in Settings.

If browser import is unavailable, paste a Claude session key manually in Settings; Pinemeter accepts `sessionKey=sk-ant-...` cookie strings.

## Usage

- **Popover** - click the menu bar icon for the full dashboard: one labelled column per quota, percentage, reset time, and per-account attribution. **Rescan browsers** in the footer reconnects sessions after they expire.
- **Menu bar** - one mini meter per quota, identical order to the popover. Hover for a tooltip naming each bar.
- **Settings** - refresh interval, Sonnet visibility, icon colour, notification thresholds, and credential management (validate, repair, clear).

### JSON export

Pinemeter writes usage to `~/.pinemeter/usage.json` on every refresh, for use in scripts and status lines:

```bash
jq '.sessionUsage.utilization' ~/.pinemeter/usage.json
```

## Development

```bash
xcodebuild test \
  -project Pinemeter.xcodeproj \
  -scheme Pinemeter \
  -configuration Debug
```

Debug builds include a demo mode with synthetic data, useful for screenshots and UI work without real credentials:

```bash
Pinemeter.app/Contents/MacOS/Pinemeter --demo multiProvider --open-popover-after-launch
```

Modes: `safeUsage`, `warningUsage`, `criticalUsage`, `exceededUsage`, `withSonnet`, `multiProvider`, `loading`, `error`, `setupWizard`. Add `--render-screenshots <dir>` to write popover and menu bar PNGs and exit.

## License

MIT - see [LICENSE](LICENSE).

Based on [Pinemeter by Edd Mann](https://github.com/eddmann/Pinemeter), also MIT licensed. Multi-account support, the multi-provider bar chart dashboard, and the Pineit branding are additions by [Pineit](https://pineit.ca).
