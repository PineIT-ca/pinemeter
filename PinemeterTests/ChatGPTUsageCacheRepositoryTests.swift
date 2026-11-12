//
//  ChatGPTUsageCacheRepositoryTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class ChatGPTUsageCacheRepositoryTests: XCTestCase {
    private var temporaryRoot: URL!
    private var appSupportBaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinemeterTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        appSupportBaseURL = temporaryRoot.appendingPathComponent("Application Support", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupportBaseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        temporaryRoot = nil
        appSupportBaseURL = nil

        try super.tearDownWithError()
    }

    func test_saveThenLoadRoundTripsUsageDataWithOriginalLastUpdated() async throws {
        let repository = makeRepository()
        let lastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        let data = ChatGPTUsageData(
            rows: [
                .init(
                    label: "Codex weekly",
                    usedPercent: 63,
                    resetAt: Date(timeIntervalSince1970: 1_700_600_000),
                    sourceLabel: "rate_limit",
                    subtitle: "WHAM: rate_limit",
                    menuBarRole: .chatGPTWeekly
                )
            ],
            lastUpdated: lastUpdated
        )

        await repository.save(data, account: ChatGPTAccount.primaryKeychainAccount)
        let loaded = await repository.load(account: ChatGPTAccount.primaryKeychainAccount)

        XCTAssertEqual(loaded, data)
        XCTAssertEqual(loaded?.lastUpdated, lastUpdated)
    }

    func test_loadWithoutAnyPersistedSnapshotReturnsNil() async {
        let repository = makeRepository()

        let loaded = await repository.load(account: ChatGPTAccount.primaryKeychainAccount)

        XCTAssertNil(loaded)
    }

    func test_loadIgnoresCorruptCacheFileGracefully() async throws {
        try FileManager.default.createDirectory(at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: cacheFileURL, options: .atomic)
        let repository = makeRepository()

        let loaded = await repository.load(account: ChatGPTAccount.primaryKeychainAccount)

        XCTAssertNil(loaded)
    }

    func test_clearRemovesPersistedSnapshot() async {
        let repository = makeRepository()
        await repository.save(
            ChatGPTUsageData(rows: [], lastUpdated: Date(timeIntervalSince1970: 0)),
            account: ChatGPTAccount.primaryKeychainAccount
        )

        await repository.clear(account: ChatGPTAccount.primaryKeychainAccount)

        let loaded = await repository.load(account: ChatGPTAccount.primaryKeychainAccount)
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))
    }

    private func makeRepository() -> ChatGPTUsageCacheRepository {
        ChatGPTUsageCacheRepository(fileManager: .default, appSupportBaseURL: appSupportBaseURL)
    }

    private var cacheFileURL: URL {
        appSupportBaseURL
            .appendingPathComponent("com.pinemeter", isDirectory: true)
            .appendingPathComponent("chatgpt_usage_cache.json")
    }
}
