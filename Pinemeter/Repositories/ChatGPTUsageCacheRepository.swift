//
//  ChatGPTUsageCacheRepository.swift
//  Pinemeter
//

import Foundation

/// Disk-backed store for the last-good ChatGPT usage snapshot, mirroring
/// `CacheRepository`'s disk-cache idiom (same Application Support directory,
/// atomic writes, tolerant reads) but scoped to a single small file since
/// `AppModel` already holds the in-memory copy -- this store only needs to
/// survive relaunches.
actor ChatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryProtocol {
    private let fileManager: FileManager
    private let cacheURL: URL

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.init(fileManager: fileManager, appSupportBaseURL: appSupport)
    }

    internal init(fileManager: FileManager = .default, appSupportBaseURL: URL) {
        self.fileManager = fileManager

        let cacheDir = appSupportBaseURL.appendingPathComponent("com.pinemeter", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        self.cacheURL = cacheDir.appendingPathComponent("chatgpt_usage_cache.json")
    }

    func save(_ data: ChatGPTUsageData) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(data) else { return }

        try? jsonData.write(to: cacheURL, options: .atomic)
    }

    func load() async -> ChatGPTUsageData? {
        guard let jsonData = try? Data(contentsOf: cacheURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(ChatGPTUsageData.self, from: jsonData)
    }

    func clear() async {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        try? fileManager.removeItem(at: cacheURL)
    }
}
