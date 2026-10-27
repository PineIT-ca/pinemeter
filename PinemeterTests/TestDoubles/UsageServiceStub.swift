//
//  UsageServiceStub.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

actor UsageServiceStub: UsageServiceProtocol {
    let fetchUsageResult: Result<UsageData, Error>
    let isSessionKeyValid: Bool
    let organizations: [Organization]
    private(set) var fetchUsageCallCount = 0
    private(set) var forceRefreshValues: [Bool] = []

    init(
        fetchUsageResult: Result<UsageData, Error>,
        organizations: [Organization] = [],
        isSessionKeyValid: Bool = true
    ) {
        self.fetchUsageResult = fetchUsageResult
        self.organizations = organizations
        self.isSessionKeyValid = isSessionKeyValid
    }

    func fetchUsage(forceRefresh: Bool) async throws -> UsageData {
        fetchUsageCallCount += 1
        forceRefreshValues.append(forceRefresh)
        switch fetchUsageResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func fetchUsage(account: String, organizationId: UUID, forceRefresh: Bool) async throws -> UsageData {
        fetchUsageCallCount += 1
        forceRefreshValues.append(forceRefresh)
        switch fetchUsageResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func fetchOrganizations() async throws -> [Organization] {
        organizations
    }

    func fetchOrganizations(sessionKey: SessionKey) async throws -> [Organization] {
        organizations
    }

    func validateSessionKey(_ sessionKey: SessionKey) async throws -> Bool {
        isSessionKeyValid
    }
}
