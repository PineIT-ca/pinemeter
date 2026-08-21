//
//  ChatGPTUsageCacheRepositoryFake.swift
//  PinemeterTests
//

import Foundation
@testable import Pinemeter

actor ChatGPTUsageCacheRepositoryFake: ChatGPTUsageCacheRepositoryProtocol {
    var savedData: ChatGPTUsageData?
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    init(savedData: ChatGPTUsageData? = nil) {
        self.savedData = savedData
    }

    func save(_ data: ChatGPTUsageData) async {
        savedData = data
        saveCallCount += 1
    }

    func load() async -> ChatGPTUsageData? {
        savedData
    }

    func clear() async {
        savedData = nil
        clearCallCount += 1
    }
}
