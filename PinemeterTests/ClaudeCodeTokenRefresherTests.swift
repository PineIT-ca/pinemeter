//
//  ClaudeCodeTokenRefresherTests.swift
//  PinemeterTests
//
//  Invariants for refreshing an expired Claude Code login in place (#236).
//  The CLI must never end up logged out by a concurrent refresh, a failed
//  refresh never corrupts or deletes the item, and no token leaves the
//  refresher's redacted types. Every token here is a synthetic placeholder.
//

import Foundation
import XCTest
@testable import Pinemeter

/// One in-memory Keychain shared by the fake reader and writer.
private actor FakeKeychain: ClaudeCodeKeychainSecretReading, ClaudeCodeKeychainSecretWriting {
    var items: [String: Data] = [:]
    var writeSucceeds = true
    var writes = 0
    var reads = 0
    /// Runs before the Nth read answers (1-based), to model a sibling write.
    var beforeRead: [Int: @Sendable (inout [String: Data]) -> Void] = [:]

    func set(_ service: String, _ data: Data) { items[service] = data }
    func setWriteSucceeds(_ value: Bool) { writeSucceeds = value }
    func onRead(_ index: Int, _ action: @escaping @Sendable (inout [String: Data]) -> Void) { beforeRead[index] = action }

    func readSecret(service: String, account: String) async -> ClaudeCodeSecretReadResult {
        reads += 1
        if let action = beforeRead[reads] { action(&items) }
        guard let data = items[service] else { return .notFound }
        return .secret(data)
    }

    func writeSecret(service: String, account: String, secret: Data) async -> Bool {
        writes += 1
        guard writeSucceeds else { return false }
        items[service] = Data(secret.map { String(format: "%02x", $0) }.joined().utf8)
        return true
    }
}

private actor FakeEndpoint: ClaudeCodeTokenEndpoint {
    var results: [ClaudeCodeTokenRefreshResult]
    var postedRefreshTokens: [String] = []
    var postedClientIds: [String] = []
    var onPost: (@Sendable () async -> Void)?

    init(_ results: [ClaudeCodeTokenRefreshResult]) { self.results = results }
    func setOnPost(_ action: @escaping @Sendable () async -> Void) { onPost = action }

    func refresh(refreshToken: ClaudeCodeSecretValue, clientId: String, scopes: [String]?) async -> ClaudeCodeTokenRefreshResult {
        postedRefreshTokens.append(refreshToken.rawValue)
        postedClientIds.append(clientId)
        await onPost?()
        return results.isEmpty ? .failed : results.removeFirst()
    }
}

final class ClaudeCodeTokenRefresherTests: XCTestCase {
    private static let service = "Claude Code-credentials-0a1b2c3d"
    private static let account = "tester"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresher-\(UUID().uuidString)/.claude_test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: Helpers

    private func item(modified: Date? = Date(timeIntervalSince1970: 1)) -> ClaudeCodeKeychainItem {
        ClaudeCodeKeychainItem(service: Self.service, account: Self.account, modificationDate: modified)
    }

