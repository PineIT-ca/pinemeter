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
        self.settings = settings
    }

    func loadNotificationState() async -> NotificationState {
        notificationState
    }

    func saveNotificationState(_ state: NotificationState) async throws {
        notificationState = state
    }
}
