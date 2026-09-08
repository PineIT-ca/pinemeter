//
//  WebViewNetworkService.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation
import WebKit
import os

struct WebViewRequestState {
    private var nextGeneration = 0
    private var owner: ObjectIdentifier?
    private(set) var activeGeneration: Int?
    private(set) var challengeRetryCount = 0

    mutating func begin(owner: ObjectIdentifier) -> Int {
        nextGeneration += 1
        activeGeneration = nextGeneration
        self.owner = owner
        challengeRetryCount = 0
        return nextGeneration
    }

    func generation(for owner: ObjectIdentifier) -> Int? {
        self.owner == owner ? activeGeneration : nil
    }

    func isActive(_ generation: Int) -> Bool {
        activeGeneration == generation
    }

    mutating func finish(_ generation: Int) -> Bool {
        guard isActive(generation) else { return false }
        activeGeneration = nil
        owner = nil
        challengeRetryCount = 0
        return true
    }

    mutating func nextChallengeRetry(for generation: Int) -> Int? {
        guard isActive(generation) else { return nil }
        challengeRetryCount += 1
        return challengeRetryCount
    }
}

/// Network service using WKWebView to bypass Cloudflare bot protection
/// WKWebView uses the same TLS stack as Safari, so Cloudflare accepts its requests
@MainActor
final class WebViewNetworkService: NSObject, NetworkServiceProtocol {
    nonisolated static let logger = Logger(subsystem: "com.pinemeter", category: "WebViewNetworkService")

    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private var activeWebView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var currentSessionKey: String?
    private let timeoutSeconds: Double = 30
    private let maxChallengeRetries = 30
    /// The continuation slot can only serve one request at a time. Each queued
    /// request gets a WebView identity so late delegate callbacks cannot be
    /// mistaken for the active request, while the shared data store preserves
    /// Cloudflare cookies between requests.
    private var lastRequest: Task<Data, Error>?
    private var requestState = WebViewRequestState()

    override init() {
        super.init()
        Task { await Self.purgeLegacyPersistentSessionKeyCookie() }
    }

    /// Cleanup for installs upgrading from a build that injected the
    /// `sessionKey` cookie into the persistent default `WKWebsiteDataStore`
    /// with a 30-day expiry and never purged it. The WebView now uses a
    /// non-persistent store (see `makeWebView`), so nothing new reaches
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
            Self.logger.error("Failed to decode response: bytes=\(data.count, privacy: .public)")
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

        // Serialize requests so the continuation slot only serves one caller.
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

        let webView = makeWebView()

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

        let generation = requestState.begin(owner: ObjectIdentifier(webView))
        activeWebView = webView

        // Load the URL and wait for response
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.timeoutSeconds))
                self.resume(.failure(NetworkError.timeout), generation: generation)
            }

            webView.load(URLRequest(url: url))
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore

        // Set up preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        return wv
    }

    private func resume(_ result: Result<Data, Error>, generation: Int) {
        guard requestState.isActive(generation), let continuation else { return }
        guard requestState.finish(generation) else { return }

        self.continuation = nil
        activeWebView?.navigationDelegate = nil
        activeWebView = nil
        continuation.resume(with: result)
    }

    private func extractJSON(generation: Int) {
        guard requestState.isActive(generation) else { return }
        guard let webView = activeWebView else {
            resume(.failure(NetworkError.invalidResponse), generation: generation)
            return
        }
        guard requestState.generation(for: ObjectIdentifier(webView)) == generation else { return }

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
            guard self.requestState.generation(for: ObjectIdentifier(webView)) == generation else { return }

            if let error = error {
                Self.logger.error("JavaScript evaluation failed: \(error.localizedDescription)")
                self.resume(.failure(NetworkError.invalidResponse), generation: generation)
                return
            }

            guard let text = result as? String else {
                self.resume(.failure(NetworkError.invalidResponse), generation: generation)
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
                guard let retryCount = self.requestState.nextChallengeRetry(for: generation) else { return }

                if retryCount < self.maxChallengeRetries {
                    Self.logger.info("Waiting for Cloudflare challenge to complete (attempt \(retryCount)/\(self.maxChallengeRetries))")
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        self.extractJSON(generation: generation)
                    }
                    return
                } else {
                    Self.logger.error("Cloudflare challenge did not complete in time")
                    self.resume(.failure(NetworkError.httpError(statusCode: 403)), generation: generation)
                    return
                }
            }

            guard let data = trimmed.data(using: .utf8) else {
                self.resume(.failure(NetworkError.invalidResponse), generation: generation)
                return
            }

            Self.logger.info("Successfully extracted JSON response")
            self.resume(.success(data), generation: generation)
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
        guard let generation = requestState.generation(for: ObjectIdentifier(webView)) else { return }
        // Small delay to ensure page is fully rendered
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            self.extractJSON(generation: generation)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let generation = requestState.generation(for: ObjectIdentifier(webView)) else { return }
        Self.logger.error("Navigation failed: \(error.localizedDescription)")
        resume(.failure(NetworkError.networkUnavailable), generation: generation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let generation = requestState.generation(for: ObjectIdentifier(webView)) else { return }
        Self.logger.error("Provisional navigation failed: \(error.localizedDescription)")
        resume(.failure(NetworkError.networkUnavailable), generation: generation)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let generation = requestState.generation(for: ObjectIdentifier(webView)) else {
            decisionHandler(.cancel)
            return
        }

        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            if statusCode == 401 {
                resume(.failure(NetworkError.authenticationFailed), generation: generation)
                decisionHandler(.cancel)
                return
            }

            if statusCode == 429 {
                resume(.failure(NetworkError.rateLimitExceeded), generation: generation)
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
