//
//  CacheRepositoryFake.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

actor CacheRepositoryFake: CacheRepositoryProtocol {
    var cachedData: UsageData?
    var lastKnownData: UsageData?

    func get() async -> UsageData? {
        cachedData
    }

    func set(_ data: UsageData) async {
        cachedData = data
        lastKnownData = data
    }

    func invalidate() async {
        cachedData = nil
    }

    func getLastKnown() async -> UsageData? {
        lastKnownData
    }
}
