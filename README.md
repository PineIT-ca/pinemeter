# Pinemeter

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
  <a href="https://github.com/PineIT-ca/pinemeter/releases/latest"><img src="https://img.shields.io/github/v/release/PineIT-ca/pinemeter" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/PineIT-ca/pinemeter" alt="MIT license"></a>
</p>

<h3 align="center">See which AI account can take the next job.</h3>

<p align="center">
  A native macOS quota dashboard for Claude, ChatGPT/Codex, and Gemini.<br>
  See every account, every blocking window, and every reset countdown in one glance.
</p>

<p align="center">
  <a href="https://github.com/PineIT-ca/pinemeter/releases/latest/download/Pinemeter.dmg"><strong>Download the latest signed DMG</strong></a>
  · Free and open source
  · No provider CLIs required
</p>

<p align="center">
  <img src="docs/popover.png" width="628" alt="Pinemeter comparing 5-hour, weekly, and API quotas across work and personal Claude accounts, ChatGPT, and Gemini">
</p>

Pinemeter is built around one practical question: **do I have enough quota left to finish the next job?**

Instead of hiding each provider behind a separate menu or reducing several accounts to one number, Pinemeter turns one status item into a compact capacity map. Up to 12 miniature meters mirror the dashboard columns in the same order, so you can compare your available headroom before starting a long coding run.

<p align="center">
  <img src="docs/menubar-icon.png" width="150" alt="Seven miniature quota meters visible directly in the macOS menu bar">
</p>

## Why Pinemeter feels different

Pinemeter chooses depth over catalog size. It deliberately focuses on Claude, ChatGPT/Codex, and Gemini so their accounts and quota windows can share one coherent visual language. One status item carries the whole picture instead of multiplying into a row of provider icons.

### The menu bar is the dashboard

Up to 12 quotas shown in the popover have matching miniature meters in the menu bar. Five-hour windows, weekly windows, model-specific allowances, and API quota all stay visible at once. Meters turn red at 90%; stale data turns gray instead of pretending to be current.

### Multiple Claude accounts are first-class

One browser scan can discover distinct Claude subscriptions across open Chrome, Safari, and Firefox profiles. Label them `Work`, `Personal`, or anything useful, then compare their five-hour, weekly, and optional Fable limits side by side. Duplicate sessions are collapsed, and unwanted accounts can be excluded from future scans.

### It tracks limits, not local guesses

Pinemeter reads the quota data reported for your signed-in provider account, including reset times. It does not estimate plan usage from local token logs. You see the limits that can actually stop the work.

### No account switching or CLI setup

Stay signed in to the provider websites you already use and choose **Scan open browsers**. Pinemeter imports the local sessions, validates them, and stores them in macOS Keychain. There is no Pinemeter account, hosted backend, browser extension, or provider CLI dependency.

### Private by architecture

There is no analytics, telemetry, or cloud sync. Credentials remain in Keychain and are sent only to the provider they belong to. ChatGPT access tokens remain in memory. Credential-like values are excluded from errors and logs, with the boundary enforced by security tests.

## What it tracks

| Provider | Quotas | Connection |
| --- | --- | --- |
| **Claude** | Five-hour, weekly, and optional Fable limits for every connected subscription | Existing browser sessions across multiple profiles |
| **ChatGPT / Codex** | Five-hour, weekly, and any additional plan limit rows returned for the account | Existing ChatGPT browser session |
| **Gemini** | API quota when Google's response exposes numeric usage | Google AI Studio API key |

The dashboard groups quotas by account, shows current percentages and reset countdowns, and keeps the same left-to-right order in the popover and menu bar.

## More reasons to keep it running

- **Alerts that are hard to miss**: configurable center-screen warning and critical alerts for primary Claude five-hour usage, plus native macOS banners when permission is granted
- **A reset worth noticing**: an optional fireworks overlay tells you when the tracked session quota is ready again
- **Fast, automatic refresh**: update every 1, 5, or 10 minutes, refresh manually with `⌘R`, and launch automatically at login
- **Credential health and recovery**: see which connections are healthy, expired, or unavailable; repair or reconnect without exposing the credential
- **A display that fits your menu bar**: choose monochrome meters or one of six Apple system-color palettes
- **Scriptable primary Claude data**: fresh usage is exported to `~/.pinemeter/usage.json` for shell prompts, status lines, and local dashboards
- **Signed in-app updates**: receive release notifications and install signed updates without replacing the app manually

## Install

Pinemeter requires macOS 14 Sonoma or later.

1. [Download the latest `Pinemeter.dmg`](https://github.com/PineIT-ca/pinemeter/releases/latest/download/Pinemeter.dmg).
2. Open the DMG and drag Pinemeter into Applications.
3. Launch Pinemeter. The release is signed with Developer ID and notarized by Apple.
4. Sign in to `claude.ai` and, optionally, `chatgpt.com` in your browser.
5. Click the Pinemeter icon and choose **Scan open browsers**.
6. Optionally add a Google AI Studio key in Settings for Gemini.

Pinemeter can reconnect sessions with **Rescan browsers** when they expire. Safari import requires Full Disk Access; the app links directly to the correct System Settings pane when access is needed.

### Build from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/PineIT-ca/pinemeter.git
cd pinemeter
xcodebuild clean build \
  -project Pinemeter.xcodeproj \
  -scheme Pinemeter \
  -configuration Release
```

Copy `Pinemeter.app` from the build products directory into `/Applications`.

## Privacy and browser access

Pinemeter is not App-Sandboxed because browser cookie databases live outside app containers. It asks macOS for only the local access needed to import sessions:

- Browser credentials are read from local browser stores and saved in **macOS Keychain**, never in preferences or plaintext files
- Provider credentials are sent only to `claude.ai`, `chatgpt.com`, or Google's API, as applicable
- GitHub is contacted only for signed release checks and downloads
- Logs and errors are sanitized against credential leakage, verified in [`SecurityInvariantTests.swift`](PinemeterTests/SecurityInvariantTests.swift)

The source is available here so the entire credential path can be audited.

## JSON export

On every successful primary Claude refresh, Pinemeter writes:

```text
~/.pinemeter/usage.json
```

For example:

```bash
jq '.session_usage.utilization' ~/.pinemeter/usage.json
```

## Development

Run the test suite:

```bash
xcodebuild test \
  -project Pinemeter.xcodeproj \
  -scheme Pinemeter \
  -configuration Debug
```

Debug builds include synthetic demo modes for screenshots and UI work without real credentials:

```bash
Pinemeter.app/Contents/MacOS/Pinemeter \
  --demo multiProvider \
  --open-popover-after-launch
```

Available modes: `safeUsage`, `warningUsage`, `criticalUsage`, `exceededUsage`, `withFable`, `multiProvider`, `loading`, `error`, and `setupWizard`. Add `--render-screenshots <dir>` to write popover and menu bar PNGs and exit.

## Project

Pinemeter is a [Pineit](https://pineit.ca) project, released under the [MIT License](LICENSE).

It began with [Pinemeter by Edd Mann](https://github.com/eddmann/Pinemeter), also MIT licensed. Multi-account support, browser-wide discovery, ChatGPT and Gemini tracking, the multi-provider quota dashboard, and Pineit branding were added by Pineit.

Pinemeter is not affiliated with Anthropic, OpenAI, or Google. Provider usage endpoints and the quota fields they expose can change.
