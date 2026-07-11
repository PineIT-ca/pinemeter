//
//  GeminiUsageServiceTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class GeminiUsageServiceTests: XCTestCase {
    private var accountsToCleanUp: [String] = []

    override func tearDown() async throws {
        let repository = GeminiAPIKeyRepository()
        for account in accountsToCleanUp {
            try? await repository.clear(account: account)
        }
        accountsToCleanUp.removeAll()
        try await super.tearDown()
    }

    func test_geminiAPIKeyRepository_persistsKeyAndSanitizedStatusOutsideSettings() async throws {
        let suiteName = "GeminiUsageServiceTests.Status.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let account = uniqueAccount()
        accountsToCleanUp.append(account)
        let repository = GeminiAPIKeyRepository(userDefaults: userDefaults)

        try await repository.save(try GeminiAPIKey(" gemini-api-key-redaction-sentinel \n"), account: account)

        let loadedKey = try await repository.load(account: account)
        XCTAssertEqual(loadedKey.value, "gemini-api-key-redaction-sentinel")
        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .available)
        XCTAssertNil(status.lastErrorCategory)

        let persistedDomain = userDefaults.persistentDomain(forName: suiteName) ?? [:]
        let persistedPayload = String(describing: persistedDomain)
        XCTAssertFalse(persistedPayload.contains("gemini-api-key-redaction-sentinel"))
        XCTAssertFalse(String(describing: status).contains("gemini-api-key-redaction-sentinel"))
        XCTAssertNil(userDefaults.data(forKey: "app_settings"))
    }

    func test_geminiAPIKeyRejectsBlankValueBeforeRepositoryBoundary() async throws {
        XCTAssertThrowsError(try GeminiAPIKey("   ")) { error in
            XCTAssertEqual(error as? GeminiAPIKeyRepositoryError, .invalidAPIKey)
        }
    }

    func test_fetchUsage_withStoredAPIKey_returnsNormalizedUsageAndSavesSanitizedStatus() async throws {
        let repository = GeminiAPIKeyRepositoryStub()
        try await repository.save(try GeminiAPIKey("gemini-api-key-redaction-sentinel"), account: GeminiUsageService.defaultAPIKeyAccount)
        let now = Date(timeIntervalSince1970: 100)
        let httpClient = GeminiHTTPClientStub(response: #"""
        {
          "usedPercent": 42.5,
          "limitLabel": "Gemini API quota",
          "resetAt": 1770000000
        }
        """#.data(using: .utf8)!)
        let service = GeminiUsageService(httpClient: httpClient, apiKeyRepository: repository, now: { now })

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.label, "Gemini API quota")
        XCTAssertEqual(usage.usedPercent, 42.5)
        XCTAssertEqual(usage.percentage, 42.5)
        XCTAssertEqual(usage.status, .safe)
        XCTAssertEqual(usage.lastUpdated, now)
        XCTAssertEqual(usage.resetAt, Date(timeIntervalSince1970: 1_770_000_000))
        let repositoryStatus = await repository.status
        XCTAssertEqual(repositoryStatus.state, .available)
        XCTAssertNil(repositoryStatus.lastErrorCategory)
        let requests = await httpClient.requests
        XCTAssertEqual(requests.map(\.apiKey.value), ["gemini-api-key-redaction-sentinel"])
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].endpoint.hasSuffix("/v1beta/models"))
    }

    func test_fetchUsage_withMissingStoredAPIKeyThrowsMissingAPIKey() async {
        let repository = GeminiAPIKeyRepositoryStub()
        let service = GeminiUsageService(httpClient: GeminiHTTPClientStub(), apiKeyRepository: repository)

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected missing API key error")
        } catch GeminiUsageError.missingAPIKey {
            let status = await repository.status
            XCTAssertEqual(status.state, .missing)
            XCTAssertEqual(status.lastErrorCategory, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_mapsInvalidAPIKeyAndClearsStoredCredential() async throws {
        let repository = GeminiAPIKeyRepositoryStub()
        try await repository.save(try GeminiAPIKey("gemini-api-key-redaction-sentinel"), account: GeminiUsageService.defaultAPIKeyAccount)
        let httpClient = GeminiHTTPClientStub(error: GeminiUsageError.invalidAPIKey)
        let service = GeminiUsageService(httpClient: httpClient, apiKeyRepository: repository)

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected invalid API key error")
        } catch GeminiUsageError.invalidAPIKey {
            let clearCalled = await repository.clearCalled
            let status = await repository.status
            XCTAssertTrue(clearCalled)
            XCTAssertEqual(status.state, .missing)
            XCTAssertEqual(status.lastErrorCategory, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_mapsHTTPForbiddenToInvalidAPIKey() async throws {
        let service = GeminiUsageService(httpClient: GeminiHTTPClientStub(error: GeminiUsageError.httpError(statusCode: 403)))

        do {
            _ = try await service.fetchUsage(apiKey: try GeminiAPIKey("gemini-api-key-redaction-sentinel"))
            XCTFail("Expected invalid API key error")
        } catch GeminiUsageError.invalidAPIKey {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_mapsEmptyQuotaResponseToQuotaUnavailable() async throws {
        let httpClient = GeminiHTTPClientStub(response: #"{"models":[]}"#.data(using: .utf8)!)
        let service = GeminiUsageService(httpClient: httpClient)

        do {
            _ = try await service.fetchUsage(apiKey: try GeminiAPIKey("gemini-api-key-redaction-sentinel"))
            XCTFail("Expected quota unavailable")
        } catch GeminiUsageError.quotaUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_validateAPIKeyReturnsFalseForAuthFailures() async throws {
        let service = GeminiUsageService(httpClient: GeminiHTTPClientStub(error: GeminiUsageError.invalidAPIKey))

        let isValid = try await service.validateAPIKey(try GeminiAPIKey("gemini-api-key-redaction-sentinel"))

        XCTAssertFalse(isValid)
    }

    private func uniqueAccount() -> String {
        "GeminiUsageServiceTests.\(UUID().uuidString)"
    }
}

private actor GeminiAPIKeyRepositoryStub: GeminiAPIKeyRepositoryProtocol {
    private var apiKeys: [String: GeminiAPIKey] = [:]
    private(set) var clearCalled = false
    private(set) var status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)

    func save(_ apiKey: GeminiAPIKey, account: String) async throws {
        apiKeys[account] = apiKey
        status = GeminiAPIKeyAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func load(account: String) async throws -> GeminiAPIKey {
        guard let apiKey = apiKeys[account] else {
            status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            throw GeminiAPIKeyRepositoryError.notFound
        }
        return apiKey
    }

    func validate(account: String) async -> GeminiAPIKeyAcquisitionStatus {
        status
    }

    func clear(account: String) async throws {
        apiKeys[account] = nil
        clearCalled = true
        status = GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

private actor GeminiHTTPClientStub: GeminiHTTPClientProtocol {
    struct RecordedRequest: Equatable {
        let endpoint: String
        let apiKey: GeminiAPIKey
    }

    private let response: Data?
    private let error: Error?
    private(set) var requests: [RecordedRequest] = []

    init(response: Data? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func request<T: Decodable>(_ endpoint: String, apiKey: GeminiAPIKey) async throws -> T {
        requests.append(RecordedRequest(endpoint: endpoint, apiKey: apiKey))

        if let error {
            throw error
        }

        guard let response else {
            throw GeminiUsageError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: response)
    }
}
