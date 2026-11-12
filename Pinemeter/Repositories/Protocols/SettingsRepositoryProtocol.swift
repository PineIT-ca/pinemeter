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

    /// Whether the last read found saved settings that could not be decoded.
    func storedSettingsUnreadable() async -> Bool

    /// Replace saved settings only after explicit user confirmation, retaining the backup.
    func replaceUnreadableSettings(with settings: AppSettings) async throws

    /// Persist and return the next monotonic remote-push generation.
    func reservePushGeneration() async throws -> UInt64

    /// Persist the next generation above both local state and the supplied floor.
    func reservePushGeneration(after floor: UInt64) async throws -> UInt64

    /// Load notification state
    func loadNotificationState() async -> NotificationState

    /// Save notification state
    func saveNotificationState(_ state: NotificationState) async throws
}

extension SettingsRepositoryProtocol {
    func storedSettingsUnreadable() async -> Bool { false }

    func replaceUnreadableSettings(with settings: AppSettings) async throws {
        try await save(settings)
    }

    func reservePushGeneration() async throws -> UInt64 {
        try await reservePushGeneration(after: 0)
    }

    // Compatibility for test doubles; production provides an actor-critical implementation.
    func reservePushGeneration(after floor: UInt64) async throws -> UInt64 {
        var settings = await load()
        let current = max(settings.broker.pushGeneration, floor)
        guard current < UInt64.max else {
            throw SettingsRepositoryError.pushGenerationExhausted
        }
        settings.broker.pushGeneration = current + 1
        try await save(settings)
        return settings.broker.pushGeneration
    }
}
