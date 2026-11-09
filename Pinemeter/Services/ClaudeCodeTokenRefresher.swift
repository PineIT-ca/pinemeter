//
//  ClaudeCodeTokenRefresher.swift
//  Pinemeter
//
//  Refreshes an expired Claude Code login in place, so a CLI-origin account
//  keeps polling when no Claude Code session has refreshed the item (#236).
//  The rotated pair goes back into the same `Claude Code-credentials*`
//  Keychain item, so Claude Code keeps working with it.
//
//  This follows Claude Code's own protocol (verified against the 2.1.318
//  binary): the `.oauth_refresh.lock` and legacy `<dir>.lock` directories
//  around the token request, a re-read under the lock, the `.storage-write`
//  directory around the write, a compare-and-swap on the stored refresh
//  token, and `security -i` with the command on stdin, so no secret ever
//  enters a process argument. A failed refresh never deletes or blanks the
//  item. No token is ever logged; outcomes use a fixed vocabulary.
//

import Darwin
import Foundation
import os

/// A secret string that never prints. `rawValue` is the only accessor.
struct ClaudeCodeSecretValue: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Writes one Keychain item's secret. Tests supply a fake.
protocol ClaudeCodeKeychainSecretWriting: Sendable {
    func writeSecret(service: String, account: String, secret: Data) async -> Bool
}

/// Writes through `/usr/bin/security -i`, the same tool and mode Claude Code
/// uses, so the item's access-control list keeps trusting the writer and the
/// secret only travels on stdin.
struct SecurityToolClaudeCodeSecretWriter: ClaudeCodeKeychainSecretWriting {
    static let arguments = ["-i"]
    /// Claude Code's own limit for one `security -i` command line.
    static let maxCommandBytes = 4_032

    /// The stdin command, or `nil` when the names are unsafe to quote or the
    /// line would exceed `security -i`'s limit.
    static func command(service: String, account: String, secret: Data) -> Data? {
        guard ClaudeCodeLoginReader.isClaudeCodeService(service),
              account.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        guard line.utf8.count <= maxCommandBytes else { return nil }
        return Data(line.utf8)
    }

    func writeSecret(service: String, account: String, secret: Data) async -> Bool {
        guard let input = Self.command(service: service, account: account, secret: secret) else { return false }
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: SecurityToolClaudeCodeSecretReader.executableURL,
            environment: SecurityToolClaudeCodeSecretReader.environment,
            timeout: SecurityToolClaudeCodeSecretReader.timeout,
            maxOutputBytes: SecurityToolClaudeCodeSecretReader.maxOutputBytes
        )
        return await runner.runCommand(arguments: Self.arguments, input: input)
    }
}

// MARK: - Token endpoint

struct ClaudeCodeTokenGrant: Sendable {
    let accessToken: ClaudeCodeSecretValue
    let refreshToken: ClaudeCodeSecretValue?
    let expiresIn: TimeInterval
    let refreshTokenExpiresIn: TimeInterval?
    let scopes: [String]?
}

enum ClaudeCodeTokenRefreshResult: Sendable {
    case tokens(ClaudeCodeTokenGrant)
    case invalidGrant
    case retryLater(retryAfter: TimeInterval?)
    case failed
}

protocol ClaudeCodeTokenEndpoint: Sendable {
    func refresh(refreshToken: ClaudeCodeSecretValue, clientId: String, scopes: [String]?) async -> ClaudeCodeTokenRefreshResult
}

/// Claude Code's own token request. The `axios/` agent matches Claude Code;
/// a `claude-code/` agent is rate limited on this endpoint.
struct URLSessionClaudeCodeTokenEndpoint: ClaudeCodeTokenEndpoint {
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let defaultClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let maxResponseBytes = 65_536
    private static let logger = Logger(subsystem: "com.pinemeter", category: "ClaudeCodeRefresh")

    let session: URLSession
    let url: URL

    /// `configuration` is a test seam: tests pass one with stub protocol
    /// classes to exercise the default session and its redirect refusal.
    init(
        session: URLSession? = nil,
        url: URL = URLSessionClaudeCodeTokenEndpoint.tokenURL,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        if let session {
            self.session = session
        } else {
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        self.url = url
    }

    func refresh(refreshToken: ClaudeCodeSecretValue, clientId: String, scopes: [String]?) async -> ClaudeCodeTokenRefreshResult {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken.rawValue,
            "client_id": clientId,
        ]
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return .failed }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("axios/1.15.2", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Claude token refresh failed: transport")
            return .retryLater(retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse, data.count <= Self.maxResponseBytes else { return .failed }
        Self.logger.info("Claude token refresh: http=\(http.statusCode, privacy: .public)")
        return Self.classify(status: http.statusCode, headers: http, body: data)
    }

    static func classify(status: Int, headers: HTTPURLResponse?, body: Data) -> ClaudeCodeTokenRefreshResult {
        switch status {
        case 200...299:
            return grant(from: body).map(ClaudeCodeTokenRefreshResult.tokens) ?? .failed
        case 400, 401:
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["type"] as? String)
            return code == "invalid_grant" ? .invalidGrant : .failed
        case 429, 500...599:
            let retryAfter = headers?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .retryLater(retryAfter: retryAfter)
        default:
            return .failed
        }
    }

