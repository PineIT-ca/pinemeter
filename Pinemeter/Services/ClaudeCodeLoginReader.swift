//
//  ClaudeCodeLoginReader.swift
//  Pinemeter
//
//  Reads Claude Code's own login Keychain items (`Claude Code-credentials` and
//  `Claude Code-credentials-<8 hex>`) so Pinemeter can poll Claude usage the
//  same way Claude Code itself does (CLI-02). Items are enumerated by
//  attributes only -- no secret data is requested at that step, so
//  enumeration never raises a Keychain dialog (RESEARCH F-K7). Each secret is
//  then read through `/usr/bin/security`, the same tool Claude Code itself
//  uses to write the item (RESEARCH F-K2): that read is already trusted by
//  the item's access-control list and raises no dialog either. Only
//  `claudeAiOauth.accessToken`, `expiresAt`, `subscriptionType`,
//  `rateLimitTier`, and `scopes` are ever decoded into a property; the
//  refresh token and the per-MCP-server OAuth entries carried in the same
//  item are never decoded into anything this reader keeps (D-06). Nothing in
//  this file writes, updates, or deletes a Keychain item (D-02, D-07), and no
//  token ever enters a subprocess argument, environment variable, or log line
//  (D-08).
//
//  If a read hangs waiting on an unanswered Keychain approval dialog (an item
//  not originally created by `/usr/bin/security`, RESEARCH Pitfall 13), the
//  bounded subprocess below terminates it after a fixed timeout and this
//  reader remembers that service as needing approval until its modification
//  date changes, so it never stacks a second dialog on top of the first.
//

import Darwin
import Foundation

/// One Claude Code Keychain item, identified by attributes only -- no secret
/// data has been read yet.
struct ClaudeCodeKeychainItem: Equatable, Sendable {
    let service: String
    let account: String
    let modificationDate: Date?
}

/// A source of `Claude Code-credentials*` Keychain item attributes. The
/// production implementation enumerates with no data-return key so the call
/// never raises a dialog; tests supply a fake so no test ever touches the
/// developer's real login Keychain.
protocol ClaudeCodeKeychainItemListing: Sendable {
    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem]
}

/// The outcome of reading one Keychain item's secret through the trusted
/// tool.
enum ClaudeCodeSecretReadResult: Sendable {
    case secret(Data)
    case notFound
    case timedOut
    case failed
}

/// A source of one Keychain item's secret bytes, by service and account
/// name. The production implementation shells out to the trusted tool; tests
/// supply a fake so no test ever reads a real secret.
protocol ClaudeCodeKeychainSecretReading: Sendable {
    func readSecret(service: String, account: String) async -> ClaudeCodeSecretReadResult
}

/// Enumerates every generic-password item's attributes with one query and no
/// data-return key, so the call completes without prompting the user, then
/// keeps only the items whose service name matches Claude Code's own naming.
struct SecurityFrameworkClaudeCodeItemLister: ClaudeCodeKeychainItemListing {
    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { attributes -> ClaudeCodeKeychainItem? in
            guard let service = attributes[kSecAttrService as String] as? String,
                  ClaudeCodeLoginReader.isClaudeCodeService(service) else {
                return nil
            }
            let account = attributes[kSecAttrAccount as String] as? String ?? ""
            let modificationDate = attributes[kSecAttrModificationDate as String] as? Date
            return ClaudeCodeKeychainItem(service: service, account: account, modificationDate: modificationDate)
        }
    }
}

/// A bounded, cancellable launch of one fixed executable with a fixed
/// argument list, used to read a Keychain secret without ever letting an
/// unanswered approval dialog block indefinitely. Shape mirrors
/// `RemoteSSHTransport`'s subprocess handling: stdin/stderr are discarded,
/// stdout is drained under a byte cap, and the process is terminated on
/// either a timeout or task cancellation.
struct ClaudeCodeSecurityProcessRunner: Sendable {
    let executableURL: URL
    let environment: [String: String]
    let timeout: Duration
    let maxOutputBytes: Int

