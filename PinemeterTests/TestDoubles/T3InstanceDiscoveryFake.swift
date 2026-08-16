//
//  T3InstanceDiscoveryFake.swift
//  PinemeterTests
//
//  Records every `scan()` call, returning a configurable canned result.
//  Mirrors `BrokerAppModelFakeT3LivenessChecker`'s shape, but non-private so
//  more than one test file can use it. Defaults to `nil` (no scan / no
//  information), matching a machine with no T3 install and keeping tests
//  deterministic across machines that do have `~/.t3/caches` populated.
//

import Foundation
@testable import Pinemeter

actor T3InstanceDiscoveryFake: T3InstanceDiscoveryProtocol {
    private(set) var scanCallCount = 0
    private var result: [DiscoveredT3Instance]?

    init(result: [DiscoveredT3Instance]? = nil) {
        self.result = result
    }

    func setResult(_ result: [DiscoveredT3Instance]?) {
        self.result = result
    }

    func scan() async -> [DiscoveredT3Instance]? {
        scanCallCount += 1
        return result
    }
}