    static func grant(from body: Data) -> ClaudeCodeTokenGrant? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 else {
            return nil
        }
        let refresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : ClaudeCodeSecretValue($0) }
        let scopes = (object["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
        return ClaudeCodeTokenGrant(
            accessToken: ClaudeCodeSecretValue(access),
            refreshToken: refresh,
            expiresIn: expiresIn,
            refreshTokenExpiresIn: (object["refresh_token_expires_in"] as? NSNumber)?.doubleValue,
            scopes: scopes
        )
    }
}

/// The request body carries the refresh token, so a redirect is never
/// followed; the 3xx response itself classifies as `.failed`.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Lock directories

/// A proper-lockfile style lock: `mkdir` acquires, `rmdir` releases, and a
/// directory whose mtime is older than `staleAfter` is taken over.
final class ClaudeCodeDirectoryLock: @unchecked Sendable {
    let path: String
    private var released = false

    private init(path: String) { self.path = path }

    static func acquire(path: String, staleAfter: TimeInterval, now: Date) -> ClaudeCodeDirectoryLock? {
        for attempt in 0..<2 {
            if mkdir(path, 0o700) == 0 { return ClaudeCodeDirectoryLock(path: path) }
            guard errno == EEXIST, attempt == 0 else { return nil }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(mtime) > staleAfter, rmdir(path) == 0 else { return nil }
        }
        return nil
    }

    /// Keeps the lock fresh for other holders' stale checks.
    func touch() {
        guard !released else { return }
        utimes(path, nil)
    }

    func release() {
        guard !released else { return }
        released = true
        rmdir(path)
    }

    deinit { release() }
}

// MARK: - Refresher

enum ClaudeCodeRefreshOutcome: String, Sendable {
    case refreshed
    case adopted
    case notNeeded
    case lockBusy
    case noRefreshToken
    case refreshTokenDead
    case backingOff
    case unsupportedItem
    case readFailed
    case requestFailed
    case writeFailed
}

