//
//  CacheRepositoryProtocol.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Protocol for two-tier usage data caching
protocol CacheRepositoryProtocol: Actor {
    /// Get cached usage data (respects 10-second TTL)
    func get() async -> UsageData?

    /// Cache usage data
    func set(_ data: UsageData) async

    /// Invalidate cache
    func invalidate() async

    /// Get last known data (ignores TTL) for offline display
    func getLastKnown() async -> UsageData?
}
