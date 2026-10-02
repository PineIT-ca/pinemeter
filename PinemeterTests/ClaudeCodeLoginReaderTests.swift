//
//  ClaudeCodeLoginReaderTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

/// Records calls per service and answers with a scripted result, so a test
/// can assert exactly which services were read and how many times.
private actor FakeClaudeCodeKeychainSecretReader: ClaudeCodeKeychainSecretReading {
    private var scripted: [String: ClaudeCodeSecretReadResult]
    private(set) var calls: [(service: String, account: String)] = []

    init(scripted: [String: ClaudeCodeSecretReadResult] = [:]) {
        self.scripted = scripted
    }

    func setResult(_ result: ClaudeCodeSecretReadResult, forService service: String) {
        scripted[service] = result
    }

    func readSecret(service: String, account: String) async -> ClaudeCodeSecretReadResult {
        calls.append((service: service, account: account))
        return scripted[service] ?? .notFound
    }

    func callCount(forService service: String) -> Int {
        calls.filter { $0.service == service }.count
    }
}

private struct FakeClaudeCodeKeychainItemLister: ClaudeCodeKeychainItemListing {
    let items: [ClaudeCodeKeychainItem]

    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem] {
        items
    }
}

final class ClaudeCodeLoginReaderTests: XCTestCase {
    // MARK: - keychainAccountName(environment:fallbackUserName:)

    func test_keychainAccountName_usesEnvironmentUSERWhenSafe() {
        XCTAssertEqual(
            ClaudeCodeLoginReader.keychainAccountName(environment: ["USER": "alice"], fallbackUserName: "x"),
            "alice"
        )
    }

    func test_keychainAccountName_fallsBackToFixedNameWhenUSERFailsSafeNameRegex() {
        XCTAssertEqual(
            ClaudeCodeLoginReader.keychainAccountName(environment: ["USER": "bad name"], fallbackUserName: "x"),
            "claude-code-user"
        )
    }

    func test_keychainAccountName_usesFallbackWhenNoUSER() {
        XCTAssertEqual(
            ClaudeCodeLoginReader.keychainAccountName(environment: [:], fallbackUserName: "fallback-name"),
            "fallback-name"
        )
    }

    // MARK: - isClaudeCodeService(_:)

