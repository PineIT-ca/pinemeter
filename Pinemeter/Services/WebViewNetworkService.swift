//
//  WebViewNetworkService.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation
import WebKit
import os

/// Network service using WKWebView to bypass Cloudflare bot protection
/// WKWebView uses the same TLS stack as Safari, so Cloudflare accepts its requests
@MainActor
final class WebViewNetworkService: NSObject, NetworkServiceProtocol {
    nonisolated static let logger = Logger(subsystem: "com.pinemeter", category: "WebViewNetworkService")

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var currentSessionKey: String?
    private let timeoutSeconds: Double = 30
    private let maxChallengeWaitSeconds: Double = 15
    private var challengeRetryCount = 0
    private let maxChallengeRetries = 30
    /// The single WKWebView and `continuation` slot can only serve one request
    /// at a time; concurrent callers (e.g. multi-account import validating
    /// sessions in a task group) must queue behind the in-flight request or
    /// they clobber each other's continuation and hang forever.
    private var lastRequest: Task<Data, Error>?
    private var requestGeneration = 0

    override init() {
        super.init()
        Task { await Self.purgeLegacyPersistentSessionKeyCookie() }
    }

    /// Cleanup for installs upgrading from a build that injected the
    /// `sessionKey` cookie into the persistent default `WKWebsiteDataStore`
    /// with a 30-day expiry and never purged it. The WebView now uses a
    /// non-persistent store (see `getOrCreateWebView`), so nothing new reaches
    /// disk, but a stale copy from a prior build may still be sitting there.
    /// Runs on every init and is idempotent: a no-op once clean, which also
    /// lets it converge if WebKit's out-of-process delete loses a race with
    /// an immediate quit.
    static func purgeLegacyPersistentSessionKeyCookie() async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await allCookies(from: cookieStore)
        where cookie.name == "sessionKey" && cookie.domain.hasSuffix("claude.ai") {
            await cookieStore.deleteCookie(cookie)
            Self.logger.info("Purged a legacy persistent claude.ai sessionKey cookie")
        }
    }

    /// Perform a generic HTTP request using WKWebView
    func request<T: Decodable>(
        _ endpoint: String,
        method: HTTPMethod,
        sessionKey: String
    ) async throws -> T {
        let data = try await performRequest(endpoint, method: method, sessionKey: sessionKey)

        #if DEBUG
        // Dev-only raw response dump for diagnosing API shape changes:
        // PINEMETER_DUMP_USAGE_DIR=<dir> writes each response body to a file.
        if let dumpDir = ProcessInfo.processInfo.environment["PINEMETER_DUMP_USAGE_DIR"] {
            let name = endpoint
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let url = URL(fileURLWithPath: dumpDir, isDirectory: true)
                .appendingPathComponent("\(Date().timeIntervalSince1970)-\(name).json")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url)
        }
        #endif

        // Decode response
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            let responseBody = String(data: data, encoding: .utf8) ?? "<unable to decode>"
            Self.logger.error("Failed to decode response from \(endpoint): \(error.localizedDescription)\nResponse: \(responseBody)")
            throw NetworkError.decodingFailed(underlyingError: error)
        }
    }

    private func performRequest(
        _ endpoint: String,
        method: HTTPMethod,
        sessionKey: String
    ) async throws -> Data {
        // Validate HTTPS
        guard endpoint.hasPrefix("https://") else {
            throw NetworkError.invalidURL
        }

        guard let url = URL(string: endpoint) else {
            throw NetworkError.invalidURL
        }

        // Serialize requests: chain each one behind the previous so the shared
        // WebView only ever serves one caller at a time.
        let previous = lastRequest
        let request = Task { () throws -> Data in
            _ = try? await previous?.value
            return try await self.executeRequest(url: url, endpoint: endpoint, sessionKey: sessionKey)
        }
        lastRequest = request
        return try await request.value
    }

    private func executeRequest(
        url: URL,
        endpoint: String,
        sessionKey: String
    ) async throws -> Data {
        Self.logger.info("Making request to: \(endpoint)")

        // Store session key for cookie injection
        currentSessionKey = sessionKey

        // Reset challenge retry count
        challengeRetryCount = 0

        // Create or reuse WebView
        let webView = getOrCreateWebView()

        // Set the session key cookie
        let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: sessionKey,
            .secure: true,
            .expires: Date().addingTimeInterval(86400 * 30)
        ])!

        // Purge any existing claude.ai sessionKey cookies first. A server-set
        // host cookie ("claude.ai") is a different cookie identity than the
        // injected domain cookie (".claude.ai"), so without this both are sent
        // and the stale one can win, authenticating the request as a
        // previously-used account. The store is per-process now, but a
        // multi-account refresh still reuses it across accounts.
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for stale in await Self.allCookies(from: cookieStore)
        where stale.name == "sessionKey" && stale.domain.hasSuffix("claude.ai") {
            await cookieStore.deleteCookie(stale)
        }
        await cookieStore.setCookie(cookie)

        requestGeneration += 1
        let generation = requestGeneration

        // Load the URL and wait for response
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            // Set up timeout. The generation check keeps a timeout task that
            // outlives its own request from cancelling a later one.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.timeoutSeconds))
                if self.requestGeneration == generation, self.continuation != nil {
                    self.continuation?.resume(throwing: NetworkError.timeout)
                    self.continuation = nil
                }
            }

            webView.load(URLRequest(url: url))
        }
    }

    private func getOrCreateWebView() -> WKWebView {
        if let existing = webView {
            return existing
        }

        let config = WKWebViewConfiguration()
        // Non-persistent: the injected sessionKey cookie and any Cloudflare
        // clearance live only in memory for this process's lifetime and never
        // reach disk. The WebView instance is cached for the app's lifetime,
        // so this costs no re-challenge per request; only a cold app launch
        // pays the challenge wait, which challengeRetryCount already tolerates.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        // Set up preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        self.webView = wv
        return wv
    }

    private func extractJSON() {
        guard let webView = webView else {
            continuation?.resume(throwing: NetworkError.invalidResponse)
            continuation = nil
            return
        }

        // Try to get raw JSON content - first check for pre tag (raw JSON view), then body text
        let script = """
        (function() {
            // Try pre tag first (raw JSON response)
            var pre = document.querySelector('pre');
            if (pre) return pre.innerText;
            // Fall back to body text
            return document.body.innerText;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                Self.logger.error("JavaScript evaluation failed: \(error.localizedDescription)")
                self.continuation?.resume(throwing: NetworkError.invalidResponse)
                self.continuation = nil
                return
            }

            guard let text = result as? String else {
                self.continuation?.resume(throwing: NetworkError.invalidResponse)
                self.continuation = nil
                return
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)


            // Check if the response looks like JSON (starts with [ or {)
            let looksLikeJSON = trimmed.hasPrefix("[") || trimmed.hasPrefix("{")

            // Check for Cloudflare challenge page
            let isChallengePage = text.contains("Just a moment") ||
                                  text.contains("Enable JavaScript") ||
                                  text.contains("Checking your browser") ||
                                  text.isEmpty


            if isChallengePage || !looksLikeJSON {
                // Still on challenge page or page not ready, retry
                self.challengeRetryCount += 1

                if self.challengeRetryCount < self.maxChallengeRetries {
                    Self.logger.info("Waiting for Cloudflare challenge to complete (attempt \(self.challengeRetryCount)/\(self.maxChallengeRetries))")
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        self.extractJSON()
                    }
                    return
                } else {
                    Self.logger.error("Cloudflare challenge did not complete in time")
                    self.continuation?.resume(throwing: NetworkError.httpError(statusCode: 403))
                    self.continuation = nil
                    return
                }
            }

            // Reset retry count for next request
            self.challengeRetryCount = 0

            guard let data = trimmed.data(using: .utf8) else {
                self.continuation?.resume(throwing: NetworkError.invalidResponse)
                self.continuation = nil
                return
            }

            Self.logger.info("Successfully extracted JSON response")
            self.continuation?.resume(returning: data)
            self.continuation = nil
        }
    }

    private static func allCookies(from cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewNetworkService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Small delay to ensure page is fully rendered
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            self.extractJSON()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("Navigation failed: \(error.localizedDescription)")
        self.continuation?.resume(throwing: NetworkError.networkUnavailable)
        self.continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("Provisional navigation failed: \(error.localizedDescription)")
        self.continuation?.resume(throwing: NetworkError.networkUnavailable)
        self.continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            if statusCode == 401 {
                self.continuation?.resume(throwing: NetworkError.authenticationFailed)
                self.continuation = nil
                decisionHandler(.cancel)
                return
            }

            if statusCode == 429 {
                self.continuation?.resume(throwing: NetworkError.rateLimitExceeded)
                self.continuation = nil
                decisionHandler(.cancel)
                return
            }

            // Log non-2xx responses but allow them to proceed (Cloudflare might serve 403 then redirect)
            if !(200...299).contains(statusCode) {
                Self.logger.warning("HTTP \(statusCode) response, allowing navigation to continue")
            }
        }

        decisionHandler(.allow)
    }
}
