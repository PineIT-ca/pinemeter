//
//  SettingsRepository.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

private struct RemotePushState: Codable {
    let version: Int
    let remoteHosts: [RemoteHost]
    let pushGeneration: UInt64

    enum CodingKeys: String, CodingKey {
        case version
        case remoteHosts = "remote_hosts"
        case pushGeneration = "push_generation"
    }
}

/// Actor-isolated repository for app settings persistence using UserDefaults
actor SettingsRepository: SettingsRepositoryProtocol {
    private let userDefaults: UserDefaults
    private let settingsKey = "app_settings"
    private let remotePushStateKey = "remote_push_state"
    private let unreadableBackupKey = "app_settings_unreadable_backup"
    private let previousUnreadableBackupKey = "app_settings_unreadable_backup_previous"
    private var unreadableSettings = false
    private let notificationStateKey = "notification_state"
    private var highestPushGeneration: UInt64 = 0

    init(userDefaults: UserDefaults = TestSafeDefaults.standardOrIsolated) {
        self.userDefaults = TestSafeDefaults.resolve(userDefaults)
    }

    /// Load app settings from UserDefaults
    func load() async -> AppSettings {
        do {
            return try currentSettings()
        } catch {
            return restoringRemotePushState(to: .default, mainData: nil)
        }
    }

    func storedSettingsUnreadable() async -> Bool {
        unreadableSettings
    }

    func replaceUnreadableSettings(with settings: AppSettings) async throws {
        // Another writer may have repaired the blob since the warning appeared; never
        // overwrite readable settings with the in-memory fallback.
        if (try? currentSettings()) != nil { return }
        let current = restoringRemotePushState(to: .default, mainData: nil)
        backUpBeforeReplacement()
        var replacement = settings
        replacement.broker.pushGeneration = max(
            replacement.broker.pushGeneration, current.broker.pushGeneration, highestPushGeneration
        )
        try write(replacement, preservingUnknown: false)
        unreadableSettings = false
    }

    /// Back up the stored bytes before replacing them. Only the two most recent unreadable
    /// incidents are kept; a third distinct incident drops the oldest backup.
    private func backUpBeforeReplacement() {
        guard let mainData = userDefaults.data(forKey: settingsKey),
              userDefaults.data(forKey: unreadableBackupKey) != mainData else { return }
        if let earlier = userDefaults.data(forKey: unreadableBackupKey) {
            userDefaults.set(earlier, forKey: previousUnreadableBackupKey)
        }
        userDefaults.set(mainData, forKey: unreadableBackupKey)
    }

    /// Save app settings to UserDefaults
    func save(_ settings: AppSettings) async throws {
        try persist(settings)
    }

    func reservePushGeneration() async throws -> UInt64 {
        try reserveGeneration(after: 0)
    }

    func reservePushGeneration(after floor: UInt64) async throws -> UInt64 {
        try reserveGeneration(after: floor)
    }

    private func reserveGeneration(after floor: UInt64) throws -> UInt64 {
        var settings = try currentSettings()
        let current = max(settings.broker.pushGeneration, floor)
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
        let persistedGeneration = try currentSettings().broker.pushGeneration
        settings.broker.pushGeneration = max(
            settings.broker.pushGeneration,
            persistedGeneration,
            highestPushGeneration
        )
        try write(settings, preservingUnknown: true)
    }

    private func write(_ settings: AppSettings, preservingUnknown: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(settings)
        let data = try preservingUnknown ? preservingUnknownFields(in: encoded) : encoded
        let sidecar = try encoder.encode(RemotePushState(
            version: 1,
            remoteHosts: settings.broker.remoteHosts,
            pushGeneration: settings.broker.pushGeneration
        ))
        // Encode both first; publish the high-water mark before the main settings blob.
        userDefaults.set(sidecar, forKey: remotePushStateKey)
        userDefaults.set(data, forKey: settingsKey)
        highestPushGeneration = settings.broker.pushGeneration
    }

    private func preservingUnknownFields(in encoded: Data) throws -> Data {
        guard let stored = userDefaults.data(forKey: settingsKey),
              let raw = try? JSONSerialization.jsonObject(with: stored) as? [String: Any] else {
            return encoded
        }
        let extras = unknownFields(in: raw, excluding: AppSettings.ownedKeyNames)
        let brokerExtras = unknownFields(
            in: raw["broker"] as? [String: Any] ?? [:], excluding: BrokerSettings.ownedKeyNames
        )
        guard !extras.isEmpty || !brokerExtras.isEmpty else { return encoded }

        var merged = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        merged.merge(extras) { current, _ in current }
        var broker = merged["broker"] as! [String: Any]
        broker.merge(brokerExtras) { current, _ in current }
        merged["broker"] = broker
        // Deeper owned objects and arrays are replaced wholesale, never merged by row identity.
        return try JSONSerialization.data(withJSONObject: merged)
    }

    private func unknownFields(in object: [String: Any], excluding ownedKeys: Set<String>) -> [String: Any] {
        object.filter { !ownedKeys.contains($0.key) && !isCredentialKey($0.key) }
            .mapValues(scrubUnknownValue)
    }

    private func scrubUnknownValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !isCredentialKey($0.key) }.mapValues(scrubUnknownValue)
        }
        if let array = value as? [Any] {
            return array.map(scrubUnknownValue)
        }
        return value
    }

    private func isCredentialKey(_ key: String) -> Bool {
        // Normalize snake, kebab and camel case so "apiKey", "api-key" and "api_key" match alike.
        let key = key.lowercased().filter { $0 != "_" && $0 != "-" }
        return [
            "credential", "sessionkey", "sessioncookie", "cookie", "token", "secret",
            "password", "passphrase", "apikey", "privatekey", "bearer", "auth"
        ].contains { key.contains($0) }
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

    private func currentSettings() throws -> AppSettings {
        let mainData = userDefaults.data(forKey: settingsKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings: AppSettings
        if let mainData {
            do {
                settings = try decoder.decode(AppSettings.self, from: mainData)
            } catch {
                unreadableSettings = true
                if userDefaults.object(forKey: unreadableBackupKey) == nil {
                    userDefaults.set(mainData, forKey: unreadableBackupKey)
                }
                throw SettingsRepositoryError.storedSettingsUnreadable
            }
        } else {
            settings = .default
        }
        unreadableSettings = false
        return restoringRemotePushState(to: settings, mainData: mainData)
    }

    private func restoringRemotePushState(to settings: AppSettings, mainData: Data?) -> AppSettings {
        var settings = settings
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = userDefaults.data(forKey: remotePushStateKey)
            .flatMap { try? decoder.decode(RemotePushState.self, from: $0) }
            .flatMap { $0.version == 1 ? $0 : nil }
        let raw = mainData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rawBroker = raw?["broker"] as? [String: Any]
        let hasHostList = rawBroker?["remote_hosts"] is [Any]
        let hasRevision = raw?.keys.contains("settings_revision") == true
        if let sidecar, !hasHostList || (settings.broker.remoteHosts.isEmpty && !hasRevision) {
            settings.broker.remoteHosts = sidecar.remoteHosts
        }
        settings.broker.pushGeneration = max(
            settings.broker.pushGeneration, sidecar?.pushGeneration ?? 0, highestPushGeneration
        )
        highestPushGeneration = settings.broker.pushGeneration
        return settings
    }
}

enum SettingsRepositoryError: Error, Equatable {
    case storedSettingsUnreadable
    case pushGenerationExhausted
}
