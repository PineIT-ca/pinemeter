import Foundation
import os

actor ClaudeAccountConnectionController {
    struct Connection: Sendable {
        let result: ClaudeAccountsImportResult
        let accounts: [ClaudeAccount]
        let staleAccountIds: Set<String>
    }

    private struct Candidate: Sendable {
        let index: Int
        let value: String
        let organization: Organization
        let sourceDescription: String
    }

    private static let logger = Logger(subsystem: "com.pinemeter", category: "ClaudeAccountConnection")

    private let usageService: any UsageServiceProtocol
    private let keychainRepository: any KeychainRepositoryProtocol

    init(
        usageService: any UsageServiceProtocol,
        keychainRepository: any KeychainRepositoryProtocol
    ) {
        self.usageService = usageService
        self.keychainRepository = keychainRepository
    }

    func connect(
        importedKeys: [ImportedSessionKey],
        excludedAccountIds: @escaping @MainActor @Sendable () -> Set<String>,
        currentAccounts: @escaping @MainActor @Sendable () -> [ClaudeAccount],
        progress: @escaping @MainActor @Sendable (String?) -> Void,
        connectPrimary: @escaping @MainActor @Sendable (String) async throws -> Bool
    ) async throws -> Connection {
        let total = importedKeys.count
        await progress("Validating \(total) session\(total == 1 ? "" : "s")\u{2026}")

        Self.logger.info("Connecting Claude accounts from \(importedKeys.count) imported key(s): \(importedKeys.map(\.sourceDescription).joined(separator: ", "), privacy: .public)")

        let validated: [Candidate] = await withTaskGroup(of: Candidate?.self) { group in
            for (index, imported) in importedKeys.enumerated() {
                group.addTask { [usageService] in
                    guard let sessionKey = try? SessionKey(imported.value) else {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): malformed session key")
                        return nil
                    }
                    let organizations: [Organization]
                    do {
                        organizations = try await usageService.fetchOrganizations(sessionKey: sessionKey)
                    } catch {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): fetchOrganizations failed: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                    guard let organization = organizations.first(where: { $0.hasChatCapability }) ?? organizations.first,
                          organization.organizationUUID != nil else {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): no usable organization in response")
                        return nil
                    }
                    Self.logger.info("Key \(index) (\(imported.sourceDescription, privacy: .public)): validated as org \(organization.uuid, privacy: .public) \(organization.name, privacy: .public)")
                    return Candidate(
                        index: index,
                        value: sessionKey.value,
                        organization: organization,
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
                await progress("Checked \(checked) of \(total) sessions\u{2026}")
            }
            return results.sorted { $0.index < $1.index }
        }

        var candidates: [Candidate] = []
        var seenOrganizations = Set<String>()
        var excludedCandidateCount = 0
        let excludedAccountIds = await excludedAccountIds()
        for candidate in validated {
            if excludedAccountIds.contains(candidate.organization.uuid) {
                excludedCandidateCount += 1
                Self.logger.info("Skipping scan-excluded Claude organization \(candidate.organization.uuid, privacy: .public)")
            } else if seenOrganizations.insert(candidate.organization.uuid).inserted {
                candidates.append(candidate)
            } else {
                Self.logger.info("Key \(candidate.index) (\(candidate.sourceDescription, privacy: .public)): duplicate of already-connected org \(candidate.organization.uuid, privacy: .public), skipping")
            }
        }

        guard !candidates.isEmpty else {
            await progress(nil)
            throw excludedCandidateCount > 0
                ? SessionKeyImportError.allDiscoveredAccountsExcluded
                : SessionKeyImportError.invalidImportedSessionKey
        }

        await progress("Saving \(candidates.count) account\(candidates.count == 1 ? "" : "s")\u{2026}")

        let accountsBeforePrimarySave = await currentAccounts()
        let existingPrimaryOrganizationId = accountsBeforePrimarySave.first(where: { $0.isPrimary })?.organizationId
        let primaryIndex = candidates.firstIndex(where: {
            $0.organization.organizationUUID == existingPrimaryOrganizationId
        }) ?? 0
        let primaryCandidate = candidates[primaryIndex]
        let additionalCandidates = candidates.enumerated()
            .filter { $0.offset != primaryIndex }
            .map { $0.element }
        let customLabelsByAccountId = Dictionary(
            accountsBeforePrimarySave.compactMap { account in
                account.customLabel.map { (account.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        guard try await connectPrimary(primaryCandidate.value) else {
            throw SessionKeyImportError.invalidImportedSessionKey
        }

        var accounts = [ClaudeAccount(
            id: primaryCandidate.organization.uuid,
            label: primaryCandidate.organization.name,
            organizationId: primaryCandidate.organization.organizationUUID!,
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: primaryCandidate.sourceDescription,
            customLabel: customLabelsByAccountId[primaryCandidate.organization.uuid]
        )]
        var staleAccountIds = Set(await currentAccounts().filter { !$0.isPrimary }.map(\.id))

        for candidate in additionalCandidates {
            try await keychainRepository.save(
                sessionKey: candidate.value,
                account: candidate.organization.uuid
            )
            accounts.append(ClaudeAccount(
                id: candidate.organization.uuid,
                label: candidate.organization.name,
                organizationId: candidate.organization.organizationUUID!,
                keychainAccount: candidate.organization.uuid,
                profileLabel: candidate.sourceDescription,
                customLabel: customLabelsByAccountId[candidate.organization.uuid]
            ))
            staleAccountIds.remove(candidate.organization.uuid)
        }

        for staleId in staleAccountIds {
            try? await keychainRepository.delete(account: staleId)
        }

        return Connection(
            result: ClaudeAccountsImportResult(
                primary: ImportedSessionKey(
                    value: primaryCandidate.value,
                    sourceDescription: primaryCandidate.sourceDescription
                ),
                importedCount: accounts.count,
                accountLabels: accounts.map(\.displayLabel),
                connected: ([primaryCandidate] + additionalCandidates).map {
                    ImportedSessionKey(value: $0.value, sourceDescription: $0.sourceDescription)
                }
            ),
            accounts: accounts,
            staleAccountIds: staleAccountIds
        )
    }
}
