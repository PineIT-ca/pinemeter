//
//  SettingsRepositoryProtocol.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Protocol for app settings persistence
protocol SettingsRepositoryProtocol: Actor {
    /// Load app settings from persistent storage
    func load() async -> AppSettings

    /// Save app settings to persistent storage
    func save(_ settings: AppSettings) async throws

    /// Persist and return the next monotonic remote-push generation.
    func reservePushGeneration() async throws -> UInt64

    /// Load notification state
    func loadNotificationState() async -> NotificationState

    /// Save notification state
    func saveNotificationState(_ state: NotificationState) async throws
}

extension SettingsRepositoryProtocol {
    func reservePushGeneration() async throws -> UInt64 {
        var settings = await load()
        guard settings.broker.pushGeneration < UInt64.max else {
            throw SettingsRepositoryError.pushGenerationExhausted
        }
        settings.broker.pushGeneration += 1
        try await save(settings)
        return settings.broker.pushGeneration
    }
}
