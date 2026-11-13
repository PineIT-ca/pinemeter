//
//  ClaudeCodeOrganizationResolverTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class ClaudeCodeOrganizationResolverTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Resolve the real (non-/private-stripped) path with realpath(3)
        // before appending anything: NSTemporaryDirectory() lives under the
        // symlinked /var on macOS, `URL.resolvingSymlinksInPath()` special-
        // cases /var/tmp/etc back to their unresolved form, but
        // FileManager's own directory enumeration later returns the fully
        // resolved /private/var form. An unresolved base here would make
        // every computed hash suffix disagree with the resolver's own
        // enumeration (same class of bug as 14-mac-ssh-push's t.TempDir()
        // fix, applied with realpath(3) since URL's own resolver does not
        // produce the same answer FileManager's enumeration does).
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

    // MARK: - Helpers

    private func writeConfig(
        organizationUuid: String,
        organizationName: String,
        email: String = "user@example.com",
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"oauthAccount":{"organizationUuid":"\(organizationUuid)","organizationName":"\(organizationName)","emailAddress":"\(email)"}}
        """
        try json.data(using: .utf8)!.write(to: directory.appendingPathComponent(".claude.json"))
    }

    private func makeCredential(
        service: String = "Claude Code-credentials",
        scopes: [String]? = nil,
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) -> ClaudeCodeKeychainCredential {
        ClaudeCodeKeychainCredential(
            service: service,
            accessToken: CLIAccessToken("synthetic-access-token"),
            expiresAt: expiresAt,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            scopes: scopes
        )
    }

    // MARK: - configDirectoryHashSuffix (RESEARCH F-K3 vectors)

    func test_configDirectoryHashSuffix_matchesKnownVectors() {
        XCTAssertEqual(
            ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: "/Users/example/.claude"),
            "402b469b"
        )
        XCTAssertEqual(
            ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: "/Users/example/.claude-work"),
            "dd1118a7"
        )
    }

    // MARK: - organization(fromConfigData:)

    func test_organizationFromConfigData_decodesUUIDCaseInsensitivelyAndName() {
        let data = #"""
        {"oauthAccount":{"organizationUuid":"00000000-0000-0000-0000-0000000000C1","organizationName":"Example Org","emailAddress":"user@example.com"}}
        """#.data(using: .utf8)!

        let organization = ClaudeCodeOrganizationResolver.organization(fromConfigData: data)

        XCTAssertEqual(organization?.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000c1"))
        XCTAssertEqual(organization?.name, "Example Org")
    }

    func test_organizationFromConfigData_missingOAuthAccount_returnsNil() {
        let data = "{}".data(using: .utf8)!
        XCTAssertNil(ClaudeCodeOrganizationResolver.organization(fromConfigData: data))
    }

    func test_organizationFromConfigData_missingOrInvalidOrganizationUuid_returnsNil() {
        let missingUuid = #"{"oauthAccount":{"organizationName":"Example Org"}}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeCodeOrganizationResolver.organization(fromConfigData: missingUuid))

        let invalidUuid = #"{"oauthAccount":{"organizationUuid":"not-a-uuid"}}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeCodeOrganizationResolver.organization(fromConfigData: invalidUuid))
    }

    // MARK: - Default (unsuffixed) local mapping

    func test_organizationFor_unsuffixedCredentialWithLocalConfig_returnsOrgAndMakesNoProfileCalls() async throws {
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c1",
            organizationName: "Example Org",
            in: tempHome
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)

        let organization = await resolver.organization(for: makeCredential())

        XCTAssertEqual(organization?.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000c1"))
        let callCount = await profile.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Suffixed local mapping (RESEARCH F-I5, ordering)

    func test_organizationFor_suffixedCredentialMatchesHashedDirectory_ignoresOtherDirectory() async throws {
        let workDirectory = tempHome.appendingPathComponent(".claude-work", isDirectory: true)
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c2",
            organizationName: "Work Org",
            in: workDirectory
        )
        let otherDirectory = tempHome.appendingPathComponent(".claude-other", isDirectory: true)
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c3",
            organizationName: "Other Org",
            in: otherDirectory
        )

        let suffix = ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: workDirectory.path)
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-\(suffix)")

        let organization = await resolver.organization(for: credential)

        XCTAssertEqual(organization?.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000c2"))
        let callCount = await profile.callCount
        XCTAssertEqual(callCount, 0)
    }

    func test_organizationFor_suffixedCredentialDirectoryIsSymlinkToDirectory_resolves() async throws {
        // A `.claude*` config directory can itself be a symlink (e.g. to
        // another volume); it must still be accepted as a candidate.
        let realConfigDirectory = tempHome.appendingPathComponent("real-config", isDirectory: true)
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c9",
            organizationName: "Symlinked Org",
            in: realConfigDirectory
        )
        let symlinkDirectory = tempHome.appendingPathComponent(".claude-sym", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realConfigDirectory)

        let suffix = ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: symlinkDirectory.path)
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-\(suffix)")

        let organization = await resolver.organization(for: credential)

        XCTAssertEqual(organization?.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000c9"))
    }

    func test_organizationFor_suffixedCredentialViaSymlinkedHomeAncestor_matchesLiteralPathHash() async throws {
        // Claude Code hashes the literal `CLAUDE_CONFIG_DIR` string it was
        // configured with -- e.g. `$HOME/.claude-work` formed by plain
        // string concatenation. `/tmp` itself is a symlink to `/private/tmp`
        // on macOS, and `FileManager`'s own directory enumeration resolves
        // that ancestor symlink in the paths it returns, so a suffix hashed
        // from the literal (unresolved) home path would never match
        // `directory.path` without the literal-path fallback.
        let rawHome = URL(fileURLWithPath: "/tmp/claude-resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rawHome) }
        let configDirectory = rawHome.appendingPathComponent(".claude-work", isDirectory: true)
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000ca",
            organizationName: "Linked Org",
            in: configDirectory
        )

        let literalPath = rawHome.path + "/.claude-work"
        let suffix = ClaudeCodeOrganizationResolver.configDirectoryHashSuffix(forPath: literalPath)
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: rawHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-\(suffix)")

        let organization = await resolver.organization(for: credential)

        XCTAssertEqual(organization?.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000ca"))
    }

    // MARK: - Profile fallback, scopes, and memoization (CLI-03 empty/concurrency edges)

    func test_organizationFor_suffixedCredentialWithNoLocalMatchAndProfileScope_memoizesPerExpiresAt() async throws {
        let organization = ClaudeOAuthProfileOrganization(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c4")!,
            name: "Profile Org"
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .success(organization))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let expiresAt = Date().addingTimeInterval(3600)
        let credential = makeCredential(
            service: "Claude Code-credentials-ffffffff",
            scopes: ["user:profile"],
            expiresAt: expiresAt
        )

        let first = await resolver.organization(for: credential)
        XCTAssertEqual(first?.id, organization.id)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertEqual(second?.id, organization.id)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 1, "same (service, expiresAt) must not call the profile fake again")

        let laterCredential = makeCredential(
            service: "Claude Code-credentials-ffffffff",
            scopes: ["user:profile"],
            expiresAt: expiresAt.addingTimeInterval(60)
        )
        let third = await resolver.organization(for: laterCredential)
        XCTAssertEqual(third?.id, organization.id)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 2, "a later expiresAt must call again")
    }

    func test_organizationFor_scopesExcludeProfile_returnsNilAndMakesNoProfileCall() async throws {
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-eeeeeeee", scopes: ["user:inference"])

        let organization = await resolver.organization(for: credential)

        XCTAssertNil(organization)
        let callCount = await profile.callCount
        XCTAssertEqual(callCount, 0)
    }

    func test_organizationFor_nilScopesAndNoLocalMatch_callsProfileFake() async throws {
        let organization = ClaudeOAuthProfileOrganization(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c5")!,
            name: nil
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .success(organization))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-dddddddd", scopes: nil)

        let result = await resolver.organization(for: credential)

        XCTAssertEqual(result?.id, organization.id)
        let callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)
    }

    func test_organizationFor_profileThrowsNetworkError_doesNotMemoize() async throws {
        // `.networkUnavailable` is transient (an outage, not a definitive
        // "no organization" answer) -- memoizing it would hide the
        // organization for the rest of the token's lifetime even after the
        // provider recovers, so every poll must retry.
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.networkUnavailable))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-cccccccc", scopes: nil)

        let first = await resolver.organization(for: credential)
        XCTAssertNil(first)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertNil(second)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 2, "a transient network failure must not be memoized")
    }

    func test_organizationFor_profileThrowsFiveHundredHTTPError_doesNotMemoize() async throws {
        // A 5xx is the provider having a bad moment, not a definitive
        // rejection -- same transient treatment as `.networkUnavailable`.
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.httpError(statusCode: 503)))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-dddddddd", scopes: nil)

        let first = await resolver.organization(for: credential)
        XCTAssertNil(first)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertNil(second)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 2, "a 5xx must not be memoized")
    }

    func test_organizationFor_profileThrowsRejected_memoizesNilResult() async throws {
        // `.rejected` (401/403/429) is a definitive "this token does not
        // work for this account" answer -- memoizing it for the token's
        // lifetime is correct (RESEARCH Pitfall 14).
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.rejected))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-eeeeeeee", scopes: nil)

        let first = await resolver.organization(for: credential)
        XCTAssertNil(first)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertNil(second)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 1, "a rejected token must stay memoized")
    }

    func test_organizationFor_profileThrowsInvalidResponse_memoizesNilResult() async throws {
        // `.invalidResponse` means the response will never parse -- a
        // definitive failure, not a transient one, so it stays memoized.
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-ffffffff", scopes: nil)

        let first = await resolver.organization(for: credential)
        XCTAssertNil(first)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertNil(second)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 1, "an unparseable response must stay memoized")
    }

    func test_organizationFor_profileThrowsCancellation_doesNotMemoize() async throws {
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CancellationError()))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        let credential = makeCredential(service: "Claude Code-credentials-bbbbbbbb", scopes: nil)

        let first = await resolver.organization(for: credential)
        XCTAssertNil(first)
        var callCount = await profile.callCount
        XCTAssertEqual(callCount, 1)

        let second = await resolver.organization(for: credential)
        XCTAssertNil(second)
        callCount = await profile.callCount
        XCTAssertEqual(callCount, 2, "a cancelled lookup must not be memoized")
    }

    // MARK: - Unsafe or oversized local files (T-19-19)

    func test_organizationFor_configFileIsDirectory_yieldsNoLocalMatch() async throws {
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent(".claude.json"),
            withIntermediateDirectories: true
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(homeDirectory: tempHome, profileService: profile)
        // No profile fallback: isolates the local-read failure from the fallback path.
        let credential = makeCredential(scopes: ["user:inference"])

        let organization = await resolver.organization(for: credential)

        XCTAssertNil(organization)
    }

    func test_organizationFor_configFileOversize_yieldsNoLocalMatch() async throws {
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c6",
            organizationName: "Example Org",
            in: tempHome
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(
            homeDirectory: tempHome,
            profileService: profile,
            maxConfigFileBytes: 4
        )
        let credential = makeCredential(scopes: ["user:inference"])

        let organization = await resolver.organization(for: credential)

        XCTAssertNil(organization)
    }

    func test_organizationFor_configFileWrongOwner_yieldsNoLocalMatch() async throws {
        try writeConfig(
            organizationUuid: "00000000-0000-0000-0000-0000000000c7",
            organizationName: "Example Org",
            in: tempHome
        )
        let profile = FakeClaudeOAuthUsageService(behavior: .throwError(CLIUsageFetchError.invalidResponse))
        let resolver = ClaudeCodeOrganizationResolver(
            homeDirectory: tempHome,
            profileService: profile,
            expectedOwnerId: getuid() + 1
        )
        let credential = makeCredential(scopes: ["user:inference"])

        let organization = await resolver.organization(for: credential)

        XCTAssertNil(organization)
    }
}

/// Counts and scripts `fetchProfileOrganization` calls; `fetchUsage` is never
/// exercised by this resolver and always throws if called by mistake.
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
