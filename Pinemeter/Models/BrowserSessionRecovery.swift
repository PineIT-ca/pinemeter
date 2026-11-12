//
//  BrowserSessionRecovery.swift
//  Pinemeter
//
//  Incident 2026-10-01: every ChatGPT browser session expired and the
//  operator saw only "degraded", with no screen saying the real fix was
//  "sign in at chatgpt.com, then Rescan browsers". This file is the
//  operator-facing half of that fix: per-provider sign-in metadata, the
//  truthful login prompt copy (D-03), and the bounded recovery watch policy
//  that keeps retrying after the prompt without ever nagging again (D-04).
//

import Foundation

/// Per-provider browser sign-in metadata. `nil` for Gemini, which has no
/// browser session to restore.
extension CredentialProvider {
    /// The site the operator signs back into.
    var browserSignInHost: String? {
        switch self {
        case .chatGPT: "chatgpt.com"
        case .claude: "claude.ai"
        case .gemini: nil
        }
    }

    /// Where "Open <site>" points.
    var browserSignInURL: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/auth/login")
        case .claude: URL(string: "https://claude.ai/login")
        case .gemini: nil
        }
    }

    /// Which routes lose their headroom signal while this provider is
    /// disconnected, named so the operator understands the blast radius
    /// instead of just the symptom.
    var browserRouteDependency: String? {
        switch self {
        case .chatGPT: "Codex routes use your ChatGPT account."
        case .claude: "Claude routes use your Claude account."
        case .gemini: nil
        }
    }
}

/// How often, and how many times, the post-prompt recovery watch rechecks
/// browsers after a login prompt (D-04).
///
/// `standard` is the shipped policy, and it is the one number both the login
/// prompt's recheck-window sentence and ``AppModel/startBrowserRecoveryWatch(for:)``
/// read, so the two can never drift out of sync with each other.
struct BrowserRecoveryWatchPolicy: Equatable, Sendable {
    let interval: Duration
    let maxAttempts: Int

    static let standard = BrowserRecoveryWatchPolicy(interval: .seconds(30), maxAttempts: 20)
}

/// One button on the login prompt: a label and where it opens.
struct BrowserSignInButton: Equatable, Sendable {
    let title: String
    let url: URL
}

/// The per-provider login prompt copy (D-03): names the site(s), which
/// routes depend on the account, and the real recheck window the watch
/// (``BrowserRecoveryWatchPolicy``) actually runs -- never a vaguer "we'll
/// retry automatically" that could silently drift out of sync with the code
/// that does the retrying.
struct BrowserLoginPromptCopy: Equatable {
    let title: String
    let message: String
    let signInButtons: [BrowserSignInButton]
    let dismissButtonTitle = "Later"

    init(providers: [CredentialProvider], policy: BrowserRecoveryWatchPolicy = .standard) {
        // A provider with no sign-in URL (Gemini) has nothing this prompt can
        // say or do about it, so it is dropped rather than rendered as a
        // broken button. Caller order is kept: the prompt reads in the same
        // order the caller named the providers.
        let signInProviders = providers.filter { $0.browserSignInURL != nil }
        let names = signInProviders.map(\.displayName)
        let joinedNames = Self.joinedWithAnd(names)

        title = names.isEmpty ? "Sign In Again" : "Sign In to \(joinedNames) Again"

        let sessionWord = signInProviders.count > 1 ? "browser sessions" : "browser session"
        let routeDependencies = signInProviders.compactMap(\.browserRouteDependency).joined(separator: " ")
        let hosts = Self.joinedWithAnd(signInProviders.compactMap(\.browserSignInHost))
        let seconds = Int(policy.interval.components.seconds)
        let minutes = seconds * policy.maxAttempts / 60

        var messageParts = ["Pinemeter could not restore your \(joinedNames) \(sessionWord)."]
        if !routeDependencies.isEmpty { messageParts.append(routeDependencies) }
        if !hosts.isEmpty { messageParts.append("Sign in at \(hosts) in Chrome, Safari, or Firefox.") }
        messageParts.append(
            "Pinemeter rechecks your browsers every \(seconds) seconds for the next \(minutes) minutes "
                + "and reconnects automatically."
        )
        message = messageParts.joined(separator: " ")

        signInButtons = signInProviders.compactMap { provider in
            guard let host = provider.browserSignInHost, let url = provider.browserSignInURL else { return nil }
            return BrowserSignInButton(title: "Open \(host)", url: url)
        }
    }

    private static func joinedWithAnd(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// The "<Provider> reconnected" notification posted when the recovery watch
/// (or an explicit Reconnect action) restores a provider without needing a
/// second login prompt (D-04).
struct BrowserReconnectedNotice: Equatable, Sendable {
    let title: String
    let body: String

    init(provider: CredentialProvider) {
        switch provider {
        case .chatGPT:
            title = "ChatGPT reconnected"
            body = "Codex routes use fresh ChatGPT quota again."
        case .claude:
            title = "Claude reconnected"
            body = "Claude routes use fresh Claude quota again."
        case .gemini:
            title = "Gemini reconnected"
            body = "Gemini quota is fresh again."
        }
    }
}
