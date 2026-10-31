//
//  ClaudeCodeOrganizationResolver.swift
//  Pinemeter
//
//  Maps a Claude Code Keychain login to the Claude organization (`ClaudeAccount`
//  org UUID) it belongs to (CLI-03), so the login can be merged into an
//  existing account instead of creating a duplicate (D-03). The default
//  Keychain item maps to `~/.claude.json`; a suffixed item maps to whichever
//  `.claude*` directory directly under the home directory hashes to the same
//  8-hex suffix (RESEARCH F-I2, F-I5). When no local file resolves the
//  organization, `/api/oauth/profile` is called at most once per
//  `(service, expiresAt)` pair and the result -- including a "no organization
//  found" result -- is memoized so an unmapped login is never re-queried on
//  every poll cycle for the life of its token (RESEARCH Pitfall 14, Open
//  Question 3).
//
//  Only `oauthAccount.{organizationUuid, organizationName}` is ever decoded
//  from a `.claude.json` file -- the email and every other `oauthAccount`
//  field are never read into anything this type keeps (D-08). Every local
//  file read goes through `BoundedLocalFileReader`, so a `.claude.json` that
//  is not a regular file, is owned by another user, or exceeds the size cap
//  is silently ignored rather than read (T-19-19).
//

import CryptoKit
import Foundation

