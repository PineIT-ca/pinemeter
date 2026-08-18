//
//  UserNotificationCenterProtocol.swift
//  Pinemeter
//
//  Created by Edd on 2026-01-09.
//

import UserNotifications

@MainActor
protocol UserNotificationCenterProtocol {
    var delegate: UNUserNotificationCenterDelegate? { get set }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}
