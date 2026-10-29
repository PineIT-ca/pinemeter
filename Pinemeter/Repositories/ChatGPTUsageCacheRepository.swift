//
//  ChatGPTUsageCacheRepository.swift
//  Pinemeter
//

import CryptoKit
import Foundation

/// Disk-backed store for the last-good ChatGPT usage snapshot, mirroring
/// `CacheRepository`'s disk-cache idiom (same Application Support directory,
/// atomic writes, tolerant reads) but scoped to a single small file since
/// `AppModel` already holds the in-memory copy -- this store only needs to
/// survive relaunches.
actor ChatGPTUsageCacheRepository: ChatGPTUsageCacheRepositoryProtocol {
    private let fileManager: FileManager
    private let cacheDirectory: URL

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

        self.cacheDirectory = cacheDir
    }

    func save(_ data: ChatGPTUsageData, account: String) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(data) else { return }

        try? jsonData.write(to: cacheURL(for: account), options: .atomic)
    }

    func load(account: String) async -> ChatGPTUsageData? {
        guard let jsonData = try? Data(contentsOf: cacheURL(for: account)) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(ChatGPTUsageData.self, from: jsonData)
    }

    func clear(account: String) async {
        let url = cacheURL(for: account)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// The primary account keeps the original single-account filename so an
    /// upgrade does not lose the last-good snapshot it already wrote.
    private func cacheURL(for account: String) -> URL {
        guard account != ChatGPTAccount.primaryKeychainAccount else {
            return cacheDirectory.appendingPathComponent("chatgpt_usage_cache.json")
        }
        return cacheDirectory.appendingPathComponent("chatgpt_usage_cache_\(Self.fileToken(for: account)).json")
    }

    /// Account ids come from the provider, so they are reduced to a filename
    /// safe token rather than trusted as a path component. The truncated
    /// readable part is disambiguated by a digest of the full id, so two ids
    /// sharing a sanitized prefix cannot share a cache file.
    static func fileToken(for account: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(account.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let digest = SHA256.hash(data: Data(account.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let readable = sanitized.isEmpty ? "account" : String(sanitized.prefix(48))
        return "\(readable)-\(digest)"
    }
}
