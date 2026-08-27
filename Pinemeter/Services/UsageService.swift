//
//  UsageService.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation
import os

/// Actor-isolated usage service with retry logic
actor UsageService: UsageServiceProtocol {
    private static let logger = Logger(subsystem: "com.pinemeter", category: "UsageService")
    private let networkService: NetworkServiceProtocol
    private let cacheRepository: CacheRepositoryProtocol
    private let keychainRepository: KeychainRepositoryProtocol
    private let settingsRepository: SettingsRepositoryProtocol

    private let maxRetries = Constants.Network.maxRetries
    private let baseURL = "https://claude.ai/api"

    /// In-memory usage cache for additional (non-primary) accounts, keyed by
    /// Keychain account. The primary account continues to use the shared
    /// disk-backed CacheRepository. AppModel owns the public aggregate export.
    private var accountMemoryCache: [String: (data: UsageData, storedAt: Date)] = [:]
    private let accountCacheTTL: TimeInterval = Constants.Cache.ttl

    init(
        networkService: NetworkServiceProtocol,
        cacheRepository: CacheRepositoryProtocol,
        keychainRepository: KeychainRepositoryProtocol,
        settingsRepository: SettingsRepositoryProtocol
    ) {
        self.networkService = networkService
        self.cacheRepository = cacheRepository
        self.keychainRepository = keychainRepository
        self.settingsRepository = settingsRepository
    }

    /// Fetch usage data with cache integration and exponential backoff retry
    func fetchUsage(forceRefresh: Bool = false) async throws -> UsageData {
        let sessionKeyString: String
        do {
            sessionKeyString = try await keychainRepository.retrieve(account: "default")
        } catch KeychainError.notFound {
            throw AppError.noSessionKey
        } catch let error as KeychainError {
            throw AppError.keychainError(error)
        }

        let sessionKey = try SessionKey(sessionKeyString)

        // Clear cache if force refresh is requested
        if forceRefresh {
            await cacheRepository.invalidate()
        }

        // Check cache first (will be empty if force refresh)
        if let cachedData = await cacheRepository.get() {
            return cachedData
        }

        // Get organization ID
        let settings = await settingsRepository.load()
        let organizationId: UUID

        if let cachedOrgId = settings.cachedOrganizationId {
            organizationId = cachedOrgId
        } else if let orgId = sessionKey.organizationId {
            organizationId = orgId
        } else {
            // Fetch organizations to get ID
            let orgs = try await fetchOrganizations()
            // Prefer organization with chat capability (Claude.ai usage), fall back to first
            guard let chatOrg = orgs.first(where: { $0.hasChatCapability }) ?? orgs.first,
                  let uuid = chatOrg.organizationUUID else {
                throw AppError.organizationNotFound
            }
            organizationId = uuid
        }

        // Fetch usage data with retry logic
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let response: UsageAPIResponse = try await networkService.request(
                    "\(baseURL)/organizations/\(organizationId)/usage",
                    method: .get,
                    sessionKey: sessionKey.value
                )

                let usageData = try response.toDomain()

                // Cache the result
                await cacheRepository.set(usageData)

                return usageData

            } catch NetworkError.networkUnavailable {
                Self.logger.warning("Network unavailable (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = NetworkError.networkUnavailable
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.backoffBase)
            } catch NetworkError.rateLimitExceeded {
                // Rate limit hit - use longer exponential backoff
                Self.logger.warning("Rate limit exceeded (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = NetworkError.rateLimitExceeded
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.rateLimitBackoffBase)
            } catch NetworkError.authenticationFailed {
                Self.logger.error("Authentication failed - session key invalid")
                throw AppError.sessionKeyInvalid
            } catch let error as URLError where error.code == .timedOut ||
                                               error.code == .cannotConnectToHost ||
                                               error.code == .networkConnectionLost ||
                                               error.code == .notConnectedToInternet {
                // Retry on timeout and connection errors
                Self.logger.warning("URL error: \(error.localizedDescription) (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = error
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.backoffBase)
            } catch {
                Self.logger.error("API request failed: \(error.localizedDescription)")
                throw AppError.networkError(error as? NetworkError ?? .invalidResponse)
            }
        }

        // If all retries failed, check for last known data
        if let lastKnown = await cacheRepository.getLastKnown() {
            Self.logger.warning("All retries failed, using cached data")
            return lastKnown
        }

        Self.logger.error("All retries failed, no cached data available")
        throw AppError.networkError(lastError as? NetworkError ?? .networkUnavailable)
    }

    /// Fetch usage for a specific connected Claude account, backed by a small
    /// per-account in-memory cache (no disk/public export; that stays the
    /// primary account's responsibility).
    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool = false) async throws -> UsageData {
        let sessionKeyString: String
        do {
            sessionKeyString = try await keychainRepository.retrieve(account: account)
        } catch KeychainError.notFound {
            throw AppError.noSessionKey
        } catch let error as KeychainError {
            throw AppError.keychainError(error)
        }

        let sessionKey = try SessionKey(sessionKeyString)

        if !forceRefresh,
           let cached = accountMemoryCache[account],
           Date().timeIntervalSince(cached.storedAt) < accountCacheTTL {
            return cached.data
        }

        let usageData = try await performUsageFetch(sessionKey: sessionKey, organizationId: organizationId)
        accountMemoryCache[account] = (usageData, Date())
        return usageData
    }

    /// Runs the usage request against a specific organization with retry/backoff.
    /// Throws `AppError.sessionKeyInvalid` on auth failure and
    /// `AppError.networkError` when retries are exhausted.
    private func performUsageFetch(sessionKey: SessionKey, organizationId: UUID) async throws -> UsageData {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let response: UsageAPIResponse = try await networkService.request(
                    "\(baseURL)/organizations/\(organizationId)/usage",
                    method: .get,
                    sessionKey: sessionKey.value
                )
                return try response.toDomain()
            } catch NetworkError.networkUnavailable {
                Self.logger.warning("Network unavailable (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = NetworkError.networkUnavailable
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.backoffBase)
            } catch NetworkError.rateLimitExceeded {
                Self.logger.warning("Rate limit exceeded (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = NetworkError.rateLimitExceeded
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.rateLimitBackoffBase)
            } catch NetworkError.authenticationFailed {
                Self.logger.error("Authentication failed - session key invalid")
                throw AppError.sessionKeyInvalid
            } catch let error as URLError where error.code == .timedOut ||
                                               error.code == .cannotConnectToHost ||
                                               error.code == .networkConnectionLost ||
                                               error.code == .notConnectedToInternet {
                Self.logger.warning("URL error: \(error.localizedDescription) (attempt \(attempt + 1)/\(self.maxRetries))")
                lastError = error
                try await waitBeforeRetry(attempt: attempt, base: Constants.Network.backoffBase)
            } catch {
                Self.logger.error("API request failed: \(error.localizedDescription)")
                throw AppError.networkError(error as? NetworkError ?? .invalidResponse)
            }
        }

        throw AppError.networkError(lastError as? NetworkError ?? .networkUnavailable)
    }

    static func retryDelay(attempt: Int, base: Double) -> TimeInterval? {
        guard attempt < Constants.Network.maxRetries - 1 else { return nil }
        return pow(base, Double(attempt)) * Double.random(in: 0.8...1.2)
    }

    private func waitBeforeRetry(attempt: Int, base: Double) async throws {
        guard let delay = Self.retryDelay(attempt: attempt, base: base) else { return }
        try await Task.sleep(for: .seconds(delay))
    }

    /// Fetch list of organizations for the user
    func fetchOrganizations() async throws -> [Organization] {
        let sessionKeyString: String
        do {
            sessionKeyString = try await keychainRepository.retrieve(account: "default")
        } catch KeychainError.notFound {
            throw AppError.noSessionKey
        } catch let error as KeychainError {
            throw AppError.keychainError(error)
        }

        let sessionKey = try SessionKey(sessionKeyString)
        return try await fetchOrganizations(sessionKey: sessionKey)
    }

    /// Fetch list of organizations with explicit session key (for setup before keychain save)
    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] {
        let organizations: OrganizationListResponse = try await networkService.request(
            "\(baseURL)/organizations",
            method: .get,
            sessionKey: sessionKey.value
        )

        return organizations
    }

    /// Validate session key with Claude API
    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool {
        do {
            let _: OrganizationListResponse = try await networkService.request(
                "\(baseURL)/organizations",
                method: .get,
                sessionKey: sessionKey.value
            )
            return true
        } catch NetworkError.authenticationFailed {
            return false
        } catch {
            throw error
        }
    }
}
