//
//  SettingsRepositoryFake.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

actor SettingsRepositoryFake: SettingsRepositoryProtocol {
    var settings: AppSettings = .default
    var notificationState = NotificationState()

    func load() async -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) async throws {
        var settings = settings
        settings.broker.pushGeneration = max(
            settings.broker.pushGeneration,
            self.settings.broker.pushGeneration
        )
        self.settings = settings
    }

    func reservePushGeneration() async throws -> UInt64 {
        guard settings.broker.pushGeneration < UInt64.max else {
            throw SettingsRepositoryError.pushGenerationExhausted
        }
        settings.broker.pushGeneration += 1
        return settings.broker.pushGeneration
    }

    func loadNotificationState() async -> NotificationState {
        notificationState
    }

    func saveNotificationState(_ state: NotificationState) async throws {
        notificationState = state
    }
}
