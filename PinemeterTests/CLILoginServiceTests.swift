//
//  CLILoginServiceTests.swift
//  PinemeterTests
//
//  Covers `ClaudeCodeLoginPipeline.deduplicated` (dedup/ordering/expiry
//  rules), the pipeline composing a fake Keychain reader with a real
//  `ClaudeCodeOrganizationResolver` over a temp home, and
//  `CLILoginService.snapshot()`'s single-flight behavior. No test reads the
//  real Keychain, `~/.claude.json`, or `auth.json`, or calls a provider.
//

import Foundation
import XCTest
@testable import Pinemeter

/// Records calls per service and answers with a scripted result. Shape
/// mirrors `ClaudeCodeLoginReaderTests.FakeClaudeCodeKeychainSecretReader`
/// (declared privately here per the plan, so this file has no dependency on
/// that one).
private actor FakeClaudeCodeKeychainSecretReader: ClaudeCodeKeychainSecretReading {
    private var scripted: [String: ClaudeCodeSecretReadResult]
    private(set) var calls: [(service: String, account: String)] = []

    init(scripted: [String: ClaudeCodeSecretReadResult] = [:]) {
        self.scripted = scripted
    }

    func readSecret(service: String, account: String) async -> ClaudeCodeSecretReadResult {
        calls.append((service: service, account: account))
        return scripted[service] ?? .notFound
    }
}

private struct FakeClaudeCodeKeychainItemLister: ClaudeCodeKeychainItemListing {
    let items: [ClaudeCodeKeychainItem]

    func listClaudeCodeItems() -> [ClaudeCodeKeychainItem] {
        items
    }
}

/// Scripts `fetchProfileOrganization`; shape mirrors
/// `ClaudeCodeOrganizationResolverTests.FakeClaudeOAuthUsageService`,
/// declared privately here per the plan.
private actor FakeClaudeOAuthUsageService: ClaudeOAuthUsageServiceProtocol {
    enum Behavior {
        case success(ClaudeOAuthProfileOrganization)
        case throwError(Error)
    }

    private let behavior: Behavior
    private(set) var callCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        throw CLIUsageFetchError.invalidResponse
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        callCount += 1
        switch behavior {
        case .success(let organization):
            return organization
        case .throwError(let error):
            throw error
        }
    }
}

/// A `ClaudeCodeLoginSource` that counts calls and optionally sleeps before
/// answering, so a single-flight test can prove two overlapping `snapshot()`
/// calls share one underlying read.
private actor SlowCountingClaudeCodeLoginSource: ClaudeCodeLoginSource {
    private(set) var callCount = 0
    private let delay: Duration
    private let result: [ClaudeCodeLogin]

    init(delay: Duration, result: [ClaudeCodeLogin]) {
        self.delay = delay
        self.result = result
    }

    func logins(now: Date) async -> [ClaudeCodeLogin] {
        callCount += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return result
    }
}