actor ClaudeCodeOrganizationResolver {
    static let maxConfigFileBytes = 16 * 1_024 * 1_024

    private let homeDirectory: URL
    private let profileService: any ClaudeOAuthUsageServiceProtocol
    private let expectedOwnerId: uid_t
    private let maxConfigFileBytes: Int
    private let maxProfileMemoEntries: Int

    /// `nil` only here means "no local match and the profile fallback has not
    /// resolved it yet" at the dictionary-membership level; a present entry
    /// whose wrapped value is `nil` means "the profile fallback ran and found
    /// no organization" -- that distinction is what lets a failed lookup stay
    /// memoized instead of being retried every poll cycle.
    private var profileMemo: [MemoKey: ClaudeOAuthProfileOrganization?] = [:]
    private var profileMemoOrder: [MemoKey] = []

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profileService: any ClaudeOAuthUsageServiceProtocol,
        expectedOwnerId: uid_t = getuid(),
        maxConfigFileBytes: Int = ClaudeCodeOrganizationResolver.maxConfigFileBytes,
        maxProfileMemoEntries: Int = 32
    ) {
        self.homeDirectory = homeDirectory
        self.profileService = profileService
        self.expectedOwnerId = expectedOwnerId
        self.maxConfigFileBytes = maxConfigFileBytes
        self.maxProfileMemoEntries = maxProfileMemoEntries
    }

    /// The first 8 lowercase hex characters of the SHA-256 digest of `path`,
    /// NFC-normalized first -- Claude Code's own per-`CLAUDE_CONFIG_DIR`
    /// service-name suffix (RESEARCH F-K3).
    static func configDirectoryHashSuffix(forPath path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes only `oauthAccount.{organizationUuid, organizationName}` from
    /// a `.claude.json` file's raw bytes. Returns `nil` for missing
    /// `oauthAccount`, a missing or malformed `organizationUuid`, or data
    /// that is not that JSON shape at all. Org ids are returned as `UUID`
    /// values -- never compared or carried as raw strings (RESEARCH F-I3) --
    /// so an uppercase and a lowercase `organizationUuid` for the same
    /// organization compare equal.
    static func organization(fromConfigData data: Data) -> ClaudeOAuthProfileOrganization? {
        guard let payload = try? JSONDecoder().decode(ConfigPayload.self, from: data),
              let oauthAccount = payload.oauthAccount,
              let uuidString = oauthAccount.organizationUuid,
              let uuid = UUID(uuidString: uuidString) else {
            return nil
        }
        return ClaudeOAuthProfileOrganization(id: uuid, name: oauthAccount.organizationName)
    }

    private struct ConfigPayload: Decodable {
        struct OAuthAccount: Decodable {
            let organizationUuid: String?
            let organizationName: String?
        }
        let oauthAccount: OAuthAccount?
    }

    /// Resolves the organization a Claude Code Keychain credential belongs
    /// to: a local `.claude.json` read first, then -- only for an item whose
    /// scopes are absent or include `user:profile` -- a memoized
    /// `/api/oauth/profile` call. Returns `nil` when neither resolves it.
    func organization(for credential: ClaudeCodeKeychainCredential) async -> ClaudeOAuthProfileOrganization? {
        let local: ClaudeOAuthProfileOrganization?
        if let suffix = credential.configDirectoryHashSuffix {
            local = suffixedLocalOrganization(suffix: suffix)
        } else {
            local = defaultLocalOrganization()
        }
        if let local {
            return local
        }

        guard Self.shouldUseProfileFallback(scopes: credential.scopes) else {
            return nil
        }

        let key = MemoKey(service: credential.service, expiresAt: credential.expiresAt)
        if let memoized = profileMemo[key] {
            return memoized
        }

        do {
            let organization = try await profileService.fetchProfileOrganization(accessToken: credential.accessToken)
            memoize(key, result: organization)
            return organization
        } catch is CancellationError {
            // A cancelled lookup is not a definitive "no organization"
            // answer -- never memoize it, so the next poll cycle tries again
            // (RESEARCH Open Question 3).
            return nil
        } catch let error as CLIUsageFetchError {
            switch error {
            case .rejected, .invalidResponse:
                // The provider definitively answered "not this" (token
                // rejected) or returned a shape that will never parse --
                // memoizing these for the token's lifetime is correct.
                memoize(key, result: nil)
            case .httpError, .networkUnavailable:
                // Transient: an outage, a 5xx, or some other non-definitive
                // HTTP status. Memoizing `nil` here would hide the
                // organization for the rest of the token's lifetime even
                // after the provider recovers, so the next poll retries
                // instead.
                break
            }
            return nil
        } catch {
            // An error this resolver's own dependencies do not throw.
            // Treat as transient, same as `.httpError`/`.networkUnavailable`
            // above, rather than risk memoizing a spurious failure.
            return nil
        }
    }

    private func defaultLocalOrganization() -> ClaudeOAuthProfileOrganization? {
        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        guard let data = BoundedLocalFileReader.read(
            configURL,
            maxBytes: maxConfigFileBytes,
            expectedOwnerId: expectedOwnerId
        ) else {
            return nil
        }
        return Self.organization(fromConfigData: data)
    }

    /// Scans the immediate `.claude*` subdirectories of the home directory in
    /// ascending name order and returns the organization from the first one
    /// whose path hashes to `suffix` and whose `.claude.json` yields an org
    /// (RESEARCH F-I5).
    private func suffixedLocalOrganization(suffix: String) -> ClaudeOAuthProfileOrganization? {
        // Deliberately no `.skipsHiddenFiles`: every candidate directory name
        // starts with a dot, so that option would exclude all of them.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return nil
        }

        let candidateDirectories = entries
            .filter { url in
                guard url.lastPathComponent.hasPrefix(".claude") else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true { return true }
                // A config directory can itself be a symlink (e.g. to
                // another volume) -- accept it when it resolves to a
                // directory, instead of silently skipping it.
                guard values?.isSymbolicLink == true else { return false }
                return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for directory in candidateDirectories {
            // Claude Code hashes the literal `CLAUDE_CONFIG_DIR` string it
            // was configured with -- normally `$HOME/<name>` formed by plain
            // string concatenation, which can differ from `directory.path`
            // when `homeDirectory` applies symlink resolution or
            // normalization this process's raw `$HOME` does not (RESEARCH
            // F-K3). Try both forms before giving up on this candidate.
            let literalPath = homeDirectory.path + "/" + directory.lastPathComponent
            let matches = Self.configDirectoryHashSuffix(forPath: directory.path) == suffix
                || Self.configDirectoryHashSuffix(forPath: literalPath) == suffix
            guard matches else { continue }
            let configURL = directory.appendingPathComponent(".claude.json")
            guard let data = BoundedLocalFileReader.read(
                configURL,
                maxBytes: maxConfigFileBytes,
                expectedOwnerId: expectedOwnerId
            ), let organization = Self.organization(fromConfigData: data) else {
                continue
            }
            return organization
        }
        return nil
    }

    private static func shouldUseProfileFallback(scopes: [String]?) -> Bool {
        guard let scopes else { return true }
        return scopes.contains("user:profile")
    }

    private func memoize(_ key: MemoKey, result: ClaudeOAuthProfileOrganization?) {
        let previousEntry = profileMemo.updateValue(result, forKey: key)
        guard previousEntry == nil else { return }
        profileMemoOrder.append(key)
        while profileMemoOrder.count > maxProfileMemoEntries {
            let oldest = profileMemoOrder.removeFirst()
            profileMemo.removeValue(forKey: oldest)
        }
    }

    private struct MemoKey: Hashable {
        let service: String
        let expiresAt: Date
    }
}