    init(executableURL: URL, environment: [String: String], timeout: Duration, maxOutputBytes: Int) {
        self.executableURL = executableURL
        self.environment = environment
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    func run(arguments: [String]) async -> ClaudeCodeSecretReadResult {
        let process = Process()
        let outputPipe = Pipe()
        let termination = ClaudeCodeSecurityProcessTermination()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { task in
            termination.finish(status: task.terminationStatus, reason: task.terminationReason)
        }

        let cap = maxOutputBytes
        let stdoutTask = Task.detached(priority: .utility) { () throws -> Data in
            try Self.drain(outputPipe.fileHandleForReading, limit: cap, process: process)
        }

        do {
            try process.run()
        } catch {
            _ = try? await stdoutTask.value
            return .failed
        }
        try? outputPipe.fileHandleForWriting.close()

        do {
            let exit = try await withTaskCancellationHandler(
                operation: { try await waitForExit(process, termination: termination) },
                onCancel: { process.terminate() }
            )
            let output = try await stdoutTask.value
            if exit.reason == .exit, exit.status == 0, !output.isEmpty {
                return .secret(output)
            } else if exit.reason == .exit, exit.status == 44 {
                return .notFound
            } else {
                return .failed
            }
        } catch is CancellationError {
            await stop(process)
            _ = try? await stdoutTask.value
            return .failed
        } catch is ClaudeCodeProcessTimeoutError {
            await stop(process)
            _ = try? await stdoutTask.value
            return .timedOut
        } catch {
            await stop(process)
            return .failed
        }
    }

    private func waitForExit(
        _ process: Process,
        termination: ClaudeCodeSecurityProcessTermination
    ) async throws -> ClaudeCodeSecurityProcessExit {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            if Task.isCancelled { throw CancellationError() }
            if clock.now >= deadline { throw ClaudeCodeProcessTimeoutError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await termination.wait()
    }

    private func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        await Task.detached(priority: .utility) {
            _ = usleep(100_000)
        }.value
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func drain(_ handle: FileHandle, limit: Int, process: Process) throws -> Data {
        var output = Data()
        while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
            guard output.count <= limit - chunk.count else {
                process.terminate()
                throw ClaudeCodeOutputTooLargeError()
            }
            output.append(chunk)
        }
        return output
    }
}

private struct ClaudeCodeProcessTimeoutError: Error {}
private struct ClaudeCodeOutputTooLargeError: Error {}

private struct ClaudeCodeSecurityProcessExit: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
}

private final class ClaudeCodeSecurityProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ClaudeCodeSecurityProcessExit?
    private var continuation: CheckedContinuation<ClaudeCodeSecurityProcessExit, Never>?

    func finish(status: Int32, reason: Process.TerminationReason) {
        let exit = ClaudeCodeSecurityProcessExit(status: status, reason: reason)
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = exit
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: exit)
    }

    func wait() async -> ClaudeCodeSecurityProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Reads one Keychain item's secret through the fixed-argv, fixed-environment
/// tool Claude Code itself writes with, so the read is already trusted by the
/// item's access-control list.
struct SecurityToolClaudeCodeSecretReader: ClaudeCodeKeychainSecretReading {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/security")
    static let environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    static let timeout: Duration = .seconds(5)
    static let maxOutputBytes = 262_144

    static func arguments(service: String, account: String) -> [String] {
        ["find-generic-password", "-s", service, "-a", account, "-w"]
    }

    func readSecret(service: String, account: String) async -> ClaudeCodeSecretReadResult {
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: Self.executableURL,
            environment: Self.environment,
            timeout: Self.timeout,
            maxOutputBytes: Self.maxOutputBytes
        )
        return await runner.run(arguments: Self.arguments(service: service, account: account))
    }
}

