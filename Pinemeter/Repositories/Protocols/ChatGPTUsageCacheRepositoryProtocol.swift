//
//  ChatGPTUsageCacheRepositoryProtocol.swift
//  Pinemeter
//

import Foundation

/// Cross-launch persistence for last-good ChatGPT usage (target invariant E:
/// `chatGPTUsageData` is memory-only otherwise, so it is nil at every app
/// launch until the first successful poll). Usage percentages are not
/// secrets; this store never persists cookies or tokens.
protocol ChatGPTUsageCacheRepositoryProtocol: Actor {
    /// Persist one account's last-good usage snapshot, replacing any prior one.
    func save(_ data: ChatGPTUsageData, account: String) async

    /// Load one account's last-good usage snapshot, ignoring staleness --
    /// callers compare `lastUpdated` against the broker's own freshness
    /// thresholds. Returns `nil` if nothing is persisted or the file is
    /// unreadable/corrupt.
    func load(account: String) async -> ChatGPTUsageData?

    /// Remove one account's persisted snapshot (explicit user disconnect only).
    func clear(account: String) async
}

/// A store that never reads or writes disk. Used as `AppModel`'s default
/// under XCTest (same test-safety pattern as `T3NullInstanceDiscovery`) so no
/// test that forgets to inject `ChatGPTUsageCacheRepositoryFake` can
/// accidentally read or write the developer's real
/// `~/Library/Application Support/com.pinemeter/chatgpt_usage_cache.json`.
actor ChatGPTUsageNullCacheRepository: ChatGPTUsageCacheRepositoryProtocol {
    func save(_ data: ChatGPTUsageData, account: String) async {}
    func load(account: String) async -> ChatGPTUsageData? { nil }
    func clear(account: String) async {}
}
