//
//  CacheRepositoryTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class CacheRepositoryTests: XCTestCase {
    private var temporaryRoot: URL!
    private var appSupportBaseURL: URL!
    private var homeBaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinemeterTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        appSupportBaseURL = temporaryRoot.appendingPathComponent("Application Support", isDirectory: true)
        homeBaseURL = temporaryRoot.appendingPathComponent("Home", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupportBaseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeBaseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        temporaryRoot = nil
        appSupportBaseURL = nil
        homeBaseURL = nil

        try super.tearDownWithError()
    }

    func test_setWritesPrivateCacheAndPublicExportToPinemeterPathsOnly() async throws {
        let repository = makeRepository()
        let data = makeUsageData(sessionUtilization: 42)

        await repository.set(data)

        XCTAssertTrue(FileManager.default.fileExists(atPath: newPrivateCacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPublicExportURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPublicExportURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPrivateCacheURL.path))

        try XCTAssertEqual(readUsageData(from: newPrivateCacheURL), data)
        try XCTAssertEqual(readUsageData(from: newPublicExportURL), data)
    }

    func test_getLastKnownIgnoresRetiredLegacyPrivateCache() async throws {
        try writeUsageData(makeUsageData(sessionUtilization: 75), to: legacyPrivateCacheURL)

        let repository = makeRepository()

        let lastKnown = await repository.getLastKnown()

        XCTAssertNil(lastKnown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPrivateCacheURL.path))
    }

    func test_invalidateRemovesPrivateCacheAndPublicExportArtifacts() async throws {
        let repository = makeRepository()
        await repository.set(makeUsageData(sessionUtilization: 42))

        await repository.invalidate()

        let cached = await repository.get()
        let lastKnown = await repository.getLastKnown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: newPrivateCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPublicExportURL.path))
        XCTAssertNil(cached)
        XCTAssertNil(lastKnown)
    }

    private func makeRepository() -> CacheRepository {
        CacheRepository(
            fileManager: .default,
            appSupportBaseURL: appSupportBaseURL,
            homeBaseURL: homeBaseURL
        )
    }

    private var newPrivateCacheURL: URL {
        appSupportBaseURL
            .appendingPathComponent("com.pinemeter", isDirectory: true)
            .appendingPathComponent("usage_cache.json")
    }

    private var legacyPrivateCacheURL: URL {
        appSupportBaseURL
            .appendingPathComponent("com.claudemeter", isDirectory: true)
            .appendingPathComponent("usage_cache.json")
    }

    private var newPublicExportURL: URL {
        homeBaseURL
            .appendingPathComponent(".pinemeter", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    private var legacyPublicExportURL: URL {
        homeBaseURL
            .appendingPathComponent(".claudemeter", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    private func makeUsageData(sessionUtilization: Double) -> UsageData {
        UsageData(
            sessionUsage: UsageLimit(utilization: sessionUtilization, resetAt: Date(timeIntervalSince1970: 1_700_000_000)),
            weeklyUsage: UsageLimit(utilization: 10, resetAt: Date(timeIntervalSince1970: 1_700_086_400)),
            sonnetUsage: nil,
            lastUpdated: Date(timeIntervalSince1970: 1_699_999_000)
        )
    }

    private func writeUsageData(_ data: UsageData, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(data).write(to: url, options: .atomic)
    }

    private func readUsageData(from url: URL) throws -> UsageData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageData.self, from: Data(contentsOf: url))
    }
}
