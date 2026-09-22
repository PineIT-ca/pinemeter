//
//  ChatGPTUsageCacheRepositoryFake.swift
//  PinemeterTests
//

import Foundation
@testable import Pinemeter

actor ChatGPTUsageCacheRepositoryFake: ChatGPTUsageCacheRepositoryProtocol {
    private(set) var savedDataByAccount: [String: ChatGPTUsageData] = [:]
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    init(savedData: ChatGPTUsageData? = nil, account: String = ChatGPTAccount.primaryKeychainAccount) {
        if let savedData {
            savedDataByAccount[account] = savedData
        }
    }

    /// The primary account's snapshot, which is what most tests assert on.
    var savedData: ChatGPTUsageData? {
        savedDataByAccount[ChatGPTAccount.primaryKeychainAccount]
    }

    func setSavedData(_ data: ChatGPTUsageData?, account: String = ChatGPTAccount.primaryKeychainAccount) {
        savedDataByAccount[account] = data
    }

    func save(_ data: ChatGPTUsageData, account: String) async {
        savedDataByAccount[account] = data
        saveCallCount += 1
    }

    func load(account: String) async -> ChatGPTUsageData? {
        savedDataByAccount[account]
    }

    func clear(account: String) async {
        savedDataByAccount[account] = nil
        clearCallCount += 1
    }
}
