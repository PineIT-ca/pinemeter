//
//  CacheRepository.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

enum AggregateQuotaState: String, Encodable, Sendable {
    case fresh
    case stale
    case error
    case unavailable
}

struct AggregateQuotaSnapshot: Encodable, Sendable {
    let generatedAt: Date
    let primaryUsage: UsageData?
    let claudeAccounts: [ClaudeAccountQuotaSnapshot]
    let chatGPT: ChatGPTQuotaSnapshot
    let gemini: GeminiQuotaSnapshot

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case sessionUsage = "session_usage"
        case weeklyUsage = "weekly_usage"
        case sonnetUsage = "sonnet_usage"
        case fableUsage = "fable_usage"
        case lastUpdated = "last_updated"
        case claudeAccounts = "claude_accounts"
        case chatGPT = "chatgpt"
        case gemini
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(claudeAccounts, forKey: .claudeAccounts)
        try container.encode(chatGPT, forKey: .chatGPT)
        try container.encode(gemini, forKey: .gemini)

        guard let primaryUsage else { return }
        try container.encode(primaryUsage.sessionUsage, forKey: .sessionUsage)
        try container.encode(primaryUsage.weeklyUsage, forKey: .weeklyUsage)
        try container.encodeIfPresent(primaryUsage.sonnetUsage, forKey: .sonnetUsage)
        try container.encodeIfPresent(primaryUsage.fableUsage, forKey: .fableUsage)
        try container.encode(primaryUsage.lastUpdated, forKey: .lastUpdated)
    }
}

struct ClaudeAccountQuotaSnapshot: Encodable, Sendable {
    let id: String
    let label: String
    let isPrimary: Bool
    let state: AggregateQuotaState
    let usage: UsageData?

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case isPrimary = "is_primary"
        case state
        case usage
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(state, forKey: .state)
        try container.encode(usage, forKey: .usage)
    }
}

struct ChatGPTQuotaSnapshot: Encodable, Sendable {
    let label: String
    let state: AggregateQuotaState
    let lastUpdated: Date?
    let rows: [ChatGPTQuotaRowSnapshot]

    private enum CodingKeys: String, CodingKey {
        case label
        case state
        case lastUpdated = "last_updated"
        case rows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(state, forKey: .state)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(rows, forKey: .rows)
    }
}

struct ChatGPTQuotaRowSnapshot: Encodable, Sendable {
    let label: String
    let usedPercent: Double
    let resetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(resetAt, forKey: .resetAt)
    }
}

struct GeminiQuotaSnapshot: Encodable, Sendable {
    struct Quota: Encodable, Sendable {
        let label: String
        let usedPercent: Double
        let resetAt: Date?
        let lastUpdated: Date

        private enum CodingKeys: String, CodingKey {
            case label
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case lastUpdated = "last_updated"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(usedPercent, forKey: .usedPercent)
            try container.encode(resetAt, forKey: .resetAt)
            try container.encode(lastUpdated, forKey: .lastUpdated)
        }
    }

    let label: String
    let state: AggregateQuotaState
    let quota: Quota?

    private enum CodingKeys: String, CodingKey {
        case label
        case state
        case quota
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(state, forKey: .state)
        try container.encode(quota, forKey: .quota)
    }
}

/// Actor-isolated two-tier cache repository
actor CacheRepository: CacheRepositoryProtocol {
    private var memoryCache: UsageData?
    private var memoryCacheTimestamp: Date?
    private let cacheTTL: TimeInterval = Constants.Cache.ttl
    private let fileManager: FileManager
    private let diskCacheURL: URL
    private let publicJSONURL: URL

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.init(
            fileManager: fileManager,
            appSupportBaseURL: appSupport,
            homeBaseURL: fileManager.homeDirectoryForCurrentUser
        )
    }

    internal init(
        fileManager: FileManager = .default,
        appSupportBaseURL: URL,
        homeBaseURL: URL
    ) {
        self.fileManager = fileManager

        let cacheDir = appSupportBaseURL.appendingPathComponent("com.pinemeter", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        self.diskCacheURL = cacheDir.appendingPathComponent("usage_cache.json")

        // Public JSON export at ~/.pinemeter/usage.json for external tools.
        let publicDir = homeBaseURL.appendingPathComponent(".pinemeter", isDirectory: true)
        try? fileManager.createDirectory(at: publicDir, withIntermediateDirectories: true)
        self.publicJSONURL = publicDir.appendingPathComponent("usage.json")
    }

    /// Get cached usage data (respects TTL)
    func get() async -> UsageData? {
        // Check in-memory cache first
        if let cached = memoryCache,
           let timestamp = memoryCacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheTTL {
            return cached
        }

        // Memory cache is stale or missing
        return nil
    }

    /// Cache primary Claude usage in memory and disk.
    func set(_ data: UsageData) async {
        memoryCache = data
        memoryCacheTimestamp = Date()
        await saveToDisk(data)
    }

    /// Invalidate only private primary-Claude cache artifacts.
    func invalidate() async {
        memoryCache = nil
        memoryCacheTimestamp = nil
        removeCacheFile(at: diskCacheURL)
    }

    /// Atomically write the current normalized multi-provider snapshot.
    func writeAggregateSnapshot(_ snapshot: AggregateQuotaSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(snapshot) else { return }
        writePublicJSON(jsonData, to: publicJSONURL)
    }

    /// Get last known data from disk (ignores TTL) for offline display
    func getLastKnown() async -> UsageData? {
        await loadFromDisk()
    }

    // MARK: - Private Methods

    private func saveToDisk(_ data: UsageData) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(data) else {
            return
        }

        do {
            try jsonData.write(to: diskCacheURL, options: .atomic)
        } catch {
            // Silently fail
        }

    }

    private func writePublicJSON(_ jsonData: Data, to url: URL) {
        do {
            try jsonData.write(to: url, options: .atomic)
        } catch {
            // Silently fail - external tools location is optional
        }
    }

    private func loadFromDisk() async -> UsageData? {
        loadUsageData(from: diskCacheURL)
    }

    private func loadUsageData(from url: URL) -> UsageData? {
        guard let jsonData = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(UsageData.self, from: jsonData)
        } catch {
            return nil
        }
    }

    private func removeCacheFile(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }
}