/// Enumerates `Claude Code-credentials*` Keychain items, reads each secret
/// through the trusted tool, and decodes only the narrow set of fields this
/// app needs. Dialog backoff is remembered per service for the life of the
/// app process only (`approvalNeeded`), never persisted.
actor ClaudeCodeLoginReader {
    private let itemLister: any ClaudeCodeKeychainItemListing
    private let secretReader: any ClaudeCodeKeychainSecretReading
    private let preferredAccountName: String
    private var approvalNeeded: [String: Date?] = [:]

    init(
        itemLister: any ClaudeCodeKeychainItemListing = SecurityFrameworkClaudeCodeItemLister(),
        secretReader: any ClaudeCodeKeychainSecretReading = SecurityToolClaudeCodeSecretReader(),
        preferredAccountName: String = ClaudeCodeLoginReader.keychainAccountName()
    ) {
        self.itemLister = itemLister
        self.secretReader = secretReader
        self.preferredAccountName = preferredAccountName
    }

    /// The Keychain account name Claude Code itself writes items under:
    /// `USER` (or the supplied fallback) when it matches
    /// `^[a-zA-Z0-9._-]+$`, else a fixed fallback account name (RESEARCH
    /// F-K4, verified against the Claude Code 2.1.280 binary).
    static func keychainAccountName(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackUserName: String = NSUserName()
    ) -> String {
        let name = environment["USER"] ?? fallbackUserName
        guard name.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            return "claude-code-user"
        }
        return name
    }

    /// `true` for the default service name or the default name plus a dash
    /// and exactly eight lowercase hex characters -- Claude Code's own
    /// per-config-directory suffix shape.
    static func isClaudeCodeService(_ service: String) -> Bool {
        let defaultService = "Claude Code-credentials"
        guard service != defaultService else { return true }
        let prefix = defaultService + "-"
        guard service.hasPrefix(prefix) else { return false }
        let suffix = String(service.dropFirst(prefix.count))
        return suffix.range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }

    /// Decodes one item's secret bytes into the narrow credential this app
    /// keeps. Accepts either the secret's plain JSON text or an even-length
    /// lowercase-hex encoding of that JSON's UTF-8 bytes, trimmed of
    /// surrounding whitespace first. Returns `nil` for anything that is not
    /// one of those two shapes, has no OAuth payload, has a blank access
    /// token, or is missing its expiry. The local copy of the secret bytes is
    /// zeroed before returning, win or lose.
    static func decodeCredential(service: String, data: Data) -> ClaudeCodeKeychainCredential? {
        var secretBytes = data
        defer {
            if !secretBytes.isEmpty { secretBytes.resetBytes(in: 0..<secretBytes.count) }
        }

        guard let text = String(data: secretBytes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var jsonData: Data
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8) else { return nil }
            jsonData = data
        } else {
            guard let decoded = hexDecodedData(trimmed) else { return nil }
            jsonData = decoded
        }
        defer {
            if !jsonData.isEmpty { jsonData.resetBytes(in: 0..<jsonData.count) }
        }

        guard let payload = try? JSONDecoder().decode(CredentialPayload.self, from: jsonData),
              let oauth = payload.claudeAiOauth else {
            return nil
        }

        let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        guard let expiresAtMilliseconds = oauth.expiresAt else { return nil }

        return ClaudeCodeKeychainCredential(
            service: service,
            accessToken: CLIAccessToken(token),
            expiresAt: Date(timeIntervalSince1970: expiresAtMilliseconds / 1000),
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier,
            scopes: oauth.scopes
        )
    }

    /// The decode target for a secret's JSON payload. No field exists for
    /// the refresh token, its own expiry, or the per-MCP-server OAuth
    /// entries the same item carries -- Decodable synthesis ignores JSON
    /// keys with no matching property, so those values never reach memory
    /// through this type.
    struct CredentialPayload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
            let scopes: [String]?
        }

        let claudeAiOauth: OAuth?
    }

    private static func hexDecodedData(_ text: String) -> Data? {
        guard !text.isEmpty, text.count % 2 == 0,
              text.range(of: #"^[0-9a-f]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func isSafeAccountName(_ account: String) -> Bool {
        account.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Lists every current item, keeps one item per service (the preferred
    /// account when present, else the lowest account name), skips a service
    /// still waiting on an unanswered approval dialog at the same
    /// modification date, reads each remaining secret through the trusted
    /// tool, decodes it, and drops anything expired. Returned in ascending
    /// service-name order, so the unsuffixed default service comes first.
    func readCredentials(now: Date) async -> [ClaudeCodeKeychainCredential] {
        let items = itemLister.listClaudeCodeItems()
            .filter { Self.isClaudeCodeService($0.service) }
            .filter { Self.isSafeAccountName($0.account) }

        var itemsByService: [String: [ClaudeCodeKeychainItem]] = [:]
        for item in items {
            itemsByService[item.service, default: []].append(item)
        }

        var selected: [ClaudeCodeKeychainItem] = []
        for serviceItems in itemsByService.values {
            if let preferred = serviceItems.first(where: { $0.account == preferredAccountName }) {
                selected.append(preferred)
            } else if let fallback = serviceItems.min(by: { $0.account < $1.account }) {
                selected.append(fallback)
            }
        }
        selected.sort { $0.service < $1.service }

        var credentials: [ClaudeCodeKeychainCredential] = []
        for item in selected {
            if let remembered = approvalNeeded[item.service], remembered == item.modificationDate {
                continue
            }

            let result = await secretReader.readSecret(service: item.service, account: item.account)
            switch result {
            case .secret(let data):
                approvalNeeded.removeValue(forKey: item.service)
                if let credential = Self.decodeCredential(service: item.service, data: data),
                   !credential.isExpired(now: now) {
                    credentials.append(credential)
                }
            case .notFound:
                approvalNeeded.removeValue(forKey: item.service)
            case .timedOut, .failed:
                // A denied Keychain approval dialog surfaces as `.failed`
                // (a non-zero exit other than 44), not `.timedOut` -- back
                // off the same way so a denial does not re-prompt on every
                // single poll. Remembered until the item's modification date
                // changes, same as a timeout.
                approvalNeeded.updateValue(item.modificationDate, forKey: item.service)
            }
        }
        return credentials
    }
}
