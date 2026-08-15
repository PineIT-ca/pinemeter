//
//  UsageServiceTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
@testable import Pinemeter

final class UsageServiceTests: XCTestCase {
    func test_usageFetch_requiresSessionKey() async {
        let networkService = NetworkServiceStub(responseData: Data())
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        do {
            _ = try await service.fetchUsage(forceRefresh: false)
            XCTFail("Expected noSessionKey error")
        } catch AppError.noSessionKey {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_userWithCachedUsage_seesCachedValueWithoutNetworkCall() async throws {
        let expectedUsage = makeUsageData(percentage: TestConstants.sessionPercentage)
        let networkService = NetworkServiceStub(responseData: Data())
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )
        await cacheRepository.set(expectedUsage)

        let usageData = try await service.fetchUsage(forceRefresh: false)
        let requestCount = await networkService.requestCount
        let lastEndpoint = await networkService.lastEndpoint

        XCTAssertEqual(usageData, expectedUsage)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(lastEndpoint)
    }

    func test_userForcesRefresh_bypassesCacheAndUpdatesCache() async throws {
        let cachedUsage = makeUsageData(percentage: TestConstants.cachedPercentage)
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: TestConstants.sessionResetDateString,
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: nil,
            sonnetResetAt: nil
        )
        let expectedSessionPercentage = TestConstants.sessionPercentage
        let expectedWeeklyPercentage = TestConstants.weeklyPercentage
        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )
        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)
        await cacheRepository.set(cachedUsage)

        let usageData = try await service.fetchUsage(forceRefresh: true)
        let cachedData = await cacheRepository.cachedData
        let requestCount = await networkService.requestCount

        XCTAssertEqual(usageData.sessionUsage.utilization, expectedSessionPercentage)
        XCTAssertEqual(usageData.weeklyUsage.utilization, expectedWeeklyPercentage)
        XCTAssertEqual(cachedData?.sessionUsage.utilization, expectedSessionPercentage)
        XCTAssertEqual(cachedData?.weeklyUsage.utilization, expectedWeeklyPercentage)
        XCTAssertEqual(requestCount, 1)
    }

    func test_userWithCachedOrganization_fetchesUsageFromCachedOrg() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: TestConstants.sessionResetDateString,
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: nil,
            sonnetResetAt: nil
        )

        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )
        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)

        _ = try await service.fetchUsage(forceRefresh: true)
        let lastEndpoint = await networkService.lastEndpoint

        let expectedPath = "/organizations/\(TestConstants.organizationUUIDString)/usage"
        XCTAssertTrue(lastEndpoint?.contains(expectedPath) == true)
    }

    func test_usageFetch_showsUsageFromApiResponse() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: TestConstants.sessionResetDateString,
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: nil,
            sonnetResetAt: nil
        )

        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)

        let usageData = try await service.fetchUsage(forceRefresh: true)

        XCTAssertEqual(usageData.sessionUsage.utilization, TestConstants.sessionPercentage)
        XCTAssertEqual(usageData.weeklyUsage.utilization, TestConstants.weeklyPercentage)
        assertDate(usageData.sessionUsage.resetAt, equalsIso8601String: TestConstants.sessionResetDateString)
        assertDate(usageData.weeklyUsage.resetAt, equalsIso8601String: TestConstants.weeklyResetDateString)
    }

    func test_usageFetch_withMissingResetAt_usesFallbackWindow() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: 0,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: nil,
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: nil,
            sonnetResetAt: nil
        )

        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)

        let usageData = try await service.fetchUsage(forceRefresh: true)

        XCTAssertEqual(usageData.sessionUsage.utilization, 0)
        XCTAssertGreaterThan(usageData.sessionUsage.resetAt.timeIntervalSinceNow, 0)
        XCTAssertLessThanOrEqual(
            usageData.sessionUsage.resetAt.timeIntervalSinceNow,
            Constants.Pacing.sessionWindow + 5
        )
    }

    /// A malformed reset timestamp must not cost the user their utilization
    /// numbers: it degrades to the synthetic pacing window instead of failing
    /// the whole response.
    func test_usageFetch_withMalformedResetAt_keepsUtilizationAndFallsBack() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: "not-a-date",
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: nil,
            sonnetResetAt: nil
        )

        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)

        let usageData = try await service.fetchUsage(forceRefresh: true)

        XCTAssertEqual(usageData.sessionUsage.utilization, TestConstants.sessionPercentage)
        XCTAssertEqual(usageData.weeklyUsage.utilization, TestConstants.weeklyPercentage)
        // The unparseable session timestamp fell back to the pacing window.
        XCTAssertEqual(
            usageData.sessionUsage.resetAt.timeIntervalSinceNow,
            Constants.Pacing.sessionWindow,
            accuracy: 5
        )
        // The well-formed weekly timestamp is untouched.
        assertDate(usageData.weeklyUsage.resetAt, equalsIso8601String: TestConstants.weeklyResetDateString)
    }

    func test_usageFetch_withSonnetUsage_showsSonnetUsage() async throws {
        let responseData = try makeUsageResponseData(
            sessionUtilization: TestConstants.sessionPercentage,
            weeklyUtilization: TestConstants.weeklyPercentage,
            sessionResetAt: TestConstants.sessionResetDateString,
            weeklyResetAt: TestConstants.weeklyResetDateString,
            sonnetUtilization: TestConstants.sonnetPercentage,
            sonnetResetAt: TestConstants.sonnetResetDateString
        )

        let networkService = NetworkServiceStub(responseData: responseData)
        let cacheRepository = CacheRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let settingsRepository = SettingsRepositoryFake()

        let service = UsageService(
            networkService: networkService,
            cacheRepository: cacheRepository,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )

        try await keychainRepository.save(
            sessionKey: TestConstants.sessionKeyValue,
            account: "default"
        )

        var settings = AppSettings.default
        settings.cachedOrganizationId = UUID(uuidString: TestConstants.organizationUUIDString)
        try await settingsRepository.save(settings)

        let usageData = try await service.fetchUsage(forceRefresh: true)

        XCTAssertEqual(usageData.sonnetUsage?.utilization, TestConstants.sonnetPercentage)
        if let resetAt = usageData.sonnetUsage?.resetAt {
            assertDate(resetAt, equalsIso8601String: TestConstants.sonnetResetDateString)
        } else {
            XCTFail("Expected sonnet usage reset date")
        }
    }

    func test_usageResponse_mapsModelScopedFableLimit() throws {
        var response = UsageAPIResponse(
            fiveHour: UsageLimitResponse(
                utilization: TestConstants.sessionPercentage,
                resetsAt: TestConstants.sessionResetDateString
            ),
            sevenDay: UsageLimitResponse(
                utilization: TestConstants.weeklyPercentage,
                resetsAt: TestConstants.weeklyResetDateString
            ),
            sevenDaySonnet: nil
        )
        response.limits = [
            ScopedUsageLimitResponse(
                percent: 31,
                resetsAt: TestConstants.weeklyResetDateString,
                scope: .init(model: .init(displayName: "Fable 5"))
            )
        ]

        let usageData = try response.toDomain()

        XCTAssertEqual(usageData.fableUsage?.utilization, 31)
        let resetAt = try XCTUnwrap(usageData.fableUsage?.resetAt)
        assertDate(resetAt, equalsIso8601String: TestConstants.weeklyResetDateString)
    }

    /// Migrated accounts null out the flat keys; every meter must come from
    /// the `limits` array alone.
    func test_usageResponse_mapsMigratedLimitsOnlyShape() throws {
        let json = """
        {
            "five_hour": null,
            "seven_day": null,
            "seven_day_sonnet": null,
            "limits": [
                {
                    "kind": "session",
                    "group": "session",
                    "percent": 12,
                    "resets_at": "\(TestConstants.sessionResetDateString)",
                    "scope": null,
                    "is_active": false
                },
                {
                    "kind": "weekly_all",
                    "group": "weekly",
                    "percent": 31,
                    "resets_at": "\(TestConstants.weeklyResetDateString)",
                    "scope": null,
                    "is_active": false
                },
                {
                    "kind": "weekly_scoped",
                    "group": "weekly",
                    "percent": 54,
                    "resets_at": "\(TestConstants.weeklyResetDateString)",
                    "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
                    "is_active": true
                }
            ]
        }
        """
        let response = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))

        let usageData = try response.toDomain()

        XCTAssertEqual(usageData.sessionUsage.utilization, 12)
        assertDate(usageData.sessionUsage.resetAt, equalsIso8601String: TestConstants.sessionResetDateString)
        XCTAssertEqual(usageData.weeklyUsage.utilization, 31)
        XCTAssertEqual(usageData.fableUsage?.utilization, 54)
    }

    /// `display_name` is a rename-prone label; the stable model id must also
    /// match, including the Mythos alias of the same underlying model.
    func test_usageResponse_mapsFableLimitByModelId() throws {
        var response = UsageAPIResponse(
            fiveHour: UsageLimitResponse(
                utilization: TestConstants.sessionPercentage,
                resetsAt: TestConstants.sessionResetDateString
            ),
            sevenDay: UsageLimitResponse(
                utilization: TestConstants.weeklyPercentage,
                resetsAt: TestConstants.weeklyResetDateString
            ),
            sevenDaySonnet: nil
        )
        response.limits = [
            ScopedUsageLimitResponse(
                kind: "weekly_scoped",
                group: "weekly",
                percent: 47,
                resetsAt: TestConstants.weeklyResetDateString,
                scope: .init(model: .init(id: "claude-fable-5", displayName: nil))
            )
        ]

        XCTAssertEqual(try response.toDomain().fableUsage?.utilization, 47)
    }

    /// Flat `seven_day_fable` (present on some cohorts) wins over `limits`.
    func test_usageResponse_prefersFlatFableKey() throws {
        var response = UsageAPIResponse(
            fiveHour: UsageLimitResponse(
                utilization: TestConstants.sessionPercentage,
                resetsAt: TestConstants.sessionResetDateString
            ),
            sevenDay: UsageLimitResponse(
                utilization: TestConstants.weeklyPercentage,
                resetsAt: TestConstants.weeklyResetDateString
            ),
            sevenDaySonnet: nil
        )
        response.sevenDayFable = UsageLimitResponse(utilization: 22, resetsAt: TestConstants.weeklyResetDateString)
        response.limits = [
            ScopedUsageLimitResponse(
                percent: 99,
                resetsAt: TestConstants.weeklyResetDateString,
                scope: .init(model: .init(displayName: "Fable"))
            )
        ]

        XCTAssertEqual(try response.toDomain().fableUsage?.utilization, 22)
    }

    /// Reset timestamps without fractional seconds must parse, and a
    /// malformed fable reset date must not fail the whole response.
    func test_usageResponse_toleratesDateFormatDrift() throws {
        var response = UsageAPIResponse(
            fiveHour: UsageLimitResponse(
                utilization: TestConstants.sessionPercentage,
                resetsAt: "2026-07-31T06:10:00+00:00"
            ),
            sevenDay: UsageLimitResponse(
                utilization: TestConstants.weeklyPercentage,
                resetsAt: "2026-08-02T08:59:59Z"
            ),
            sevenDaySonnet: nil
        )
        response.limits = [
            ScopedUsageLimitResponse(
                percent: 54,
                resetsAt: "not-a-date",
                scope: .init(model: .init(displayName: "Fable"))
            )
        ]

        let usageData = try response.toDomain()

        assertDate(usageData.sessionUsage.resetAt, equalsIso8601String: "2026-07-31T06:10:00+00:00")
        XCTAssertEqual(usageData.fableUsage?.utilization, 54)
        // Malformed date degrades to the weekly pacing fallback (a future date).
        XCTAssertGreaterThan(try XCTUnwrap(usageData.fableUsage?.resetAt), Date())
    }
}