actor ClaudeCodeTokenRefresher {
    static let refreshLockStaleAfter: TimeInterval = 60
    static let storageLockStaleAfter: TimeInterval = 15
    static let storageLockAttempts = 10
    /// Room for a longer rotated pair in the `security -i` command line.
    static let commandHeadroomBytes = 512

    private static let logger = Logger(subsystem: "com.pinemeter", category: "ClaudeCodeRefresh")

    private struct Backoff {
        let until: Date?
        let modificationDate: Date?
        let failures: Int
    }

    private struct PendingWrite {
        let account: String
        let consumedRefreshToken: String
        let grant: ClaudeCodeTokenGrant
        let issuedAt: Date
    }

    private let secretReader: any ClaudeCodeKeychainSecretReading
    private let secretWriter: any ClaudeCodeKeychainSecretWriting
    private let endpoint: any ClaudeCodeTokenEndpoint
    private let configDirectory: @Sendable (String) -> URL?
    private let sleep: @Sendable (Duration) async -> Void
    private var backoff: [String: Backoff] = [:]
    private var pending: [String: PendingWrite] = [:]

    init(
        secretReader: any ClaudeCodeKeychainSecretReading = SecurityToolClaudeCodeSecretReader(),
        secretWriter: any ClaudeCodeKeychainSecretWriting = SecurityToolClaudeCodeSecretWriter(),
        endpoint: any ClaudeCodeTokenEndpoint = URLSessionClaudeCodeTokenEndpoint(),
        configDirectory: @escaping @Sendable (String) -> URL?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.secretReader = secretReader
        self.secretWriter = secretWriter
        self.endpoint = endpoint
        self.configDirectory = configDirectory
        self.sleep = sleep
    }

    func refreshIfExpired(item: ClaudeCodeKeychainItem, now: Date) async -> ClaudeCodeRefreshOutcome {
        let outcome = await run(item: item, now: now)
        Self.logger.info("Claude login refresh: outcome=\(outcome.rawValue, privacy: .public)")
        return outcome
    }

    private func run(item: ClaudeCodeKeychainItem, now: Date) async -> ClaudeCodeRefreshOutcome {
        let service = item.service
        guard ClaudeCodeLoginReader.isClaudeCodeService(service),
              item.account.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil,
              let directory = configDirectory(service) else {
            return .unsupportedItem
        }

        // An issued pair is kept until it is written or a sibling's write
        // supersedes it, however old it is: its refresh token is the only
        // live one, and posting the consumed token again would fail.
        if pending[service] != nil {
            return await commitPending(service: service, directory: directory, now: now)
        }

        if let entry = backoff[service] {
            if entry.modificationDate != item.modificationDate {
                backoff[service] = nil
            } else if entry.until.map({ now < $0 }) ?? true {
                return .backingOff
            }
        }

        guard let initial = await readDocument(service: service, account: item.account) else { return .readFailed }
        if let early = Self.precheck(initial, service: service, account: item.account, now: now) {
            if early == .refreshTokenDead || early == .unsupportedItem || early == .noRefreshToken {
                backoff[service] = Backoff(until: nil, modificationDate: item.modificationDate, failures: 0)
            }
            return early
        }

        guard let refreshLock = ClaudeCodeDirectoryLock.acquire(
            path: directory.appendingPathComponent(".oauth_refresh.lock").path,
            staleAfter: Self.refreshLockStaleAfter,
            now: Date()
        ) else { return .lockBusy }
        defer { refreshLock.release() }
        let legacyPath = directory.resolvingSymlinksInPath().path + ".lock"
        guard let legacyLock = ClaudeCodeDirectoryLock.acquire(
            path: legacyPath,
            staleAfter: Self.refreshLockStaleAfter,
            now: Date()
        ) else { return .lockBusy }
        defer { legacyLock.release() }

        // Re-read under the lock: a sibling may have refreshed already.
        guard let current = await readDocument(service: service, account: item.account) else { return .readFailed }
        if let early = Self.precheck(current, service: service, account: item.account, now: now) {
            return early == .notNeeded ? .adopted : early
        }
        guard let posted = Self.oauthString(current, "refreshToken") else { return .noRefreshToken }

        refreshLock.touch()
        legacyLock.touch()
        let clientId = Self.oauthString(current, "clientId") ?? URLSessionClaudeCodeTokenEndpoint.defaultClientId
        let scopes = (current["claudeAiOauth"] as? [String: Any])?["scopes"] as? [String]
        let result = await endpoint.refresh(refreshToken: ClaudeCodeSecretValue(posted), clientId: clientId, scopes: scopes)
        refreshLock.touch()
        legacyLock.touch()

        switch result {
        case .tokens(let grant):
            backoff[service] = nil
            pending[service] = PendingWrite(account: item.account, consumedRefreshToken: posted, grant: grant, issuedAt: now)
            return await commitPending(service: service, directory: directory, now: now)
        case .invalidGrant:
            if let after = await readDocument(service: service, account: item.account),
               Self.oauthString(after, "refreshToken") != posted {
                return Self.precheck(after, service: service, account: item.account, now: now) == .notNeeded
                    ? .adopted : .refreshTokenDead
            }
            backoff[service] = Backoff(until: nil, modificationDate: item.modificationDate, failures: 0)
            return .refreshTokenDead
        case .retryLater(let retryAfter):
            noteFailure(service: service, modificationDate: item.modificationDate, now: now, minimum: retryAfter)
            return .requestFailed
        case .failed:
            noteFailure(service: service, modificationDate: item.modificationDate, now: now, minimum: 900)
            return .requestFailed
        }
    }

    /// Writes a pair the token endpoint already issued. Only writes while the
    /// item still holds the consumed refresh token or an empty one; any other
    /// token means a sibling wrote a newer login, which always wins.
    private func commitPending(service: String, directory: URL, now: Date) async -> ClaudeCodeRefreshOutcome {
        guard let entry = pending[service] else { return .notNeeded }
        let lockPath = directory.appendingPathComponent(".storage-write").path
        var storageLock: ClaudeCodeDirectoryLock?
        for attempt in 0..<Self.storageLockAttempts {
            storageLock = ClaudeCodeDirectoryLock.acquire(path: lockPath, staleAfter: Self.storageLockStaleAfter, now: Date())
            if storageLock != nil { break }
            if attempt + 1 < Self.storageLockAttempts { await sleep(.milliseconds(200)) }
        }
        guard let storageLock else { return .writeFailed }
        defer { storageLock.release() }

        guard let current = await readDocument(service: service, account: entry.account) else { return .writeFailed }
        storageLock.touch()
        let storedOAuth = current["claudeAiOauth"] as? [String: Any]
        let stored = storedOAuth?["refreshToken"] as? String ?? ""
        // An empty refresh token is ours to fill only for Claude Code's own
        // dead-pair blanking (an empty pair, expiry 0 or absent), never a
        // different login without a refresh token, and never an item whose
        // login was removed.
        let storedExpiry = (storedOAuth?["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let blanked = storedOAuth != nil && stored.isEmpty
            && Self.oauthString(current, "accessToken") == nil && storedExpiry == 0
        guard blanked || stored == entry.consumedRefreshToken else {
            pending[service] = nil
            return .adopted
        }
        let merged = Self.merged(current, grant: entry.grant, postedRefreshToken: entry.consumedRefreshToken, issuedAt: entry.issuedAt)
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.withoutEscapingSlashes]),
              await secretWriter.writeSecret(service: service, account: entry.account, secret: data) else {
            return .writeFailed
        }
        storageLock.touch()
        let expected = entry.grant.refreshToken?.rawValue ?? entry.consumedRefreshToken
        guard let check = await readDocument(service: service, account: entry.account),
              Self.oauthString(check, "accessToken") == entry.grant.accessToken.rawValue,
              Self.oauthString(check, "refreshToken") == expected else {
            return .writeFailed
        }
        pending[service] = nil
        return .refreshed
    }

    private func noteFailure(service: String, modificationDate: Date?, now: Date, minimum: TimeInterval?) {
        let failures = (backoff[service]?.failures ?? 0) + 1
        let delay = max(minimum ?? 0, min(3_600, 60 * pow(2, Double(failures - 1))))
        backoff[service] = Backoff(until: now.addingTimeInterval(delay), modificationDate: modificationDate, failures: failures)
    }

    private func readDocument(service: String, account: String) async -> [String: Any]? {
        guard case .secret(var data) = await secretReader.readSecret(service: service, account: account) else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        return Self.document(from: data)
    }

    // MARK: Pure helpers

    /// Decodes plain JSON or the lowercase-hex JSON `security -X` stores.
    static func document(from data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        var json: Data
        if text.hasPrefix("{") {
            json = Data(text.utf8)
        } else {
            guard text.count % 2 == 0, text.range(of: #"^[0-9a-f]+$"#, options: .regularExpression) != nil else { return nil }
            var bytes = [UInt8]()
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            json = Data(bytes)
        }
        defer { json.resetBytes(in: 0..<json.count) }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    static func oauthString(_ document: [String: Any], _ key: String) -> String? {
        guard let value = (document["claudeAiOauth"] as? [String: Any])?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// `nil` when the item needs a refresh and can take one; otherwise the
    /// reason it must not be refreshed now.
    static func precheck(_ document: [String: Any], service: String, account: String, now: Date) -> ClaudeCodeRefreshOutcome? {
        guard let oauth = document["claudeAiOauth"] as? [String: Any] else { return .noRefreshToken }
        if let access = oauth["accessToken"] as? String, !access.isEmpty,
           let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1_000) > now.addingTimeInterval(CLILoginExpiry.skew) {
            return .notNeeded
        }
        guard oauthString(document, "refreshToken") != nil else { return .noRefreshToken }
        if let refreshExpiresAt = (oauth["refreshTokenExpiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: refreshExpiresAt / 1_000) <= now {
            return .refreshTokenDead
        }
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.withoutEscapingSlashes]),
              let command = SecurityToolClaudeCodeSecretWriter.command(service: service, account: account, secret: data),
              command.count + commandHeadroomBytes <= SecurityToolClaudeCodeSecretWriter.maxCommandBytes else {
            return .unsupportedItem
        }
        return nil
    }

    /// Claude Code's own merge: the new pair, expiry and scopes replace the
    /// old ones, a known refresh-token expiry only moves earlier, and every
    /// other key in the item is kept as it was.
    static func merged(
        _ document: [String: Any],
        grant: ClaudeCodeTokenGrant,
        postedRefreshToken: String,
        issuedAt: Date
    ) -> [String: Any] {
        var document = document
        var oauth = document["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = grant.accessToken.rawValue
        oauth["refreshToken"] = grant.refreshToken?.rawValue ?? postedRefreshToken
        oauth["expiresAt"] = Int64((issuedAt.timeIntervalSince1970 + grant.expiresIn) * 1_000)
        if let scopes = grant.scopes, !scopes.isEmpty { oauth["scopes"] = scopes }
        if let existing = (oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value {
            if let seconds = grant.refreshTokenExpiresIn {
                oauth["refreshTokenExpiresAt"] = min(existing, Int64((issuedAt.timeIntervalSince1970 + seconds) * 1_000))
            }
        }
        document["claudeAiOauth"] = oauth
        return document
    }
}