    func test_isClaudeCodeService_acceptsDefaultAndSuffixedServices() {
        XCTAssertTrue(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code-credentials"))
        XCTAssertTrue(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code-credentials-0a1b2c3d"))
    }

    func test_isClaudeCodeService_rejectsUppercaseHexShortHexAndNonHexSuffixesAndBareName() {
        XCTAssertFalse(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code-credentials-0A1B2C3D"))
        XCTAssertFalse(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code-credentials-123"))
        XCTAssertFalse(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code-credentials-local-oauth"))
        XCTAssertFalse(ClaudeCodeLoginReader.isClaudeCodeService("Claude Code"))
    }

    // MARK: - SecurityToolClaudeCodeSecretReader

    func test_securityToolSecretReader_argumentsAndFixedExecutionShape() {
        XCTAssertEqual(
            SecurityToolClaudeCodeSecretReader.arguments(service: "S", account: "A"),
            ["find-generic-password", "-s", "S", "-a", "A", "-w"]
        )
        XCTAssertEqual(SecurityToolClaudeCodeSecretReader.executableURL.path, "/usr/bin/security")
        XCTAssertEqual(
            SecurityToolClaudeCodeSecretReader.environment,
            ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        )
    }

    // MARK: - decodeCredential(service:data:)

    func test_decodeCredential_decodesNarrowFieldsFromPlainJSON() throws {
        let json = Self.fullPayloadJSON()
        let credential = try XCTUnwrap(
            ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: json)
        )
        XCTAssertEqual(credential.accessToken.authorizationHeaderValue, "Bearer synthetic-access-token")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(credential.subscriptionType, "max")
        XCTAssertEqual(credential.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(credential.scopes, ["user:profile", "user:inference"])
    }

    func test_decodeCredential_decodesIdenticalCredentialFromHexEncoding() throws {
        let json = Self.fullPayloadJSON()
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let credential = try XCTUnwrap(
            ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: Data(hex.utf8))
        )
        XCTAssertEqual(credential.accessToken.authorizationHeaderValue, "Bearer synthetic-access-token")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(credential.subscriptionType, "max")
    }

    func test_decodeCredential_returnsNilForMissingOAuthPayload() {
        let json = Data(#"{"mcpOAuth": {}}"#.utf8)
        XCTAssertNil(ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: json))
    }

    func test_decodeCredential_returnsNilForBlankAccessToken() {
        let json = Data(#"{"claudeAiOauth": {"accessToken": "  ", "expiresAt": 1893456000000}}"#.utf8)
        XCTAssertNil(ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: json))
    }

    func test_decodeCredential_returnsNilForMissingExpiresAt() {
        let json = Data(#"{"claudeAiOauth": {"accessToken": "synthetic-access-token"}}"#.utf8)
        XCTAssertNil(ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: json))
    }

    func test_decodeCredential_returnsNilForNonJSONNonHexText() {
        let text = Data("not json and not hex!!".utf8)
        XCTAssertNil(ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: text))
    }

    func test_decodeCredential_returnsNilForEmptyData() {
        XCTAssertNil(ClaudeCodeLoginReader.decodeCredential(service: "Claude Code-credentials", data: Data()))
    }

    // MARK: - Mirror labels (decode surface)

    func test_decodeSurface_mirrorLabelsAreExactlyTheDocumentedFields() throws {
        let json = Self.fullPayloadJSON()
        let payload = try JSONDecoder().decode(ClaudeCodeLoginReader.CredentialPayload.self, from: json)

        let payloadMirror = Mirror(reflecting: payload)
        XCTAssertEqual(payloadMirror.children.map(\.label), [Optional("claudeAiOauth")])

        let oauthMirror = Mirror(reflecting: try XCTUnwrap(payload.claudeAiOauth))
        XCTAssertEqual(
            oauthMirror.children.map(\.label),
            [
                Optional("accessToken"),
                Optional("expiresAt"),
                Optional("subscriptionType"),
                Optional("rateLimitTier"),
                Optional("scopes"),
            ]
        )
    }

    // MARK: - readCredentials(now:)

    func test_readCredentials_withZeroListedItems_returnsEmptyAndMakesNoReads() async {
        let secretReader = FakeClaudeCodeKeychainSecretReader()
        let reader = ClaudeCodeLoginReader(
            itemLister: FakeClaudeCodeKeychainItemLister(items: []),
            secretReader: secretReader,
            preferredAccountName: "alice"
        )
        let credentials = await reader.readCredentials(now: Date())
        XCTAssertTrue(credentials.isEmpty)
        let callCount = await secretReader.calls.count
        XCTAssertEqual(callCount, 0)
    }

    func test_readCredentials_sortsWithUnsuffixedServiceFirst() async {
        let now = Date()
        let suffixedItem = ClaudeCodeKeychainItem(
            service: "Claude Code-credentials-0a1b2c3d",
            account: "alice",
            modificationDate: now
        )
        let defaultItem = ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "alice", modificationDate: now)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials-0a1b2c3d": .secret(Self.fullPayloadJSON()),
            "Claude Code-credentials": .secret(Self.fullPayloadJSON()),
        ])
        let reader = ClaudeCodeLoginReader(
            itemLister: FakeClaudeCodeKeychainItemLister(items: [suffixedItem, defaultItem]),
            secretReader: secretReader,
            preferredAccountName: "alice"
        )
        let credentials = await reader.readCredentials(now: now)
        XCTAssertEqual(credentials.map(\.service), ["Claude Code-credentials", "Claude Code-credentials-0a1b2c3d"])
    }