final class CLILoginServiceTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // See ClaudeCodeOrganizationResolverTests: realpath(3), not
        // URL.resolvingSymlinksInPath(), so this never disagrees with
        // FileManager's own enumeration under /private/var.
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        let rawTempDir = NSTemporaryDirectory()
        let resolvedTempDir = realpath(rawTempDir, &buffer).map { String(cString: $0) } ?? rawTempDir
        tempHome = URL(fileURLWithPath: resolvedTempDir).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        try super.tearDownWithError()
    }

    // MARK: - ClaudeCodeLoginPipeline.deduplicated

    func test_deduplicated_keepsLatestExpiresAtForSameOrganization() {
        let now = Date()
        let organizationId = UUID()
        let older = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: now.addingTimeInterval(3600),
            service: "Claude Code-credentials-0a1b2c3d"
        )
        let newer = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: now.addingTimeInterval(7200),
            service: "Claude Code-credentials"
        )

        let result = ClaudeCodeLoginPipeline.deduplicated([older, newer], now: now)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.keychainService, "Claude Code-credentials")
        XCTAssertEqual(result.first?.expiresAt, newer.expiresAt)
    }

    func test_deduplicated_equalExpiresAtKeepsUnsuffixedOverSuffixed() {
        let now = Date()
        let organizationId = UUID()
        let expiresAt = now.addingTimeInterval(3600)
        let suffixed = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: expiresAt,
            service: "Claude Code-credentials-0a1b2c3d"
        )
        let unsuffixed = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: expiresAt,
            service: "Claude Code-credentials"
        )

        let result = ClaudeCodeLoginPipeline.deduplicated([suffixed, unsuffixed], now: now)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.keychainService, "Claude Code-credentials")
    }

    func test_deduplicated_equalExpiresAtTwoSuffixedKeepsLowerServiceName() {
        let now = Date()
        let organizationId = UUID()
        let expiresAt = now.addingTimeInterval(3600)
        let higher = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: expiresAt,
            service: "Claude Code-credentials-ffffffff"
        )
        let lower = ClaudeCodeLoginReaderFakeLogin(
            organizationId: organizationId,
            expiresAt: expiresAt,
            service: "Claude Code-credentials-00000000"
        )

        let result = ClaudeCodeLoginPipeline.deduplicated([higher, lower], now: now)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.keychainService, "Claude Code-credentials-00000000")
    }

    func test_deduplicated_dropsLoginExpiringAtSixtySecondBoundary() {
        let now = Date()
        let atBoundary = ClaudeCodeLoginReaderFakeLogin(
            organizationId: UUID(),
            expiresAt: now.addingTimeInterval(60),
            service: "Claude Code-credentials"
        )

        let result = ClaudeCodeLoginPipeline.deduplicated([atBoundary], now: now)

        XCTAssertTrue(result.isEmpty, "a login expiring at exactly the 60s skew boundary must be dropped")
    }

    func test_deduplicated_ordersOutputByOrganizationIdAscending() {
        let now = Date()
        let lowOrg = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
        let highOrg = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
        let first = ClaudeCodeLoginReaderFakeLogin(
            organizationId: highOrg,
            expiresAt: now.addingTimeInterval(3600),
            service: "Claude Code-credentials"
        )
        let second = ClaudeCodeLoginReaderFakeLogin(
            organizationId: lowOrg,
            expiresAt: now.addingTimeInterval(3600),
            service: "Claude Code-credentials-0a1b2c3d"
        )

        let result = ClaudeCodeLoginPipeline.deduplicated([first, second], now: now)

        XCTAssertEqual(result.map(\.organizationId), [lowOrg, highOrg])
    }

    func test_deduplicated_emptyInputReturnsEmptyOutput() {
        XCTAssertTrue(ClaudeCodeLoginPipeline.deduplicated([], now: Date()).isEmpty)
    }

    // MARK: - ClaudeCodeLoginPipeline.logins(now:)

    func test_pipeline_defaultServiceWithLocalConfig_returnsLoginWithOrganizationIdAndName() async throws {
        let organizationId = UUID()
        let configJSON = """
        {"oauthAccount":{"organizationUuid":"\(organizationId.uuidString)","organizationName":"Acme Org"}}
        """
        try configJSON.data(using: .utf8)!.write(to: tempHome.appendingPathComponent(".claude.json"))

        let secretJSON = Data(#"""
        {"claudeAiOauth":{"accessToken":"synthetic-access-token","expiresAt":\#(
            Int((Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000).rounded())
        ),"subscriptionType":"max"}}
        """#.utf8)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .secret(secretJSON),
        ])
        let itemLister = FakeClaudeCodeKeychainItemLister(items: [
            ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "tester", modificationDate: nil),
        ])
        let reader = ClaudeCodeLoginReader(
            itemLister: itemLister,
            secretReader: secretReader,
            preferredAccountName: "tester"
        )
        let profileService = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profileService)
        let pipeline = ClaudeCodeLoginPipeline(reader: reader, resolver: resolver)

        let logins = await pipeline.logins(now: Date())

        XCTAssertEqual(logins.count, 1)
        XCTAssertEqual(logins.first?.organizationId, organizationId)
        XCTAssertEqual(logins.first?.organizationName, "Acme Org")
        let profileCalls = await profileService.callCount
        XCTAssertEqual(profileCalls, 0, "a local config match must never fall back to the profile endpoint")
    }

    func test_pipeline_dropsCredentialWhoseOrganizationCannotBeResolved() async throws {
        // No `.claude.json` written in tempHome, so the local lookup misses;
        // the credential carries nil scopes, so the profile fallback runs
        // and this fake makes it throw, so the login is dropped entirely.
        let secretJSON = Data(#"""
        {"claudeAiOauth":{"accessToken":"synthetic-access-token","expiresAt":\#(
            Int((Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000).rounded())
        )}}
        """#.utf8)
        let secretReader = FakeClaudeCodeKeychainSecretReader(scripted: [
            "Claude Code-credentials": .secret(secretJSON),
        ])
        let itemLister = FakeClaudeCodeKeychainItemLister(items: [
            ClaudeCodeKeychainItem(service: "Claude Code-credentials", account: "tester", modificationDate: nil),
        ])
        let reader = ClaudeCodeLoginReader(
            itemLister: itemLister,
            secretReader: secretReader,
            preferredAccountName: "tester"
        )
        let profileService = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profileService)
        let pipeline = ClaudeCodeLoginPipeline(reader: reader, resolver: resolver)

        let logins = await pipeline.logins(now: Date())

        XCTAssertTrue(logins.isEmpty)
        let profileCalls = await profileService.callCount
        XCTAssertEqual(profileCalls, 1)
    }

    // MARK: - CLILoginService.snapshot() single-flight

    func test_snapshot_overlappingCalls_callSourceOnceAndReturnSameClaudeCount() async {
        let login = CLILoginReaderFake.claudeLogin(organizationId: UUID(), expiresIn: 3600)
        let source = SlowCountingClaudeCodeLoginSource(delay: .milliseconds(150), result: [login])
        let service = CLILoginService(codexEnvironment: [:], claudeSource: source)

        async let first = service.snapshot()
        async let second = service.snapshot()
        let (snapshotA, snapshotB) = await (first, second)

        XCTAssertEqual(snapshotA.claude.count, 1)
        XCTAssertEqual(snapshotB.claude.count, 1)
        let callCount = await source.callCount
        XCTAssertEqual(callCount, 1, "two overlapping snapshot() calls must share one underlying read")
    }

    func test_snapshot_sequentialCalls_callSourceOncePerCall() async {
        let login = CLILoginReaderFake.claudeLogin(organizationId: UUID(), expiresIn: 3600)
        let source = SlowCountingClaudeCodeLoginSource(delay: .zero, result: [login])
        let service = CLILoginService(codexEnvironment: [:], claudeSource: source)

        _ = await service.snapshot()
        _ = await service.snapshot()

        let callCount = await source.callCount
        XCTAssertEqual(callCount, 2, "two sequential snapshot() calls must each trigger their own read")
    }
}

/// Builds a synthetic `ClaudeCodeLogin` for the dedup/ordering tests, with a
/// fixed synthetic token -- never a real credential.
private func ClaudeCodeLoginReaderFakeLogin(
    organizationId: UUID,
    expiresAt: Date,
    service: String
) -> ClaudeCodeLogin {
    ClaudeCodeLogin(
        accessToken: CLIAccessToken("synthetic-access-token"),
        expiresAt: expiresAt,
        organizationId: organizationId,
        organizationName: "Org",
        subscriptionType: "max",
        keychainService: service
    )
}
