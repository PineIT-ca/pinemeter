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

    /// Load notification state
    func loadNotificationState() async -> NotificationState

    /// Save notification state
    func saveNotificationState(_ state: NotificationState) async throws
}
