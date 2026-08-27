//
//  ChatGPTAccountConnectionController.swift
//  Pinemeter
//

import Foundation
import os

/// Turns raw imported ChatGPT cookies into a connected account set.
///
/// Mirrors `ClaudeAccountConnectionController`: every cookie is validated
/// concurrently, accounts are deduplicated by the identity the provider
/// reports (not by cookie value, since one account can be signed in from
/// several browser profiles), the first account keeps the legacy single
/// account Keychain slot, and accounts that disappeared from the scan have
/// their Keychain entries deleted.
actor ChatGPTAccountConnectionController {
    struct Connection: Sendable {
        let accounts: [ChatGPTAccount]
        let staleAccountIds: Set<String>
        let connectedLabels: [String]
    }

    private struct Candidate: Sendable {
        let index: Int
        let cookieHeader: String
        let identity: ChatGPTAccountIdentity
        let accountId: String
        let sourceDescription: String
    }

    private static let logger = Logger(subsystem: "com.pinemeter", category: "ChatGPTAccountConnection")

    private let usageService: any ChatGPTUsageServiceProtocol
    private let sessionRepository: any ChatGPTSessionRepositoryProtocol

    init(
        usageService: any ChatGPTUsageServiceProtocol,
        sessionRepository: any ChatGPTSessionRepositoryProtocol
    ) {
        self.usageService = usageService
        self.sessionRepository = sessionRepository
    }

    func connect(
        importedCookies: [ImportedChatGPTSessionCookie],
        excludedAccountIds: @escaping @MainActor @Sendable () -> Set<String>,
        currentAccounts: @escaping @MainActor @Sendable () -> [ChatGPTAccount],
        progress: @escaping @MainActor @Sendable (String?) -> Void
    ) async throws -> Connection {
        let total = importedCookies.count
        await progress("Validating \(total) ChatGPT session\(total == 1 ? "" : "s")\u{2026}")

        let validated: [Candidate] = await withTaskGroup(of: Candidate?.self) { group in
            for (index, imported) in importedCookies.enumerated() {
                group.addTask { [usageService] in
                    let normalized = ChatGPTUsageService.cookieHeader(from: imported.cookieHeader)
                    guard !normalized.isEmpty else { return nil }
                    let identity: ChatGPTAccountIdentity
                    do {
                        identity = try await usageService
                            .fetchUsageAndIdentity(sessionCookie: normalized)
                            .identity
                    } catch {
                        Self.logger.warning(
                            "Cookie \(index) (\(imported.sourceDescription, privacy: .public)): validation failed"
                        )
                        return nil
                    }
                    // Without an id two cookies cannot be told apart, so every
                    // unidentified cookie collapses onto the one legacy id
                    // rather than risking two accounts fighting over a
                    // Keychain slot. A cookie that validates is still
                    // connected -- refusing it outright would lock out anyone
                    // whose response omits the identity fields.
                    let accountId = identity.stableId ?? ChatGPTAccount.unidentifiedId
                    if identity.stableId == nil {
                        Self.logger.warning(
                            "Cookie \(index) (\(imported.sourceDescription, privacy: .public)): provider reported no account id"
                        )
                    }
                    return Candidate(
                        index: index,
                        cookieHeader: normalized,
                        identity: identity,
                        accountId: accountId,
                        sourceDescription: imported.sourceDescription
                    )
                }
            }

            var results: [Candidate] = []
            var checked = 0
            for await result in group {
                checked += 1
                if let candidate = result {
                    results.append(candidate)
                }
                await progress("Checked \(checked) of \(total) ChatGPT sessions\u{2026}")
            }
            return results.sorted { $0.index < $1.index }
        }

        let existingAccounts = await currentAccounts()
        var candidates: [Candidate] = []
        var seenAccounts = Set<String>()
        var excludedCandidateCount = 0
        let excludedAccountIds = await excludedAccountIds()

        // An exclusion taken before the account's identity resolved is keyed by
        // the legacy Keychain slot (recorded by a pre-multi-account build) or by
        // the unidentified placeholder, and no real candidate id can ever match
        // either. Both therefore mean "ChatGPT is excluded", and block every
        // candidate: silently reconnecting an account the user disconnected
        // would reverse their decision. Recovery is the visible Re-enable action
        // in Settings.
        let excludesEveryAccount = excludedAccountIds.contains(ChatGPTAccount.primaryKeychainAccount)
            || excludedAccountIds.contains(ChatGPTAccount.unidentifiedId)

        for candidate in validated {
            if excludesEveryAccount || excludedAccountIds.contains(candidate.accountId) {
                excludedCandidateCount += 1
            } else if seenAccounts.insert(candidate.accountId).inserted {
                candidates.append(candidate)
            }
        }

        if candidates.isEmpty, excludedCandidateCount == 0, !excludesEveryAccount {
            // Nothing validated. A poll can fail for reasons that say nothing
            // about the cookie (offline, provider hiccup), and connecting has
            // never required a successful fetch, so a single discovered cookie
            // is still saved to the primary slot unvalidated -- exactly the
            // pre-multi-account behavior.
            //
            // Restricted to at most one already-connected account. With two
            // connected and only one cookie still discoverable, this would write
            // that cookie into the primary slot and delete the other account's,
            // replacing one account's credential with another's under the first
            // one's label. It also reuses the existing primary's id so a rescan
            // during an outage cannot strand the account under the unidentified
            // placeholder and lose its custom label.
            guard importedCookies.count == 1,
                  existingAccounts.count <= 1,
                  case let normalized = ChatGPTUsageService.cookieHeader(from: importedCookies[0].cookieHeader),
                  !normalized.isEmpty else {
                await progress(nil)
                throw SessionKeyImportError.invalidImportedChatGPTSessionCookie
            }
            candidates = [Candidate(
                index: 0,
                cookieHeader: normalized,
                identity: .unidentified,
                accountId: existingAccounts.first?.id ?? ChatGPTAccount.unidentifiedId,
                sourceDescription: importedCookies[0].sourceDescription
            )]
        }

        guard !candidates.isEmpty else {
            await progress(nil)
            throw SessionKeyImportError.allDiscoveredAccountsExcluded
        }

        await progress("Saving \(candidates.count) ChatGPT account\(candidates.count == 1 ? "" : "s")\u{2026}")
        // Whichever discovered account already holds the primary slot keeps it,
        // so an upgrade or a rescan never silently repoints the legacy slot at
        // a different account.
        let existingPrimaryId = existingAccounts.first(where: { $0.isPrimary })?.id
        let primaryIndex = candidates.firstIndex { $0.accountId == existingPrimaryId } ?? 0
        let customLabelsByAccountId = Dictionary(
            existingAccounts.compactMap { account in
                account.customLabel.map { (account.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var accounts: [ChatGPTAccount] = []
        // The primary slot is always reassigned to a discovered candidate, so
        // only additional accounts can go stale and have their Keychain entry
        // deleted.
        var staleAccountIds = Set(existingAccounts.filter { !$0.isPrimary }.map(\.id))

        for (offset, candidate) in candidates.enumerated() {
            let isPrimary = offset == primaryIndex
            // Account ids come from the provider, so an id equal to the legacy
            // slot name is namespaced rather than allowed to overwrite the
            // primary account's cookie.
            let keychainAccount: String
            if isPrimary {
                keychainAccount = ChatGPTAccount.primaryKeychainAccount
            } else if candidate.accountId == ChatGPTAccount.primaryKeychainAccount {
                keychainAccount = "chatgpt.account.\(candidate.accountId)"
            } else {
                keychainAccount = candidate.accountId
            }
            try await sessionRepository.save(
                ChatGPTSession(sessionCookie: candidate.cookieHeader),
                account: keychainAccount
            )
            // A rescan must never downgrade metadata it simply did not learn
            // this time, so anything the identity omits falls back to what is
            // already stored for that account.
            let previous = existingAccounts.first { $0.id == candidate.accountId }
            let reportedEmail = candidate.identity.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            accounts.append(ChatGPTAccount(
                id: candidate.accountId,
                label: reportedEmail.isEmpty
                    ? (previous?.label ?? candidate.identity.displayLabel)
                    : candidate.identity.displayLabel,
                planType: candidate.identity.planType ?? previous?.planType,
                keychainAccount: keychainAccount,
                profileLabel: candidate.sourceDescription,
                customLabel: customLabelsByAccountId[candidate.accountId]
            ))
            staleAccountIds.remove(candidate.accountId)
        }

        // Sort so the primary account renders first, matching Claude's order.
        accounts.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }

        for staleId in staleAccountIds {
            guard let stale = existingAccounts.first(where: { $0.id == staleId }),
                  !stale.isPrimary else { continue }
            try? await sessionRepository.clear(account: stale.keychainAccount)
        }

        return Connection(
            accounts: accounts,
            staleAccountIds: staleAccountIds,
            connectedLabels: accounts.map(\.displayLabel)
        )
    }
}
