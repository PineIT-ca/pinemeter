//
//  AggregateUsageExportTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

@MainActor
final class AggregateUsageExportTests: XCTestCase {
    private var temporaryRoot: URL!
    private var appSupportBaseURL: URL!
    private var homeBaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregateUsageExportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        appSupportBaseURL = temporaryRoot.appendingPathComponent("Application Support", isDirectory: true)
        homeBaseURL = temporaryRoot.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportBaseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeBaseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        try super.tearDownWithError()
    }

    func test_writeAggregateSnapshotExportsAllProvidersAndLegacyPrimary() async throws {
        let primary = usage(session: 42, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let secondary = usage(session: 17, updatedAt: Date(timeIntervalSince1970: 1_699_999_999))
        let repository = makeRepository()
        let snapshot = AggregateQuotaSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            primaryUsage: primary,
            claudeAccounts: [
                ClaudeAccountQuotaSnapshot(id: "primary", label: "Work", isPrimary: true, state: .fresh, usage: primary),
                ClaudeAccountQuotaSnapshot(id: "secondary", label: "Personal", isPrimary: false, state: .fresh, usage: secondary)
            ],
            chatGPT: ChatGPTQuotaSnapshot(
                label: "ChatGPT",
                state: .fresh,
                lastUpdated: Date(timeIntervalSince1970: 1_700_000_050),
                rows: [
                    ChatGPTQuotaRowSnapshot(label: "Codex 5h", usedPercent: 33, resetAt: Date(timeIntervalSince1970: 1_700_018_000)),
                    ChatGPTQuotaRowSnapshot(label: "Codex weekly", usedPercent: 64, resetAt: nil)
                ]
            ),
            gemini: GeminiQuotaSnapshot(
                label: "Gemini",
                state: .fresh,
                quota: GeminiQuotaSnapshot.Quota(label: "Gemini API quota", usedPercent: 25, resetAt: nil, lastUpdated: Date(timeIntervalSince1970: 1_700_000_075))
            )
        )

        await repository.writeAggregateSnapshot(snapshot)

        let data = try Data(contentsOf: publicExportURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual((document["claude_accounts"] as? [[String: Any]])?.map { $0["id"] as? String }, ["primary", "secondary"])
        XCTAssertEqual(((document["chatgpt"] as? [String: Any])?["rows"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(((document["gemini"] as? [String: Any])?["quota"] as? [String: Any])?["used_percent"] as? Double, 25)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UsageData.self, from: data), primary)
    }

    func test_invalidateKeepsLastCompleteAggregateSnapshot() async throws {
        let repository = makeRepository()
        let primary = usage(session: 42, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await repository.writeAggregateSnapshot(AggregateQuotaSnapshot(
            generatedAt: .now,
            primaryUsage: primary,
            claudeAccounts: [ClaudeAccountQuotaSnapshot(id: "primary", label: "Claude", isPrimary: true, state: .fresh, usage: primary)],
            chatGPT: ChatGPTQuotaSnapshot(label: "ChatGPT", state: .unavailable, lastUpdated: nil, rows: []),
            gemini: GeminiQuotaSnapshot(label: "Gemini", state: .unavailable, quota: nil)
        ))

        await repository.set(primary)
        await repository.invalidate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: publicExportURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UsageData.self, from: Data(contentsOf: publicExportURL)), primary)
    }

    func test_writeAggregateSnapshotEncodesNestedOptionalFieldsAsNull() async throws {
        let repository = makeRepository()
        let snapshot = AggregateQuotaSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primaryUsage: nil,
            claudeAccounts: [ClaudeAccountQuotaSnapshot(id: "account", label: "Claude", isPrimary: true, state: .unavailable, usage: nil)],
            chatGPT: ChatGPTQuotaSnapshot(
                label: "ChatGPT",
                state: .unavailable,
                lastUpdated: nil,
                rows: [ChatGPTQuotaRowSnapshot(label: "Codex 5h", usedPercent: 0, resetAt: nil)]
            ),
            gemini: GeminiQuotaSnapshot(
                label: "Gemini",
                state: .fresh,
                quota: GeminiQuotaSnapshot.Quota(label: "Gemini API quota", usedPercent: 0, resetAt: nil, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000))
            )
        )

        await repository.writeAggregateSnapshot(snapshot)

        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: publicExportURL)) as? [String: Any])
        let claude = try XCTUnwrap((document["claude_accounts"] as? [[String: Any]])?.first)
        let chatGPT = try XCTUnwrap(document["chatgpt"] as? [String: Any])
        let row = try XCTUnwrap((chatGPT["rows"] as? [[String: Any]])?.first)
        let gemini = try XCTUnwrap(document["gemini"] as? [String: Any])
        let quota = try XCTUnwrap(gemini["quota"] as? [String: Any])
        XCTAssertTrue(claude["usage"] is NSNull)
        XCTAssertTrue(chatGPT["last_updated"] is NSNull)
        XCTAssertTrue(row["reset_at"] is NSNull)
        XCTAssertTrue(quota["reset_at"] is NSNull)

        let unavailableGemini = try JSONEncoder().encode(GeminiQuotaSnapshot(label: "Gemini", state: .unavailable, quota: nil))
        let unavailableDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: unavailableGemini) as? [String: Any])
        XCTAssertTrue(unavailableDocument["quota"] is NSNull)
    }

    func test_appModelExportsClaudeAccountOrderAndUnavailableProviders() async throws {
        let repository = makeRepository()
        let primary = usage(session: 42, updatedAt: .now)
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            cacheRepository: repository,
            usageService: UsageServiceStub(fetchUsageResult: .success(primary)),
            notificationService: NotificationServiceSpy()
        )
        appModel.isSetupComplete = true
        appModel.settings.claudeAccounts = [
            ClaudeAccount(id: "primary", label: "Work", organizationId: UUID(), keychainAccount: "default"),
            ClaudeAccount(id: "secondary", label: "Personal", organizationId: UUID(), keychainAccount: "secondary")
        ]

        await appModel.refreshUsage()
        await appModel.refreshAdditionalClaudeAccounts()

        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: publicExportURL)) as? [String: Any])
        XCTAssertEqual((document["claude_accounts"] as? [[String: Any]])?.map { $0["id"] as? String }, ["primary", "secondary"])
        XCTAssertEqual((document["chatgpt"] as? [String: Any])?["state"] as? String, "unavailable")
        XCTAssertEqual((document["gemini"] as? [String: Any])?["state"] as? String, "unavailable")
    }

    func test_appModelWithCustomUsageServiceAndNoRepositoryDisablesAggregateExport() async {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .success(usage(session: 42, updatedAt: .now))),
            notificationService: NotificationServiceSpy()
        )
        appModel.isSetupComplete = true

        XCTAssertNil(appModel.cacheRepository)
        await appModel.refreshUsage()
        XCTAssertNil(appModel.cacheRepository)
    }

    func test_aggregateQuotaStatePrioritizesErrorThenFreshness() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AppModel.aggregateQuotaState(generatedAt: now, lastUpdated: now, hasError: true), .error)
        XCTAssertEqual(AppModel.aggregateQuotaState(generatedAt: now, lastUpdated: now, hasError: false), .fresh)
        XCTAssertEqual(AppModel.aggregateQuotaState(generatedAt: now, lastUpdated: now.addingTimeInterval(-Constants.Refresh.stalenessThreshold - 1), hasError: false), .stale)
        XCTAssertEqual(AppModel.aggregateQuotaState(generatedAt: now, lastUpdated: nil, hasError: false), .unavailable)
    }

    private func makeRepository() -> CacheRepository {
        CacheRepository(fileManager: .default, appSupportBaseURL: appSupportBaseURL, homeBaseURL: homeBaseURL)
    }

    private var publicExportURL: URL {
        homeBaseURL.appendingPathComponent(".pinemeter", isDirectory: true).appendingPathComponent("usage.json")
    }

    private func usage(session: Double, updatedAt: Date) -> UsageData {
        UsageData(
            sessionUsage: UsageLimit(utilization: session, resetAt: Date(timeIntervalSince1970: 1_700_018_000)),
            weeklyUsage: UsageLimit(utilization: 10, resetAt: Date(timeIntervalSince1970: 1_700_086_400)),
            sonnetUsage: nil,
            lastUpdated: updatedAt
        )
    }
}
