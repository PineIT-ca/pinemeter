//
//  NotificationCenterSpy.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import UserNotifications
@testable import Pinemeter

@MainActor
final class NotificationCenterSpy: UserNotificationCenterProtocol {
    var delegate: UNUserNotificationCenterDelegate?
    var authorizationStatus: UNAuthorizationStatus = .authorized
    var shouldGrantAuthorization: Bool = true
    private(set) var requestedAuthorizationOptions: UNAuthorizationOptions?
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedAuthorizationOptions = options
        return shouldGrantAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }
}
