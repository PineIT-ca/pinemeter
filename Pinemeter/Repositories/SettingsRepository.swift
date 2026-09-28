//
//  SettingsRepository.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Actor-isolated repository for app settings persistence using UserDefaults
actor SettingsRepository: SettingsRepositoryProtocol {
    private let userDefaults: UserDefaults
    private let settingsKey = "app_settings"
    private let notificationStateKey = "notification_state"
    private var highestPushGeneration: UInt64 = 0

    init(userDefaults: UserDefaults = TestSafeDefaults.standardOrIsolated) {
        self.userDefaults = TestSafeDefaults.resolve(userDefaults)
    }

    /// Load app settings from UserDefaults
    func load() async -> AppSettings {
        guard let data = userDefaults.data(forKey: settingsKey) else {
            return .default
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let settings = try decoder.decode(AppSettings.self, from: data)
            highestPushGeneration = max(highestPushGeneration, settings.broker.pushGeneration)
            return settings
        } catch {
            // If decoding fails, return default settings
            return .default
        }
    }

    /// Save app settings to UserDefaults
    func save(_ settings: AppSettings) async throws {
        try persist(settings)
    }

    func reservePushGeneration() async throws -> UInt64 {
        var settings = decodedSettings() ?? .default
        let current = max(settings.broker.pushGeneration, highestPushGeneration)
        guard current < UInt64.max else {
            throw SettingsRepositoryError.pushGenerationExhausted
        }
        let next = current + 1
        settings.broker.pushGeneration = next
        try persist(settings)
        return next
    }

    private func persist(_ settings: AppSettings) throws {
        var settings = settings
        let persistedGeneration = decodedSettings()?.broker.pushGeneration ?? 0
        settings.broker.pushGeneration = max(
            settings.broker.pushGeneration,
            persistedGeneration,
            highestPushGeneration
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(settings)
        userDefaults.set(data, forKey: settingsKey)
        highestPushGeneration = settings.broker.pushGeneration
    }

    /// Load notification state from UserDefaults
    func loadNotificationState() async -> NotificationState {
        guard let data = userDefaults.data(forKey: notificationStateKey) else {
            return NotificationState()
        }

        let decoder = JSONDecoder()

        do {
            return try decoder.decode(NotificationState.self, from: data)
        } catch {
            return NotificationState()
        }
    }

    /// Save notification state to UserDefaults
    func saveNotificationState(_ state: NotificationState) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        userDefaults.set(data, forKey: notificationStateKey)
    }

    private func decodedSettings() -> AppSettings? {
        guard let data = userDefaults.data(forKey: settingsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppSettings.self, from: data)
    }
}

enum SettingsRepositoryError: Error, Equatable {
    case pushGenerationExhausted
}