    func test_readCredentials_dropsSecretExpiringAtSixtySecondBoundaryKeepsOneSecondLater() async {
        // A whole-second instant keeps the millisecond `expiresAt` exact through
        // the JSON round trip; a live `Date()` lands on either side of the boundary.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiringAtBoundaryItem = ClaudeCodeKeychainItem(
            service: "Claude Code-credentials",
            account: "alice",
            modificationDate: now
        )
        let boundaryJSON = Self.fullPayloadJSON(
            expiresAtMilliseconds: now.addingTimeInterval(60).timeIntervalSince1970 * 1000
        )
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .secret(boundaryJSON),
        ])
        let reader = ClaudeCodeLoginReader(
            itemLister: FakeClaudeCodeKeychainItemLister(items: [expiringAtBoundaryItem]),
            secretReader: secretReader,
            preferredAccountName: "alice"
        )
        let droppedCredentials = await reader.readCredentials(now: now)
        XCTAssertTrue(droppedCredentials.isEmpty)

        let keptJSON = Self.fullPayloadJSON(
            expiresAtMilliseconds: now.addingTimeInterval(61).timeIntervalSince1970 * 1000
        )
        await secretReader.setResult(.secret(keptJSON), forService: "Claude Code-credentials")
        let keptCredentials = await reader.readCredentials(now: now)
        XCTAssertEqual(keptCredentials.count, 1)
    }

    func test_readCredentials_twoAccountsForOneService_onlyReadsPreferredAccount() async {
        let now = Date()
        let otherAccountItem = ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "other", modificationDate: now)
        let preferredAccountItem = ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "alice", modificationDate: now)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .secret(Self.fullPayloadJSON()),
        ])
        let reader = ClaudeCodeLoginReader(
            itemLister: FakeClaudeCodeKeychainItemLister(items: [otherAccountItem, preferredAccountItem]),
            secretReader: secretReader,
            preferredAccountName: "alice"
        )
        _ = await reader.readCredentials(now: now)
        let calls = await secretReader.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.account, "alice")
    }

    func test_readCredentials_itemWithUnsafeAccountName_isNeverRead() async {
        let now = Date()
        let unsafeItem = ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "has space", modificationDate: now)
        let secretReader = FakeClaudeCodeKeychainSecretReader()
        let reader = ClaudeCodeLoginReader(
            itemLister: FakeClaudeCodeKeychainItemLister(items: [unsafeItem]),
            secretReader: secretReader,
            preferredAccountName: "alice"
        )
        let credentials = await reader.readCredentials(now: now)
        XCTAssertTrue(credentials.isEmpty)
        let callCount = await secretReader.calls.count
        XCTAssertEqual(callCount, 0)
    }

    func test_readCredentials_timedOutServiceIsSkippedUntilModificationDateChanges() async {
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        let lister = MutableItemLister(service: "Claude Code-credentials", account: "alice", modificationDate: fixedDate)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .timedOut,
        ])
        let reader = ClaudeCodeLoginReader(itemLister: lister, secretReader: secretReader, preferredAccountName: "alice")

        _ = await reader.readCredentials(now: Date())
        _ = await reader.readCredentials(now: Date())
        let callCountSameDate = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callCountSameDate, 1)
    }

    func test_readCredentials_timedOutThenNewerModificationDate_readsAgain() async {
        let firstDate = Date(timeIntervalSince1970: 2_000_000)
        let newerDate = firstDate.addingTimeInterval(5)
        let lister = MutableItemLister(service: "Claude Code-credentials", account: "alice", modificationDate: firstDate)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .timedOut,
        ])
        let reader = ClaudeCodeLoginReader(itemLister: lister, secretReader: secretReader, preferredAccountName: "alice")

        _ = await reader.readCredentials(now: Date())
        _ = await reader.readCredentials(now: Date())
        let callsAtSameDate = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callsAtSameDate, 1)

        lister.modificationDate = newerDate
        await secretReader.setResult(.secret(Self.fullPayloadJSON()), forService: "Claude Code-credentials")
        _ = await reader.readCredentials(now: Date())
        let callsAfterDateChange = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callsAfterDateChange, 2)
    }

    func test_readCredentials_failedServiceIsSkippedUntilModificationDateChanges() async {
        // A user-denied Keychain approval dialog surfaces as `.failed` (a
        // non-zero exit other than 44), not `.timedOut`. It must back off
        // the same way, or a denial re-prompts on every single poll.
        let fixedDate = Date(timeIntervalSince1970: 3_000_000)
        let lister = MutableItemLister(service: "Claude Code-credentials", account: "alice", modificationDate: fixedDate)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .failed,
        ])
        let reader = ClaudeCodeLoginReader(itemLister: lister, secretReader: secretReader, preferredAccountName: "alice")

        _ = await reader.readCredentials(now: Date())
        _ = await reader.readCredentials(now: Date())
        let callCountSameDate = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callCountSameDate, 1)
    }

    func test_readCredentials_failedThenNewerModificationDate_readsAgain() async {
        let firstDate = Date(timeIntervalSince1970: 4_000_000)
        let newerDate = firstDate.addingTimeInterval(5)
        let lister = MutableItemLister(service: "Claude Code-credentials", account: "alice", modificationDate: firstDate)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .failed,
        ])
        let reader = ClaudeCodeLoginReader(itemLister: lister, secretReader: secretReader, preferredAccountName: "alice")

        _ = await reader.readCredentials(now: Date())
        _ = await reader.readCredentials(now: Date())
        let callsAtSameDate = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callsAtSameDate, 1)

        lister.modificationDate = newerDate
        await secretReader.setResult(.secret(Self.fullPayloadJSON()), forService: "Claude Code-credentials")
        _ = await reader.readCredentials(now: Date())
        let callsAfterDateChange = await secretReader.callCount(forService: "Claude Code-credentials")
        XCTAssertEqual(callsAfterDateChange, 2)
    }

    // MARK: - ClaudeCodeSecurityProcessRunner (system binaries only, never /usr/bin/security)

    func test_processRunner_timesOutAndChildIsNoLongerRunning() async {
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(0.3),
            maxOutputBytes: 4096
        )
        let start = Date()
        let result = await runner.run(arguments: ["10"])
        let elapsed = Date().timeIntervalSince(start)
        guard case .timedOut = result else {
            return XCTFail("Expected .timedOut, got \(result)")
        }
        XCTAssertLessThan(elapsed, 3)
    }

    func test_processRunner_echoReturnsSecretWithEchoedBytes() async {
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(5),
            maxOutputBytes: 4096
        )
        let result = await runner.run(arguments: ["hello-world"])
        guard case .secret(let data) = result else {
            return XCTFail("Expected .secret, got \(result)")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello-world")
    }

    func test_processRunner_yesWithSmallCap_returnsFailed() async {
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(5),
            maxOutputBytes: 4096
        )
        let result = await runner.run(arguments: [])
        guard case .failed = result else {
            return XCTFail("Expected .failed, got \(result)")
        }
    }

    func test_processRunner_cancelledTaskReturnsWithoutLeavingChildRunning() async {
        let runner = ClaudeCodeSecurityProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(10),
            maxOutputBytes: 4096
        )
        let task = Task<ClaudeCodeSecretReadResult, Never> {
            await runner.run(arguments: ["10"])
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.value
        // No assertion beyond "returns" is possible on the result value itself
        // (cancellation is a race with the subprocess launch), but reaching
        // this line proves `run(arguments:)` did not hang waiting on a
        // process that `withTaskCancellationHandler`'s `onCancel` should have
        // terminated.
    }

    // MARK: - Fixtures

    private static func fullPayloadJSON(expiresAtMilliseconds: Double = 1_893_456_000_000) -> Data {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "synthetic-access-token",
            "expiresAt": \(expiresAtMilliseconds),
            "refreshToken": "synthetic-refresh-token",
            "refreshTokenExpiresAt": 1893460000000,
            "rateLimitTier": "default_claude_max_20x",
            "scopes": ["user:profile", "user:inference"],
            "subscriptionType": "max"
          },
          "mcpOAuth": {
            "example-server": {
              "accessToken": "synthetic-mcp-access-token",
              "clientId": "synthetic-client-id"
            }
          }
        }
        """
        return Data(json.utf8)
    }
}

/// An item lister whose single item's modification date can be mutated
/// between calls, proving that `ClaudeCodeLoginReader`'s per-service
/// approval memory keys strictly off the item's current modification date.
private final class MutableItemLister: ClaudeCodeKeychainItemListing, @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private let account: String
    private var _modificationDate: Date

    init(service: String, account: String, modificationDate: Date) {
        self.service = service
        self.account = account
        self._modificationDate = modificationDate
    }

    var modificationDate: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _modificationDate
        }
        set {
            lock.lock()
            _modificationDate = newValue
            lock.unlock()
        }
    }

    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem] {
        [ClaudeCodeKeychainItem(service: service, account: account, modificationDate: modificationDate)]
    }
}