    private func login(access: String, refresh: String, expiresAt: Date, extra: [String: Any] = [:]) -> Data {
        var oauth: [String: Any] = [
            "accessToken": access,
            "refreshToken": refresh,
            "expiresAt": Int64(expiresAt.timeIntervalSince1970 * 1_000),
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "refreshTokenExpiresAt": Int64(now.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1_000),
        ]
        oauth.merge(extra) { _, new in new }
        let document: [String: Any] = ["claudeAiOauth": oauth, "mcpOAuth": ["server|abc": ["accessToken": "FAKE-MCP"]]]
        return try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private var expiredLogin: Data {
        login(access: "FAKE-ACCESS-OLD", refresh: "FAKE-REFRESH-OLD", expiresAt: now.addingTimeInterval(-3_600))
    }

    private func grant(access: String = "FAKE-ACCESS-NEW", refresh: String? = "FAKE-REFRESH-NEW") -> ClaudeCodeTokenRefreshResult {
        .tokens(ClaudeCodeTokenGrant(
            accessToken: ClaudeCodeSecretValue(access),
            refreshToken: refresh.map(ClaudeCodeSecretValue.init),
            expiresIn: 28_800,
            refreshTokenExpiresIn: nil,
            scopes: nil
        ))
    }

    private func makeRefresher(_ keychain: FakeKeychain, _ endpoint: FakeEndpoint) -> ClaudeCodeTokenRefresher {
        let directory = directory!
        return ClaudeCodeTokenRefresher(
            secretReader: keychain,
            secretWriter: keychain,
            endpoint: endpoint,
            configDirectory: { _ in directory },
            sleep: { _ in }
        )
    }

    private func stored(_ keychain: FakeKeychain) async -> [String: Any] {
        let data = await keychain.items[Self.service]!
        return ClaudeCodeTokenRefresher.document(from: data)!
    }

    private func oauth(_ keychain: FakeKeychain) async -> [String: Any] {
        await stored(keychain)["claudeAiOauth"] as! [String: Any]
    }

    private func assertNoLocksLeft(file: StaticString = #filePath, line: UInt = #line) {
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent(".storage-write").path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: directory.resolvingSymlinksInPath().path + ".lock"), file: file, line: line)
    }

    // MARK: 1. Success writes the new pair and keeps every other key

    func test_expiredLogin_refreshesAndWritesPairBackKeepingOtherKeys() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let endpoint = FakeEndpoint([grant()])

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .refreshed)
        let postedTokens = await endpoint.postedRefreshTokens
        let postedClientIds = await endpoint.postedClientIds
        XCTAssertEqual(postedTokens, ["FAKE-REFRESH-OLD"])
        XCTAssertEqual(postedClientIds, [URLSessionClaudeCodeTokenEndpoint.defaultClientId])
        let oauth = await oauth(keychain)
        XCTAssertEqual(oauth["accessToken"] as? String, "FAKE-ACCESS-NEW")
        XCTAssertEqual(oauth["refreshToken"] as? String, "FAKE-REFRESH-NEW")
        XCTAssertEqual((oauth["expiresAt"] as? NSNumber)?.int64Value, Int64((now.timeIntervalSince1970 + 28_800) * 1_000))
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference", "user:profile"])
        let document = await stored(keychain)
        XCTAssertNotNil(document["mcpOAuth"], "other keys in the item must survive the write")
        assertNoLocksLeft()

        // The reader decodes the written item as a current login.
        let data = await keychain.items[Self.service]!
        let credential = ClaudeCodeLoginReader.decodeCredential(service: Self.service, data: data)
        XCTAssertNotNil(credential)
        XCTAssertFalse(credential!.isExpired(now: now))
    }

    func test_responseWithoutRefreshToken_keepsPostedRefreshToken() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let outcome = await makeRefresher(keychain, FakeEndpoint([grant(refresh: nil)])).refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(outcome, .refreshed)
        let refresh = await oauth(keychain)["refreshToken"] as? String
        XCTAssertEqual(refresh, "FAKE-REFRESH-OLD")
    }

    func test_storedClientId_isPosted() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, login(
            access: "FAKE-ACCESS-OLD", refresh: "FAKE-REFRESH-OLD",
            expiresAt: now.addingTimeInterval(-60), extra: ["clientId": "custom-client"]
        ))
        let endpoint = FakeEndpoint([grant()])
        _ = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)
        let clientIds = await endpoint.postedClientIds
        XCTAssertEqual(clientIds, ["custom-client"])
    }

    // MARK: 2. Not expired, or refreshed by a sibling before the POST

    func test_currentLogin_isNotTouched() async {
        let keychain = FakeKeychain()
        let fresh = login(access: "FAKE-ACCESS", refresh: "FAKE-REFRESH", expiresAt: now.addingTimeInterval(3_600))
        await keychain.set(Self.service, fresh)
        let endpoint = FakeEndpoint([grant()])
        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(outcome, .notNeeded)
        let posts = await endpoint.postedRefreshTokens.count
        let writes = await keychain.writes
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(writes, 0)
    }

    func test_siblingRefreshBeforeLockedReRead_adoptsWithoutPost() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let sibling = login(access: "FAKE-ACCESS-SIBLING", refresh: "FAKE-REFRESH-SIBLING", expiresAt: now.addingTimeInterval(28_800))
        await keychain.onRead(2) { $0[Self.service] = sibling }
        let endpoint = FakeEndpoint([grant()])

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .adopted)
        let posts = await endpoint.postedRefreshTokens.count
        let writes = await keychain.writes
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(writes, 0)
        let access = await oauth(keychain)["accessToken"] as? String
        XCTAssertEqual(access, "FAKE-ACCESS-SIBLING")
        assertNoLocksLeft()
    }

    // MARK: 3–4. Locks

    func test_heldRefreshLock_noPostNoWrite() async throws {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let lock = directory.appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let endpoint = FakeEndpoint([grant()])

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .lockBusy)
        let posts = await endpoint.postedRefreshTokens.count
        XCTAssertEqual(posts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "another holder's lock must stay")
    }

    func test_heldLegacyLock_releasesPrimaryAndDoesNotPost() async throws {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let legacy = URL(fileURLWithPath: directory.resolvingSymlinksInPath().path + ".lock")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let endpoint = FakeEndpoint([grant()])

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .lockBusy)
        let posts = await endpoint.postedRefreshTokens.count
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func test_staleRefreshLock_isTakenOver() async throws {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let lock = directory.appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: lock.path)

        let outcome = await makeRefresher(keychain, FakeEndpoint([grant()])).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .refreshed)
        assertNoLocksLeft()
    }

    // MARK: 5–6. invalid_grant

    func test_invalidGrantWithUnchangedItem_neverWritesAndBacksOffUntilItemChanges() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let endpoint = FakeEndpoint([.invalidGrant, grant()])
        let refresher = makeRefresher(keychain, endpoint)

        let first = await refresher.refreshIfExpired(item: item(), now: now)
        let second = await refresher.refreshIfExpired(item: item(), now: now.addingTimeInterval(86_400))

        XCTAssertEqual(first, .refreshTokenDead)
        XCTAssertEqual(second, .backingOff)
        let writes = await keychain.writes
        XCTAssertEqual(writes, 0)
        let data = await keychain.items[Self.service]
        XCTAssertEqual(data, expiredLogin, "a dead refresh token must leave the item byte-for-byte unchanged")

        let changed = await refresher.refreshIfExpired(item: item(modified: Date(timeIntervalSince1970: 2)), now: now)
        XCTAssertEqual(changed, .refreshed)
    }

    func test_invalidGrantAfterSiblingRotated_adoptsSiblingWithoutWrite() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let sibling = login(access: "FAKE-ACCESS-SIBLING", refresh: "FAKE-REFRESH-SIBLING", expiresAt: now.addingTimeInterval(28_800))
        let endpoint = FakeEndpoint([.invalidGrant])
        await endpoint.setOnPost { await keychain.set(Self.service, sibling) }

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .adopted)
        let writes = await keychain.writes
        XCTAssertEqual(writes, 0)
        let access = await oauth(keychain)["accessToken"] as? String
        XCTAssertEqual(access, "FAKE-ACCESS-SIBLING")
    }

    // MARK: 7–8. Compare-and-swap before the write

    func test_siblingWroteDifferentRefreshTokenAfterOurPost_isNeverOverwritten() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let sibling = login(access: "FAKE-ACCESS-SIBLING", refresh: "FAKE-REFRESH-SIBLING", expiresAt: now.addingTimeInterval(28_800))
        let endpoint = FakeEndpoint([grant()])
        await endpoint.setOnPost { await keychain.set(Self.service, sibling) }

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .adopted)
        let writes = await keychain.writes
        XCTAssertEqual(writes, 0)
        let data = await keychain.items[Self.service]
        XCTAssertEqual(data, sibling)
        assertNoLocksLeft()
    }

    func test_emptyStoredRefreshTokenAfterPost_isFilledWithOurs() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let blanked = login(access: "", refresh: "", expiresAt: Date(timeIntervalSince1970: 0))
        let endpoint = FakeEndpoint([grant()])
        await endpoint.setOnPost { await keychain.set(Self.service, blanked) }

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .refreshed)
        let refresh = await oauth(keychain)["refreshToken"] as? String
        XCTAssertEqual(refresh, "FAKE-REFRESH-NEW")
    }

    // MARK: 9. Write failure keeps the issued pair and retries safely

    func test_writeFailure_leavesItemUnchanged_thenRetriesPendingPairWithoutNewPost() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        await keychain.setWriteSucceeds(false)
        let endpoint = FakeEndpoint([grant()])
        let refresher = makeRefresher(keychain, endpoint)

        let first = await refresher.refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(first, .writeFailed)
        let unchanged = await keychain.items[Self.service]
        XCTAssertEqual(unchanged, expiredLogin)
        assertNoLocksLeft()

        await keychain.setWriteSucceeds(true)
        let second = await refresher.refreshIfExpired(item: item(), now: now.addingTimeInterval(60))
        XCTAssertEqual(second, .refreshed)
        let posts = await endpoint.postedRefreshTokens.count
        XCTAssertEqual(posts, 1, "the consumed refresh token must never be posted twice")
        let access = await oauth(keychain)["accessToken"] as? String
        XCTAssertEqual(access, "FAKE-ACCESS-NEW")
    }

    func test_pendingPairIsDroppedWhenSiblingWroteMeanwhile() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        await keychain.setWriteSucceeds(false)
        let refresher = makeRefresher(keychain, FakeEndpoint([grant()]))
        _ = await refresher.refreshIfExpired(item: item(), now: now)

        let sibling = login(access: "FAKE-ACCESS-SIBLING", refresh: "FAKE-REFRESH-SIBLING", expiresAt: now.addingTimeInterval(28_800))
        await keychain.set(Self.service, sibling)
        await keychain.setWriteSucceeds(true)
        let outcome = await refresher.refreshIfExpired(item: item(modified: Date(timeIntervalSince1970: 2)), now: now)

        XCTAssertEqual(outcome, .adopted)
        let data = await keychain.items[Self.service]
        XCTAssertEqual(data, sibling)
    }

    func test_pendingPairOlderThanItsAccessTokenIsStillCommittedNeverReposted() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        await keychain.setWriteSucceeds(false)
        let endpoint = FakeEndpoint([grant(), grant(access: "FAKE-ACCESS-2", refresh: "FAKE-REFRESH-2")])
        let refresher = makeRefresher(keychain, endpoint)
        _ = await refresher.refreshIfExpired(item: item(), now: now)

        await keychain.setWriteSucceeds(true)
        let later = await refresher.refreshIfExpired(item: item(), now: now.addingTimeInterval(86_400))

        XCTAssertEqual(later, .refreshed)
        let posted = await endpoint.postedRefreshTokens
        XCTAssertEqual(posted, ["FAKE-REFRESH-OLD"], "the consumed refresh token must never be posted again")
        let refresh = await oauth(keychain)["refreshToken"] as? String
        XCTAssertEqual(refresh, "FAKE-REFRESH-NEW")
    }

    func test_readBackMismatch_keepsPendingPair() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let original = expiredLogin
        // Reads: 1 initial, 2 under the refresh lock, 3 before the write,
        // 4 the read-back. The read-back sees the old item, as if the write
        // was silently lost.
        await keychain.onRead(4) { $0[Self.service] = original }
        let endpoint = FakeEndpoint([grant()])
        let refresher = makeRefresher(keychain, endpoint)

        let first = await refresher.refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(first, .writeFailed)
        let second = await refresher.refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(second, .refreshed)
        let posts = await endpoint.postedRefreshTokens.count
        XCTAssertEqual(posts, 1)
    }

    func test_otherLoginWithoutRefreshTokenAfterPost_isNotOverwritten() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        let other = login(access: "FAKE-ACCESS-OTHER", refresh: "", expiresAt: now.addingTimeInterval(3_600))
        let endpoint = FakeEndpoint([grant()])
        await endpoint.setOnPost { await keychain.set(Self.service, other) }

        let outcome = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)

        XCTAssertEqual(outcome, .adopted)
        let data = await keychain.items[Self.service]
        XCTAssertEqual(data, other)
    }

    func test_pendingPairIsNeverWrittenIntoAnItemWhoseLoginWasRemoved() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, expiredLogin)
        await keychain.setWriteSucceeds(false)
        let refresher = makeRefresher(keychain, FakeEndpoint([grant()]))
        _ = await refresher.refreshIfExpired(item: item(), now: now)

        let loggedOut = try! JSONSerialization.data(withJSONObject: ["mcpOAuth": [:] as [String: Any]], options: [.sortedKeys])
        await keychain.set(Self.service, loggedOut)
        await keychain.setWriteSucceeds(true)
        let outcome = await refresher.refreshIfExpired(item: item(modified: Date(timeIntervalSince1970: 2)), now: now)

        XCTAssertEqual(outcome, .adopted)
        let data = await keychain.items[Self.service]
        XCTAssertEqual(data, loggedOut)
    }

    // MARK: 10. Transient failures

    func test_transientAndMalformedFailures_neverWriteAndBackOff() async {
        for result: ClaudeCodeTokenRefreshResult in [.retryLater(retryAfter: 120), .failed] {
            let keychain = FakeKeychain()
            await keychain.set(Self.service, expiredLogin)
            let endpoint = FakeEndpoint([result, grant()])
            let refresher = makeRefresher(keychain, endpoint)

            let first = await refresher.refreshIfExpired(item: item(), now: now)
            let second = await refresher.refreshIfExpired(item: item(), now: now.addingTimeInterval(30))

            XCTAssertEqual(first, .requestFailed)
            XCTAssertEqual(second, .backingOff)
            let writes = await keychain.writes
            XCTAssertEqual(writes, 0)
            let data = await keychain.items[Self.service]
            XCTAssertEqual(data, expiredLogin)
            assertNoLocksLeft()
        }
    }

    func test_classify_mapsStatusesAndRejectsMalformedGrant() {
        let ok = Data(#"{"access_token":"FAKE-A","refresh_token":"FAKE-R","expires_in":28800,"scope":"user:inference user:profile"}"#.utf8)
        guard case .tokens(let parsed) = URLSessionClaudeCodeTokenEndpoint.classify(status: 200, headers: nil, body: ok) else {
            return XCTFail("expected tokens")
        }
        XCTAssertEqual(parsed.scopes, ["user:inference", "user:profile"])
        guard case .failed = URLSessionClaudeCodeTokenEndpoint.classify(status: 200, headers: nil, body: Data(#"{"access_token":""}"#.utf8)) else {
            return XCTFail("a grant without a token or expiry must not be written")
        }
        guard case .invalidGrant = URLSessionClaudeCodeTokenEndpoint.classify(status: 400, headers: nil, body: Data(#"{"error":"invalid_grant"}"#.utf8)) else {
            return XCTFail("expected invalid_grant")
        }
        guard case .failed = URLSessionClaudeCodeTokenEndpoint.classify(status: 400, headers: nil, body: Data(#"{"error":"invalid_scope"}"#.utf8)) else {
            return XCTFail("expected failed")
        }
        guard case .retryLater = URLSessionClaudeCodeTokenEndpoint.classify(status: 503, headers: nil, body: Data()) else {
            return XCTFail("expected retryLater")
        }
        guard case .failed = URLSessionClaudeCodeTokenEndpoint.classify(status: 307, headers: nil, body: Data()) else {
            return XCTFail("a redirect must never be followed or treated as success")
        }
    }

    // MARK: 11. The write keeps secrets off argv

    func test_writeCommand_usesStdinOnly() {
        XCTAssertEqual(SecurityToolClaudeCodeSecretWriter.arguments, ["-i"])
        let secret = Data(#"{"claudeAiOauth":{"accessToken":"FAKE-A"}}"#.utf8)
        let command = SecurityToolClaudeCodeSecretWriter.command(service: Self.service, account: Self.account, secret: secret)
        let text = String(data: command!, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("add-generic-password -U -a \"tester\" -s \"\(Self.service)\" -X \""))
        XCTAssertTrue(text.hasSuffix("\"\n"))
        XCTAssertFalse(text.contains("FAKE-A"), "the secret travels hex-encoded")
        XCTAssertNil(SecurityToolClaudeCodeSecretWriter.command(service: Self.service, account: "bad\" name", secret: secret))
        XCTAssertNil(SecurityToolClaudeCodeSecretWriter.command(service: "Other-service", account: Self.account, secret: secret))
        XCTAssertNil(SecurityToolClaudeCodeSecretWriter.command(
            service: Self.service, account: Self.account, secret: Data(repeating: 0x41, count: 4_000)
        ))
    }

    // MARK: 12. Redaction

    func test_secretValuesNeverPrint() {
        let value = ClaudeCodeSecretValue("FAKE-SECRET")
        XCTAssertFalse(String(describing: value).contains("FAKE-SECRET"))
        XCTAssertFalse(String(reflecting: value).contains("FAKE-SECRET"))
        XCTAssertFalse(String(describing: grant()).contains("FAKE-ACCESS-NEW"))
    }

    // MARK: 13. Items this app must not touch

    func test_unsupportedItems_areNeverRefreshed() async {
        let keychain = FakeKeychain()
        await keychain.set(Self.service, login(access: "FAKE-A", refresh: "", expiresAt: now.addingTimeInterval(-60)))
        let endpoint = FakeEndpoint([grant()])
        let refresher = makeRefresher(keychain, endpoint)
        let noRefresh = await refresher.refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(noRefresh, .noRefreshToken)

        let unsafe = await refresher.refreshIfExpired(
            item: ClaudeCodeKeychainItem(service: Self.service, account: "bad name", modificationDate: nil), now: now
        )
        XCTAssertEqual(unsafe, .unsupportedItem)

        let noDirectory = ClaudeCodeTokenRefresher(
            secretReader: keychain, secretWriter: keychain, endpoint: endpoint, configDirectory: { _ in nil }, sleep: { _ in }
        )
        await keychain.set(Self.service, expiredLogin)
        let unplaced = await noDirectory.refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(unplaced, .unsupportedItem)

        await keychain.set(Self.service, login(
            access: "FAKE-A", refresh: "FAKE-R", expiresAt: now.addingTimeInterval(-60),
            extra: ["refreshTokenExpiresAt": Int64(now.addingTimeInterval(-1).timeIntervalSince1970 * 1_000)]
        ))
        let deadByExpiry = await makeRefresher(keychain, endpoint).refreshIfExpired(item: item(), now: now)
        XCTAssertEqual(deadByExpiry, .refreshTokenDead)

        let posts = await endpoint.postedRefreshTokens.count
        let writes = await keychain.writes
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(writes, 0)
    }

    func test_merged_onlyMovesKnownRefreshExpiryEarlier() {
        let existing = Int64(now.addingTimeInterval(100).timeIntervalSince1970 * 1_000)
        let document: [String: Any] = ["claudeAiOauth": ["refreshTokenExpiresAt": existing, "accessToken": "FAKE-OLD"]]
        let later = ClaudeCodeTokenGrant(
            accessToken: ClaudeCodeSecretValue("FAKE-NEW"), refreshToken: nil, expiresIn: 60,
            refreshTokenExpiresIn: 10_000, scopes: nil
        )
        let merged = ClaudeCodeTokenRefresher.merged(document, grant: later, postedRefreshToken: "FAKE-R", issuedAt: now)
        let oauth = merged["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual((oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value, existing)
    }

    func test_configDirectory_matchesOnlyExistingHashedDirectories() throws {
        let home = directory.deletingLastPathComponent()
        let suffix = ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: home.path + "/.claude_test")
        XCTAssertEqual(
            ClaudeCodeOrganizationResolver.configDirectory(forService: "Claude Code-credentials-\(suffix)", homeDirectory: home)?.path,
            home.path + "/.claude_test"
        )
        XCTAssertNil(ClaudeCodeOrganizationResolver.configDirectory(forService: "Claude Code-credentials-00000000", homeDirectory: home))
        XCTAssertNil(ClaudeCodeOrganizationResolver.configDirectory(forService: "Claude Code-credentials", homeDirectory: home))
    }

    // MARK: Default session refuses redirects (#243)

    func test_defaultSession_neverFollowsARedirectThatWouldResendTheRefreshToken() async {
        RedirectingTokenURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingTokenURLProtocol.self]
        let endpoint = URLSessionClaudeCodeTokenEndpoint(configuration: configuration)

        let result = await endpoint.refresh(
            refreshToken: ClaudeCodeSecretValue("FAKE-REFRESH"), clientId: "client", scopes: nil
        )

        guard case .failed = result else { return XCTFail("a 307 must classify as failed") }
        XCTAssertEqual(RedirectingTokenURLProtocol.requestedHosts(), ["platform.claude.com"])
    }

    /// Control: without the endpoint's delegate the same stub is followed,
    /// so the test above proves the delegate, not the stub.
    func test_redirectStub_isFollowedBySessionWithoutTheDelegate() async throws {
        RedirectingTokenURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingTokenURLProtocol.self]
        var request = URLRequest(url: URLSessionClaudeCodeTokenEndpoint.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        _ = try await URLSession(configuration: configuration).data(for: request)

        XCTAssertEqual(RedirectingTokenURLProtocol.requestedHosts(), ["platform.claude.com", "redirect.invalid"])
    }

    // MARK: Pipeline refreshes, then re-reads (#243)

    func test_pipeline_refreshesExpiredItemThenReturnsTheNewLogin() async throws {
        let home = directory.deletingLastPathComponent()
        let organization = UUID()
        try Data(#"{"oauthAccount":{"organizationUuid":"\#(organization.uuidString)"}}"#.utf8)
            .write(to: directory.appendingPathComponent(".claude.json"))
        let service = "Claude Code-credentials-"
            + ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: home.path + "/.claude_test")
        let item = ClaudeCodeKeychainItem(service: service, account: Self.account, modificationDate: Date(timeIntervalSince1970: 1))

        let keychain = FakeKeychain()
        await keychain.set(service, login(
            access: "FAKE-ACCESS-OLD", refresh: "FAKE-REFRESH-OLD", expiresAt: Date().addingTimeInterval(-3_600)
        ))
        let endpoint = FakeEndpoint([grant()])
        let reader = ClaudeCodeLoginReader(
            itemLister: StaticItemLister(items: [item]),
            secretReader: keychain,
            preferredAccountName: Self.account
        )
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: home, profileService: NoProfileService())
        let configDirectory = directory!
        let refresher = ClaudeCodeTokenRefresher(
            secretReader: keychain, secretWriter: keychain, endpoint: endpoint,
            configDirectory: { _ in configDirectory }, sleep: { _ in }
        )

        let withoutRefresher = await ClaudeCodeLoginPipeline(reader: reader, resolver: resolver).logins(now: Date())
        XCTAssertTrue(withoutRefresher.isEmpty, "an expired login is not offered without a refresher")

        let logins = await ClaudeCodeLoginPipeline(reader: reader, resolver: resolver, refresher: refresher)
            .logins(now: Date())

        XCTAssertEqual(logins.count, 1)
        XCTAssertEqual(logins.first?.organizationId, organization)
        XCTAssertEqual(logins.first?.accessToken.authorizationHeaderValue, "Bearer FAKE-ACCESS-NEW")
        XCTAssertEqual(logins.first?.keychainService, service)
        let posts = await endpoint.postedRefreshTokens
        XCTAssertEqual(posts, ["FAKE-REFRESH-OLD"])
    }
}

private struct StaticItemLister: ClaudeCodeKeychainItemListing {
    let items: [ClaudeCodeKeychainItem]
    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem] { items }
}

private struct NoProfileService: ClaudeOAuthUsageServiceProtocol {
    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData { throw CLIUsageFetchError.invalidResponse }
    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        throw CLIUsageFetchError.invalidResponse
    }
}

/// Answers the token host with a 307 to another host, and that host with an
/// empty 200. Records the host of every request it serves.
private final class RedirectingTokenURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static func reset() { lock.withLock { hosts = [] } }
    static func requestedHosts() -> [String] { lock.withLock { hosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.hosts.append(url.host ?? "") }
        if url.host == "platform.claude.com" {
            let target = URL(string: "https://redirect.invalid/v1/oauth/token")!
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