// MARK: - Helpers

private func makeUsageResponseData(
    sessionUtilization: Double,
    weeklyUtilization: Double,
    sessionResetAt: String?,
    weeklyResetAt: String?,
    sonnetUtilization: Double?,
    sonnetResetAt: String?
) throws -> Data {
    let sonnetUsage = sonnetUtilization.map {
        UsageLimitResponse(
            utilization: $0,
            resetsAt: sonnetResetAt
        )
    }

    let response = UsageAPIResponse(
        fiveHour: UsageLimitResponse(
            utilization: sessionUtilization,
            resetsAt: sessionResetAt
        ),
        sevenDay: UsageLimitResponse(
            utilization: weeklyUtilization,
            resetsAt: weeklyResetAt
        ),
        sevenDaySonnet: sonnetUsage
    )

    return try JSONEncoder().encode(response)
}

private func makeUsageData(percentage: Double) -> UsageData {
    let resetDate = Date().addingTimeInterval(TestConstants.oneHourInterval)
    let sessionUsage = UsageLimit(utilization: percentage, resetAt: resetDate)
    let weeklyUsage = UsageLimit(utilization: TestConstants.weeklyPercentage, resetAt: resetDate)

    return UsageData(
        sessionUsage: sessionUsage,
        weeklyUsage: weeklyUsage,
        sonnetUsage: nil,
        lastUpdated: Date()
    )
}

private func assertDate(_ date: Date, equalsIso8601String isoString: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainFormatter = ISO8601DateFormatter()
    plainFormatter.formatOptions = [.withInternetDateTime]

    guard let expectedDate = formatter.date(from: isoString) ?? plainFormatter.date(from: isoString) else {
        XCTFail("Invalid ISO8601 test date: \(isoString)")
        return
    }

    XCTAssertEqual(date.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
}
