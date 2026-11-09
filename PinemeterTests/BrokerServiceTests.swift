//
//  BrokerServiceTests.swift
//  PinemeterTests
//
//  Hermetic unit suite for the broker runtime 07-01 stubbed and 07-03 fills
//  in: persisted cooldowns with the CLI read-merge, T3 liveness, and the full
//  BrokerService tool surface (pick/status/down/up/refresh) exercised against
//  an injected spy decide-function rather than the real engine, per the plan's
//  file-ownership note.
//

import XCTest
@testable import Pinemeter

final class BrokerServiceTests: XCTestCase {
    func test_pickForT3_constrainsOnlyThisRequestAndKeepsPolicyDenies() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = BrokerCandidate(route: .t3, instance: "denied", model: "claude-sonnet-5")
        let policy = BrokerFixture.policy(
            roles: ["review": ["native/claude-fable-5", denied.id, "t3:blocked/claude-sonnet-5", "t3:reviewInstance/claude-sonnet-5"]],
            callers: ["claude-code": BrokerCallerPolicy(routes: [.native, .t3], denyCandidates: [denied], denyInstances: ["blocked"])]
        )
        let service = BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: FakeT3LivenessChecker(), now: { BrokerFixture.now })
        await service.updateOracleSnapshot(BrokerFixture.oracle())
        await service.updateT3Liveness(BrokerFixture.reachable("denied", "blocked", "reviewInstance"))

        let ordinary = try await service.pick(role: "review", caller: nil)
        XCTAssertEqual(ordinary.route, .native)
        let constrained = try await service.pickForT3(role: "review", caller: nil)
        XCTAssertEqual(constrained.invocation, .t3Dispatch(model: "claude-sonnet-5", instanceId: "reviewInstance"))
        XCTAssertNotNil(constrained.decisionID)
        let later = try await service.pick(role: "review", caller: nil)
        XCTAssertEqual(later.route, .native)
    }

    func test_pickForT3_doesNotReopenDisallowedT3Route() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = BrokerFixture.policy(
            roles: ["review": ["native/claude-fable-5", "t3/claude-sonnet-5"]],
            callers: ["claude-code": BrokerCallerPolicy(routes: [.native])],
            allowForcedDegraded: ["review": false]
        )
        let service = pricingService(dir: directory, policy: policy)
        await service.updateOracleSnapshot(BrokerFixture.oracle())
        await service.updateT3Liveness(BrokerFixture.reachable("claudeAgent"))
        do {
            _ = try await service.pickForT3(role: "review", caller: nil)
            XCTFail("A T3-only request must preserve the caller's route restrictions")
        } catch let error as BrokerError {
            guard case .noHeadroom = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func test_pickForT3_retriesThroughTheSameEngineWithoutOpeningNativeRoute() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = BrokerFixture.policy(roles: ["review": ["native/claude-fable-5", "t3/claude-sonnet-5"]],
            allowForcedDegraded: ["review": false])
        let service = BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: FakeT3LivenessChecker(result: BrokerFixture.reachable("claudeAgent")), now: { BrokerFixture.now })
        await service.updateOracleSnapshot(BrokerFixture.oracle())
        let decision = try await service.pickForT3(role: "review", caller: nil)
        XCTAssertEqual(decision.route, .t3)
        XCTAssertFalse(decision.degraded)
    }

    func test_localRouteRowsUseStoredLoadAndEngineLevelWithoutProbe() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerPolicy.default
        policy.localRoutes = [BrokerLocalRoutesViewTests.route()]
        let broker = pricingService(dir: directory, policy: policy)
        await broker.setLocalLoad(BrokerLocalRoutesViewTests.fixtureLoad())
        let rows = await broker.localRouteRows(now: BrokerLocalRoutesViewTests.now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .idle)
        XCTAssertEqual(rows.first?.priceLevel, 0)
        let off = await broker.localRouteRows(now: BrokerLocalRoutesViewTests.now, brokerEnabled: false)
        XCTAssertEqual(off.first?.state, .brokerOff)
        XCTAssertNil(off.first?.priceLevel)
    }
    func test_statusResidencyAdvertisesSupportAndCurrentRoleMap() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = pricingService(dir: directory, policy: .default)
        for roles: [String: BrokerResidency] in [[:], ["execution": .controlled, "verification": .controlled], [:]] {
            var policy = BrokerPolicy.default
            policy.residencyRoles = roles
            await broker.updatePolicy(policy)
            let status = await broker.status()
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.jsonString().utf8)) as? [String: Any])
            let residency = try XCTUnwrap(root["residency"] as? [String: Any])
            XCTAssertEqual(Set(residency.keys), ["supported", "roles"])
            XCTAssertEqual(residency["supported"] as? Bool, true)
            XCTAssertEqual(residency["roles"] as? [String: String], roles.mapValues(\.rawValue))
        }
    }

    func test_probeCycleReachesControlledPick() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerLocalRouteTests.policy()
        policy.localRoutes[0].residency = .controlled
        let broker = pricingService(dir: directory, policy: policy)
        await broker.updateT3Liveness(BrokerLocalRouteTests.t3)
        let ready = expectation(description: "snapshot published")
        let capture = LocalProbeCapture()
        let prober = LocalModelLoadService(transport: { request in
            await capture.record(request)
            return .init(status: 200, body: request.url?.path == "/models" ? LocalModelLoadServiceTests.loaded : LocalModelLoadServiceTests.idle)
        }, clock: { BrokerFixture.now }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await prober.configure(routes: policy.localRoutes)
        await prober.start { load in
            await broker.setLocalLoad(load)
            await capture.publish(load)
            if !load.hosts.isEmpty { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 2)
        let load = try await capture.waitForLoad()
        XCTAssertEqual(load.hosts.first?.state, "ok")
        let pick = try await broker.pick(role: "explore", caller: nil, residency: .controlled)
        XCTAssertEqual(pick.model, policy.localRoutes[0].candidate)
        XCTAssertEqual(pick.residency, "controlled")
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 2)
        await prober.stop()
    }

    func test_pickNeverFetchesForOrdinaryOverrideAndScoreCalls() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerLocalRouteTests.policy(); policy.localRoutes[0].residency = .controlled
        let broker = BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: FakeT3LivenessChecker(), now: { BrokerFixture.now })
        await broker.updateT3Liveness(BrokerLocalRouteTests.t3)
        let capture = LocalProbeCapture()
        let prober = LocalModelLoadService(transport: { request in
            await capture.record(request)
            return .init(status: 200, body: request.url?.path == "/models" ? LocalModelLoadServiceTests.loaded : LocalModelLoadServiceTests.idle)
        }, clock: { BrokerFixture.now }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await prober.configure(routes: policy.localRoutes)
        await prober.start { load in await broker.setLocalLoad(load); await capture.publish(load) }
        _ = try await capture.waitForLoad()
        for _ in 0..<20 { _ = try await broker.pick(role: "explore", caller: nil, residency: .controlled) }
        for _ in 0..<5 { _ = try await broker.pick(role: "explore", caller: nil, overrideCandidate: policy.localRoutes[0].candidate, residency: .controlled) }
        for _ in 0..<5 { _ = await broker.scoreSnapshot(role: "explore") }
        let count = await capture.requests.count
        XCTAssertEqual(count, 2)
        await prober.stop()
    }

    func test_pendingCountsOnlySameHostPicksStrictlyAfterObservation() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableClock(BrokerFixture.now)
        var policy = BrokerLocalRouteTests.policy(); policy.localRoutes[0].residency = .controlled
        let spy = DecideSpy { call in
            try BrokerEngine.decide(role: call.role, caller: call.caller, policy: call.policy,
                oracle: call.oracle, cooldowns: call.cooldowns, now: call.now, t3: call.t3,
                demand: call.demand, health: call.health, local: call.local, residency: call.residency)
        }
        let broker = BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: FakeT3LivenessChecker(), now: { clock.now }, decide: spy.decide)
        await broker.updateT3Liveness(BrokerLocalRouteTests.t3)
        await broker.setLocalLoad(BrokerLocalRouteTests.snapshot(age: 0))
        _ = try await broker.pick(role: "explore", caller: nil, residency: .controlled)
        clock.now = clock.now.addingTimeInterval(1)
        _ = try await broker.pick(role: "explore", caller: nil, residency: .controlled)
        clock.now = clock.now.addingTimeInterval(1)
        _ = try await broker.pick(role: "explore", caller: nil, residency: .controlled)
        XCTAssertEqual(spy.calls.map { $0.local?.hosts.first?.pending }, [0, 0, 1])
        var fresh = BrokerLocalRouteTests.snapshot(age: 0); fresh.hosts[0].observedAt = clock.now
        await broker.setLocalLoad(fresh)
        _ = try await broker.pick(role: "explore", caller: nil, residency: .controlled)
        XCTAssertEqual(spy.calls.last?.local?.hosts.first?.pending, 0)
    }

    func test_explicitRefreshRequestsCycleWithoutAwaitingTransport() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = pricingService(dir: directory, policy: .default)
        let capture = LocalProbeCapture()
        let gate = ProbeResponseGate()
        let prober = LocalModelLoadService(transport: { request in
            await capture.record(request); await gate.wait()
            return .init(status: 200, body: Data(#"{"data":[]}"#.utf8))
        }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await prober.configure(routes: [BrokerLocalRouteTests.route()])
        await prober.start { await capture.publish($0) }
        await broker.setLocalRefreshHandler { await prober.requestCycle() }
        try await broker.refresh()
        let loads = await capture.loads
        XCTAssertTrue(loads.isEmpty)
        await gate.release()
        _ = try await capture.waitForLoad()
        let calls = await capture.requests.count
        XCTAssertEqual(calls, 1)
        await prober.stop()
    }

    func test_statusLocalUsesSnapshotAndEngineGatesWithoutPrivateFields() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerLocalRouteTests.policy(); policy.localRoutes[0].residency = .controlled
        var second = BrokerLocalRouteTests.route(); second.host = "gpu-b"; second.candidate = "t3:pi/lab/other-model"; second.preset = "other-model"; second.probeURL = "http://gpu-b.example:11434"
        policy.localRoutes.append(second)
        let broker = pricingService(dir: directory, policy: policy)
        let load = BrokerLocalRouteTests.snapshot()
        await broker.setLocalLoad(load)
        let status = await broker.status()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.jsonString().utf8)) as? [String: Any])
        let local = try XCTUnwrap(root["local"] as? [String: Any])
        XCTAssertEqual(Set(local.keys), ["hosts", "routes"])
        let hosts = try XCTUnwrap(local["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(Set(hosts[0].keys), ["host", "state", "ageSeconds", "loadedPreset", "slotsBusy", "slotsTotal", "pending"])
        XCTAssertEqual(hosts[0]["host"] as? String, "gpu-a")
        XCTAssertEqual(hosts[0]["ageSeconds"] as? Double, 10)
        XCTAssertEqual(hosts[0]["loadedPreset"] as? String, "qwen-27b")
        let routes = try XCTUnwrap(local["routes"] as? [[String: Any]])
        XCTAssertEqual(routes.count, 2)
        for (index, route) in routes.enumerated() {
            let declaration = policy.localRoutes[index]
            let reason = BrokerLocalRouting.gate(route: declaration, load: load, now: BrokerFixture.now)
            XCTAssertEqual(route["available"] as? Bool, reason == nil)
            XCTAssertEqual(route["reason"] as? String, reason)
            XCTAssertEqual(route["priceLevel"] as? Int, reason == nil ? BrokerLocalRouting.level(route: declaration, load: load, now: BrokerFixture.now) : nil)
            XCTAssertTrue(Set(route.keys).isSubset(of: ["candidate", "residency", "enabled", "roles", "available", "priceLevel", "reason"]))
        }
        let data = try JSONSerialization.data(withJSONObject: local)
        let text = String(decoding: data, as: UTF8.self)
        for prohibited in ["http", "example", "probe", "params", "next_token", "n_ctx"] { XCTAssertFalse(text.contains(prohibited)) }
        await broker.updatePolicy(.default)
        let empty = await broker.status()
        let emptyRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.jsonString().utf8)) as? [String: Any])
        XCTAssertNil(emptyRoot["local"])
    }

    func test_changedProbeDeclarationInvalidatesOldHostObservation() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = BrokerLocalRouteTests.policy()
        let broker = pricingService(dir: directory, policy: policy)
        await broker.setLocalLoad(BrokerLocalRouteTests.snapshot())
        policy.localRoutes[0].probeURL = "http://gpu-b.example:11434"
        await broker.updatePolicy(policy)
        let status = await broker.status()
        XCTAssertEqual(status.local?.hosts.count, 0)
        XCTAssertEqual(status.local?.routes.first?.reason, "local host 'gpu-a' load unknown")
    }

    func test_pickResidency_reachesDecide() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? "claude-code")
        }
        let service = pricingService(dir: directory, policy: .default, decide: spy.decide)
        _ = try await service.pick(role: "explore", caller: nil, residency: .controlled)
        XCTAssertEqual(spy.calls.first?.residency, .controlled)
        XCTAssertTrue(spy.calls.allSatisfy { $0.residency == .controlled })
    }

    func test_pickResidency_survivesRefreshRetry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = DecideSpy { _ in throw cappedReviewRole }
        let service = pricingService(dir: directory, policy: .default, decide: spy.decide)
        do {
            _ = try await service.pick(role: "explore", caller: nil, residency: .controlled)
            XCTFail("expected exhaustion")
        } catch BrokerError.noHeadroom { }
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertTrue(spy.calls.allSatisfy { $0.residency == .controlled })
    }

    func test_pickResidencyAndT3Child_surviveRefreshRetry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = DecideSpy { _ in throw cappedReviewRole }
        let service = pricingService(dir: directory, policy: .default, decide: spy.decide)
        do {
            _ = try await service.pick(role: "explore", caller: nil, overrideCandidate: nil, executionContext: .t3Child, residency: .controlled)
            XCTFail("expected exhaustion")
        } catch BrokerError.noHeadroom { }
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertTrue(spy.calls.allSatisfy { $0.residency == .controlled && $0.executionContext == .t3Child })
    }

    func testRecentPickResidencyCopiesDecision() async throws {
        for restricted in [true, false] {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var p = BrokerLocalRouteTests.policy(); p.localRoutes[0].residency = .controlled
            let engine: BrokerService.DecideFunction = { role, caller, policy, _, cooldowns, now, _, demand, health, _, _, _ in
                try BrokerEngine.decide(role: role, caller: caller, policy: policy,
                    oracle: BrokerLocalRouteTests.oracle(gated: false), cooldowns: cooldowns, now: now,
                    t3: BrokerLocalRouteTests.t3, demand: demand, health: health,
                    local: BrokerLocalRouteTests.snapshot(), residency: restricted ? .controlled : nil)
            }
            let service = pricingService(dir: directory, policy: p, decide: engine)
            let d = try await service.pick(role: "explore", caller: nil)
            let recent = await service.recentPicksSnapshot
            let pick = try XCTUnwrap(recent.first)
            XCTAssertEqual(pick.residency, restricted ? "controlled" : nil)
            XCTAssertEqual(pick.routeClass, restricted ? "controlled" : nil)
            XCTAssertEqual(pick.residency, d.residency)
            XCTAssertEqual(pick.routeClass, d.routeClass)
            for text in [pick.candidate, pick.reason] {
                XCTAssertFalse(text.contains("http"))
                XCTAssertFalse(text.contains(".example"))
                XCTAssertFalse(text.contains("/slots"))
            }
            XCTAssertFalse(Mirror(reflecting: pick).children.contains { ($0.label ?? "").lowercased().contains("prompt") })
        }
    }

    // MARK: - BrokerCooldownStore (Task 1)

    /// Behavior test 1: down(...) persists availableAt; a fresh store
    /// instance pointed at the same file sees it (restart survival); up
    /// deletes the key.
    func test_downUntilClamp_matchesGoAndPersists() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String, TimeInterval, TimeInterval)] = [
            ("past", -3600, 60),
            ("under one minute", 30, 60),
            ("two hours", 7200, 7200),
            ("thirty days", 2592000, 604800),
        ]
        for (name, delta, expected) in cases {
            let dir = try makeTempDirectory()
            let cliFile = dir.appendingPathComponent("cli.json")
            let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { now })
            let deadline = try await store.down(target: "native", until: now.addingTimeInterval(delta))
            XCTAssertEqual(deadline, now.addingTimeInterval(expected), name)
            let restarted = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { now })
            let snapshot = await restarted.mergedSnapshot()
            XCTAssertEqual(snapshot["native"], deadline, name)
        }
    }

    func test_down_persistsAcrossRestart_upDeletesTheKey() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        let availableAt = try await store.down(target: "t3/claude-fable-5", minutes: 30)
        XCTAssertEqual(availableAt.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.001)

        let restarted = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })
        var snapshot = await restarted.mergedSnapshot()
        XCTAssertEqual(
            snapshot["t3/claude-fable-5"]?.timeIntervalSince1970,
            availableAt.timeIntervalSince1970,
            "a fresh store instance pointed at the same file must see the persisted entry"
        )

        try await restarted.up(target: "t3/claude-fable-5")
        snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["t3/claude-fable-5"], "up must delete the key")
    }

    func test_reset_clearsInAppAndMasksLegacyCLICooldownsWithoutWritingItsFile() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date())
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        _ = try await store.down(target: "native/claude-fable-5", minutes: 30)
        try writeCLICooldowns(["t3:claudeAgent/claude-fable-5": clock.now.addingTimeInterval(1800)], to: cliFile)
        let cliData = try Data(contentsOf: cliFile)

        try await store.reset()

        let snapshot = await store.mergedSnapshot()
        XCTAssertEqual(snapshot, [:])
        XCTAssertEqual(try Data(contentsOf: cliFile), cliData)
    }

    func test_reset_honoursCLICooldownRecordedLater() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000.125))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })
        let existingExpiry = clock.now.addingTimeInterval(300)

        try writeCLICooldowns(["existing": existingExpiry], to: cliFile)
        try await store.reset()

        let laterExpiry = clock.now.addingTimeInterval(600)
        try writeCLICooldowns(
            ["existing": existingExpiry, "recorded-later": laterExpiry],
            to: cliFile
        )

        let snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["existing"])
        XCTAssertEqual(
            snapshot["recorded-later"]?.timeIntervalSince1970 ?? 0,
            laterExpiry.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func test_reset_suppressesCLIEntriesThatExistedAtResetUntilTheirExpiry() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000.125))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })
        let expiry = clock.now.addingTimeInterval(600)

        try writeCLICooldowns(["existing": expiry], to: cliFile)
        try await store.reset()

        var snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["existing"])
        clock.now = expiry.addingTimeInterval(-0.001)
        snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["existing"])
        clock.now = expiry
        snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["existing"])
    }

    func test_reset_honoursPreExistingCLIEntryExtendedToALaterExpiry() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000.125))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })
        let originalExpiry = clock.now.addingTimeInterval(300)

        try writeCLICooldowns(["shared": originalExpiry], to: cliFile)
        try await store.reset()

        let extendedExpiry = originalExpiry.addingTimeInterval(0.010)
        try writeCLICooldowns(["shared": extendedExpiry], to: cliFile)

        let snapshot = await store.mergedSnapshot()
        XCTAssertEqual(
            snapshot["shared"]?.timeIntervalSince1970 ?? 0,
            extendedExpiry.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func test_legacyResetMarker_decodesAndSuppressesOnlyCLIExpiriesThroughItsDate() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let inAppFile = dir.appendingPathComponent("broker-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })
        let legacyResetUntil = clock.now.addingTimeInterval(300)
        let inAppExpiry = clock.now.addingTimeInterval(600)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode([
            "__pinemeter_cli_reset__": legacyResetUntil,
            "in-app": inAppExpiry,
        ]).write(to: inAppFile)
        try writeCLICooldowns([
            "legacy-existing": clock.now.addingTimeInterval(200),
            "recorded-or-extended-later": clock.now.addingTimeInterval(400),
        ], to: cliFile)

        let snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["__pinemeter_cli_reset__"])
        XCTAssertNil(snapshot["legacy-existing"])
        XCTAssertNotNil(snapshot["in-app"])
        XCTAssertNotNil(snapshot["recorded-or-extended-later"])
    }

    func test_resetSuppression_doesNotConsumeCapacityAndPrunesExpiredEntries() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let inAppFile = dir.appendingPathComponent("broker-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000.125))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        try writeCLICooldowns([
            "expires-first": clock.now.addingTimeInterval(1),
            "stays-active": clock.now.addingTimeInterval(300),
        ], to: cliFile)
        try await store.reset()
        for index in 0..<BrokerCooldownStore.maxEntries {
            _ = try await store.down(target: "in-app-\(index)", minutes: 10)
        }

        clock.now = clock.now.addingTimeInterval(2)
        let snapshot = await store.mergedSnapshot()
        XCTAssertEqual(snapshot.count, BrokerCooldownStore.maxEntries)

        let data = try Data(contentsOf: inAppFile)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let suppressions = try XCTUnwrap(object["__pinemeter_cli_reset__"] as? [String: Any])
        XCTAssertTrue(object["in-app-0"] is String, "older builds must still decode real cooldowns")
        XCTAssertNil(suppressions["expires-first"])
        XCTAssertNotNil(suppressions["stays-active"])
        XCTAssertEqual(suppressions.count, 1)
    }

    /// Behavior test 2: minutes clamps to 1...10080 and defaults to 60;
    /// entries whose availableAt is in the past are dropped on read.
    func test_downMinutes_clampsAndDefaults_pastEntriesSelfExpireOnRead() async throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date())
        let store = BrokerCooldownStore(
            storeDirectory: dir,
            cliCooldownsURL: dir.appendingPathComponent("cli.json"),
            now: { clock.now }
        )

        let defaultAvailable = try await store.down(target: "defaulted", minutes: nil)
        XCTAssertEqual(defaultAvailable.timeIntervalSince(clock.now), 60 * 60, accuracy: 0.001)

        let low = try await store.down(target: "too-low", minutes: 0)
        XCTAssertEqual(low.timeIntervalSince(clock.now), 1 * 60, accuracy: 0.001)

        let high = try await store.down(target: "too-high", minutes: 999_999)
        XCTAssertEqual(high.timeIntervalSince(clock.now), 10080 * 60, accuracy: 0.001)

        clock.now = clock.now.addingTimeInterval(120)
        let snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["too-low"], "an availableAt now in the past must self-expire on read")
        XCTAssertNotNil(snapshot["defaulted"])
        XCTAssertNotNil(snapshot["too-high"])
    }

    /// Behavior test 3: a CLI-only entry appears in the merge; a shared key
    /// resolves to the LATER availableAt; a missing/unparseable CLI file
    /// merges as empty (fail-empty, no throw); in-app down/up never write it.
    func test_mergedSnapshot_unionsCLIFile_laterAvailableAtWins_failEmptyOnUnparseableFile() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date())
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        // No CLI file yet: merges as empty, in-app entries still visible.
        _ = try await store.down(target: "t3", minutes: 10)
        var snapshot = await store.mergedSnapshot()
        XCTAssertNotNil(snapshot["t3"])

        // A CLI-only key appears in the merge.
        let cliOnlyAvailableAt = clock.now.addingTimeInterval(500)
        try writeCLICooldowns(["codex": cliOnlyAvailableAt], to: cliFile)
        snapshot = await store.mergedSnapshot()
        XCTAssertEqual(
            snapshot["codex"]?.timeIntervalSince1970 ?? 0,
            cliOnlyAvailableAt.timeIntervalSince1970,
            accuracy: 1
        )

        // Shared key, CLI later: CLI wins.
        let inAppAvailableAt = try await store.down(target: "shared", minutes: 5)
        let cliLaterAvailableAt = inAppAvailableAt.addingTimeInterval(3600)
        try writeCLICooldowns(
            ["codex": cliOnlyAvailableAt, "shared": cliLaterAvailableAt],
            to: cliFile
        )
        snapshot = await store.mergedSnapshot()
        XCTAssertEqual(
            snapshot["shared"]?.timeIntervalSince1970 ?? 0,
            cliLaterAvailableAt.timeIntervalSince1970,
            accuracy: 1
        )

        // Shared key, CLI earlier: in-app (later) wins.
        let cliEarlierAvailableAt = inAppAvailableAt.addingTimeInterval(-60)
        try writeCLICooldowns(["shared": cliEarlierAvailableAt], to: cliFile)
        snapshot = await store.mergedSnapshot()
        XCTAssertEqual(
            snapshot["shared"]?.timeIntervalSince1970 ?? 0,
            inAppAvailableAt.timeIntervalSince1970,
            accuracy: 1
        )

        // An unparseable CLI file merges as empty; in-app entries survive.
        try Data("not json at all".utf8).write(to: cliFile)
        snapshot = await store.mergedSnapshot()
        XCTAssertNil(snapshot["codex"])
        XCTAssertNotNil(snapshot["t3"])
        XCTAssertNotNil(snapshot["shared"])
    }

    /// Regression coverage for review finding C2: a CLI file containing both
    /// a fractional-seconds timestamp (the real shape JS `Date.toISOString()`
    /// always writes) and a whole-seconds timestamp must merge both, not
    /// silently drop the fractional entries.
    func test_mergedSnapshot_parsesFractionalAndWholeSecondCLITimestampsInTheSameFile() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        let fractionalAvailableAt = clock.now.addingTimeInterval(300)
        let wholeSecondAvailableAt = clock.now.addingTimeInterval(600)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSecondFormatter = ISO8601DateFormatter()

        let object: [String: String] = [
            "fractional": fractionalFormatter.string(from: fractionalAvailableAt),
            "wholeSecond": wholeSecondFormatter.string(from: wholeSecondAvailableAt),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: cliFile)

        let snapshot = await store.mergedSnapshot()
        XCTAssertEqual(
            snapshot["fractional"]?.timeIntervalSince1970 ?? 0,
            fractionalAvailableAt.timeIntervalSince1970,
            accuracy: 1,
            "a fractional-seconds CLI timestamp (the real CLI file shape) must merge"
        )
        XCTAssertEqual(
            snapshot["wholeSecond"]?.timeIntervalSince1970 ?? 0,
            wholeSecondAvailableAt.timeIntervalSince1970,
            accuracy: 1,
            "a whole-seconds CLI timestamp must still merge"
        )
    }

    func test_mergedSnapshot_rejectsOversizedSymlinkedAndOverCapacityFiles() async throws {
        let dir = try makeTempDirectory()
        let cliFile = dir.appendingPathComponent("cli-cooldowns.json")
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: cliFile, now: { clock.now })

        try Data(repeating: 0x61, count: BrokerCooldownStore.maxFileSizeBytes + 1).write(to: cliFile)
        var snapshot = await store.mergedSnapshot()
        XCTAssertTrue(snapshot.isEmpty)

        try FileManager.default.removeItem(at: cliFile)
        let symlinkTarget = dir.appendingPathComponent("symlink-target.json")
        try writeCLICooldowns(["must-not-leak": clock.now.addingTimeInterval(300)], to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: cliFile, withDestinationURL: symlinkTarget)
        snapshot = await store.mergedSnapshot()
        XCTAssertTrue(snapshot.isEmpty)

        try FileManager.default.removeItem(at: cliFile)
        let overCapacity = Dictionary(uniqueKeysWithValues: (0...BrokerCooldownStore.maxEntries).map {
            ("target-\($0)", clock.now.addingTimeInterval(300))
        })
        try writeCLICooldowns(overCapacity, to: cliFile)
        snapshot = await store.mergedSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_down_prunesExpiredEntriesBeforeCapacityCheck() async throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = BrokerCooldownStore(
            storeDirectory: dir,
            cliCooldownsURL: dir.appendingPathComponent("cli.json"),
            now: { clock.now }
        )

        for index in 0..<BrokerCooldownStore.maxEntries {
            _ = try await store.down(target: "expired-\(index)", minutes: 1)
        }
        clock.now = clock.now.addingTimeInterval(61)

        _ = try await store.down(target: "replacement", minutes: 1)

        let snapshot = await store.mergedSnapshot()
        XCTAssertEqual(Set(snapshot.keys), ["replacement"])
    }

    func test_cooldownStoreSource_neverWritesTheCLIFile() throws {
        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/BrokerCooldownStore.swift")
        XCTAssertFalse(
            source.contains("writer(data, cliCooldownsURL)"),
            "the CLI cooldowns file must never be a write target"
        )
        XCTAssertTrue(
            source.contains("writer(data, storeURL)"),
            "the in-app file is the only write target"
        )
    }

    func testCooldownWriteFailureLeavesMemoryAndRestartStateUnchanged() async throws {
        let directory = try makeTempDirectory()
        let cliURL = directory.appendingPathComponent("cli.json")
        let seed = BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: cliURL)
        _ = try await seed.down(target: "t3", minutes: 30)
        let before = try Data(contentsOf: directory.appendingPathComponent("broker-cooldowns.json"))
        let failing = BrokerCooldownStore(
            storeDirectory: directory,
            cliCooldownsURL: cliURL,
            writer: { _, _ in throw BrokerServiceAuditTestError.writeFailed }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await failing.down(target: "codex", minutes: 30)
        }
        await XCTAssertThrowsErrorAsync {
            try await failing.up(target: "t3")
        }

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("broker-cooldowns.json")),
            before
        )
        let restarted = await BrokerCooldownStore(
            storeDirectory: directory,
            cliCooldownsURL: cliURL
        ).mergedSnapshot()
        XCTAssertNotNil(restarted["t3"])
        XCTAssertNil(restarted["codex"])
    }

    // MARK: - T3LivenessChecker (Task 1)

    func test_livenessProbeRunsWhenRefreshCallerWasCancelled() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pointerFile = directory.appendingPathComponent("server-runtime.json")
        try Data("{\"origin\":\"http://127.0.0.1:5199\"}".utf8).write(to: pointerFile)
        let checker = T3LivenessChecker(
            pointerFileURL: pointerFile,
            probeFn: { _ in
                if Task.isCancelled { return (nil, "cancelled") }
                return (200, nil)
            },
            inferProbeFn: { _ in
                if Task.isCancelled { return (nil, "cancelled") }
                return (200, nil)
            }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await checker.checkLiveness(
                instances: [
                    T3InstanceConfig(id: "codex", name: "Codex"),
                    T3InstanceConfig(id: "pi", name: "Local", healthProbeOrigin: "http://model-host:11434"),
                ]
            )
        }

        let result = await task.value
        XCTAssertEqual(result["codex"]?.reachable, true)
        XCTAssertEqual(result["pi"]?.reachable, true)
        XCTAssertEqual(result["t3:pi/default"]?.reachable, true)
    }

    /// Behavior test 4: a missing or origin-less pointer file returns
    /// reachable false without any HTTP request (probe counter stays 0).
    func test_liveness_missingOrOriginLessPointerFile_isUnreachableWithoutHTTPRequest() async throws {
        let dir = try makeTempDirectory()
        let pointerFile = dir.appendingPathComponent("server-runtime.json")
        let counter = ProbeCallCounter()
        let checker = T3LivenessChecker(pointerFileURL: pointerFile, probeFn: { origin in
            await counter.record(origin)
            return (200, nil)
        })

        var result = await checker.checkLiveness(
            instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]
        )
        XCTAssertEqual(result["claudeAgent"]?.reachable, false)
        XCTAssertEqual(result["claudeAgent"]?.why, "no server-runtime.json")

        try Data("{\"pid\":123}".utf8).write(to: pointerFile)
        result = await checker.checkLiveness(
            instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]
        )
        XCTAssertEqual(result["claudeAgent"]?.reachable, false, "an origin-less pointer file must fail closed")

        let calls = await counter.calls
        XCTAssertEqual(calls.count, 0, "no HTTP probe should be attempted without a resolvable origin")
    }

    /// Behavior test 5: any HTTP status (including 401) is reachable; a
    /// connection error returns reachable false with the error text as why;
    /// the request timeout is pinned to 0.75s.
    func test_liveness_anyHTTPStatusIsReachable_connectionErrorIsNot_requestTimeoutIsPinned() async throws {
        let dir = try makeTempDirectory()
        let pointerFile = dir.appendingPathComponent("server-runtime.json")
        try Data("{\"origin\":\"http://127.0.0.1:5199\"}".utf8).write(to: pointerFile)

        let statusChecker = T3LivenessChecker(pointerFileURL: pointerFile, probeFn: { _ in (401, nil) })
        let statusResult = await statusChecker.checkLiveness(
            instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]
        )
        XCTAssertEqual(statusResult["claudeAgent"]?.reachable, true, "401 is reachable, not an auth failure")
        XCTAssertEqual(statusResult["claudeAgent"]?.why, "http 401")

        let errorChecker = T3LivenessChecker(
            pointerFileURL: pointerFile,
            probeFn: { _ in (nil, "connect failed: ECONNREFUSED") }
        )
        let errorResult = await errorChecker.checkLiveness(
            instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]
        )
        XCTAssertEqual(errorResult["claudeAgent"]?.reachable, false)
        XCTAssertEqual(errorResult["claudeAgent"]?.why, "connect failed: ECONNREFUSED")

        let source = try sourceContents(relativePath: "Pinemeter/Services/Broker/T3LivenessChecker.swift")
        XCTAssertTrue(source.contains("timeoutInterval = 0.75"), "the request timeout must be pinned to 0.75s")
        XCTAssertTrue(source.contains("/api/orchestration/snapshot"), "the probe path must be pinned")
    }

    func test_liveness_dedupesProbesPerBaseURL_andFansOutToSharedInstances() async throws {
        let dir = try makeTempDirectory()
        let pointerFile = dir.appendingPathComponent("server-runtime.json")
        try Data("{\"origin\":\"http://127.0.0.1:5199\"}".utf8).write(to: pointerFile)

        let counter = ProbeCallCounter()
        let checker = T3LivenessChecker(pointerFileURL: pointerFile, probeFn: { origin in
            await counter.record(origin)
            return (200, nil)
        })

        let instances = [
            T3InstanceConfig(id: "claudeAgent", name: "Claude Agent"),
            T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)"),
            T3InstanceConfig(id: "override", name: "Override", baseURLOverride: "http://127.0.0.1:9999"),
        ]

        let result = await checker.checkLiveness(instances: instances)

        XCTAssertEqual(result["claudeAgent"]?.reachable, true)
        XCTAssertEqual(result["claude_secondary"]?.reachable, true)
        XCTAssertEqual(result["override"]?.reachable, true)

        let calls = await counter.calls
        XCTAssertEqual(calls.count, 2, "one probe per distinct base URL, fanned out to instances sharing it")
        XCTAssertEqual(Set(calls), Set(["http://127.0.0.1:5199", "http://127.0.0.1:9999"]))
    }

    func test_piLivenessRequiresInferHealthAfterT3Responds() async throws {
        let dir = try makeTempDirectory()
        let pointerFile = dir.appendingPathComponent("server-runtime.json")
        try Data("{\"origin\":\"http://127.0.0.1:5199\"}".utf8).write(to: pointerFile)
        let checker = T3LivenessChecker(
            pointerFileURL: pointerFile,
            probeFn: { _ in (200, nil) },
            inferProbeFn: { origin in
                XCTAssertEqual(origin, "http://model-host.example:11434")
                return (503, nil)
            }
        )
        let result = await checker.checkLiveness(instances: [
            T3InstanceConfig(id: "pi", name: "omp", healthProbeOrigin: "http://model-host.example:11434"),
            T3InstanceConfig(id: "codex", name: "Codex"),
        ])
        XCTAssertEqual(result["pi"]?.reachable, true)
        XCTAssertEqual(result["t3:pi/default"]?.reachable, false)
        XCTAssertEqual(result["t3:pi/default"]?.why, "infer unhealthy: http 503")
        XCTAssertEqual(result["codex"]?.reachable, true)

        let healthy = T3LivenessChecker(
            pointerFileURL: pointerFile,
            probeFn: { _ in (200, nil) },
            inferProbeFn: { _ in (200, nil) }
        )
        let healthyResult = await healthy.checkLiveness(instances: [
            T3InstanceConfig(id: "pi", name: "omp", healthProbeOrigin: "http://model-host.example:11434")
        ])
        XCTAssertEqual(healthyResult["t3:pi/default"]?.reachable, true)

        let offline = T3LivenessChecker(
            pointerFileURL: pointerFile,
            probeFn: { _ in (200, nil) },
            inferProbeFn: { _ in (nil, "connect failed") }
        )
        let offlineResult = await offline.checkLiveness(instances: [
            T3InstanceConfig(id: "pi", name: "omp", healthProbeOrigin: "http://model-host.example:11434")
        ])
        XCTAssertEqual(offlineResult["t3:pi/default"]?.reachable, false)
        XCTAssertEqual(offlineResult["t3:pi/default"]?.why, "infer unhealthy: connect failed")

        let unconfigured = await healthy.checkLiveness(instances: [T3InstanceConfig(id: "pi", name: "omp")])
        XCTAssertEqual(unconfigured["t3:pi/default"]?.reachable, false)
        XCTAssertEqual(unconfigured["t3:pi/default"]?.why, "infer health origin not configured")
    }

    // MARK: - BrokerService tool surface (Task 2)

    /// Behavior test 1: pick assembles the world for the injected decide
    /// function — the latest OracleSnapshot, merged cooldowns from the store,
    /// and the latest T3 signal — and records the decision in the ring buffer.
    func test_pick_assemblesOracleCooldownsAndT3ForDecide_andRecordsTheRingBuffer() async throws {
        let dir = try makeTempDirectory()
        let store = BrokerCooldownStore(
            storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
        )
        let clock = MutableClock(Date())
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(
            policy: .default,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(),
            now: { clock.now },
            decide: spy.decide
        )

        let oracle = OracleSnapshot(
            generatedAt: clock.now,
            accounts: [
                OracleSnapshot.AccountRow(
                    id: "acct-1", label: "Primary", isPrimary: true, lastUpdated: clock.now,
                    state: .fresh, session: 10, weekly: 20, sonnet: nil, fable: nil
                ),
            ],
            chatGPTState: .unavailable,
            chatGPTRows: []
        )
        await service.updateOracleSnapshot(oracle)
        _ = try await store.down(target: "t3", minutes: 15)
        let liveness = ["claudeAgent": T3Liveness(reachable: true, why: "http 200")]
        await service.updateT3Liveness(liveness)

        _ = try await service.pick(role: "planning", caller: "claude-code")

        let call = try XCTUnwrap(spy.calls.first)
        XCTAssertEqual(call.oracle, oracle)
        XCTAssertNotNil(call.cooldowns["t3"], "the merged store snapshot must reach decide")
        XCTAssertEqual(call.t3, liveness)

        let ring = await service.recentPicksSnapshot
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring.first?.role, "planning")
    }

    func test_degradedPick_postsBrokerAlertEvent() async throws {
        let alert = expectation(description: "degraded broker alert")
        let observer = NotificationCenter.default.addObserver(
            forName: .brokerDegradedPick,
            object: nil,
            queue: nil
        ) { note in
            guard let decision = note.object as? BrokerDecision, decision.degraded else { return }
            alert.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let directory = try makeTempDirectory()
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            decide: DecideSpy { call in
                makeDecision(
                    role: call.role,
                    caller: call.caller ?? BrokerPolicy.defaultCaller,
                    degraded: true,
                    reason: "lane oracle stale"
                )
            }.decide
        )

        _ = try await service.pick(role: "heavy", caller: "codex")

        await fulfillment(of: [alert], timeout: 1)
    }

    func test_retryableDegradedPick_refreshesAndRepicksBeforeReturning() async throws {
        let directory = try makeTempDirectory()
        let refreshedAt = Date()
        let spy = DecideSpy { call in
            makeDecision(
                role: call.role,
                caller: call.caller ?? BrokerPolicy.defaultCaller,
                degraded: call.oracle == nil,
                retryable: call.oracle == nil,
                reason: call.oracle == nil ? "lane oracle stale" : "ok",
                pickBasis: .quota
            )
        }
        let auditStore = BrokerAuditStore(storeDirectory: directory)
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("cli.json")
            ),
            auditStore: auditStore,
            livenessChecker: FakeT3LivenessChecker(),
            decide: spy.decide
        )
        await service.setRefreshHandler {
            await service.updateOracleSnapshot(
                OracleSnapshot(
                    generatedAt: refreshedAt,
                    accounts: [],
                    chatGPTState: .fresh,
                    chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                    chatGPTLastUpdated: refreshedAt
                )
            )
        }

        let decision = try await service.pick(role: "heavy", caller: "codex")

        XCTAssertFalse(decision.degraded)
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertEqual(decision.pickBasis, .quota)
        let records = await auditStore.recordsSnapshot
        XCTAssertEqual(records.first?.pickBasis, .quota)
    }

    // MARK: - Blocked picks

    /// The incident this path exists for: a `review` pick whose pools were all
    /// capped threw and left no trace. The throw is re-polled once, because a
    /// stale snapshot can already have rolled into a new quota window, and a
    /// pick that is still blocked after that is persisted.
    func test_noHeadroomPick_refreshesOnceAndRetries_thenRecordsABlock() async throws {
        let dir = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: dir)
        let refreshes = CallCounter()
        let spy = DecideSpy { _ in throw cappedReviewRole }
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: auditStore,
            livenessChecker: FakeT3LivenessChecker(),
            decide: spy.decide
        )
        await service.setRefreshHandler { await refreshes.increment() }

        do {
            _ = try await service.pick(role: "review", caller: "claude-code")
            XCTFail("a role that is still capped after the refresh must keep erroring")
        } catch let error as BrokerError {
            guard case .noHeadroom = error else {
                return XCTFail("expected noHeadroom, got \(error)")
            }
        }

        XCTAssertEqual(spy.calls.count, 2, "exactly one retry, never a loop")
        let refreshCount = await refreshes.count
        XCTAssertEqual(refreshCount, 1)

        let blocks = await auditStore.blocksSnapshot
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.role, "review")
        XCTAssertEqual(block.caller, "claude-code")
        XCTAssertEqual(
            block.message,
            "Broker policy error: role \'review\' has no candidate with headroom "
                + "and forced-degraded is disabled for it"
        )
        XCTAssertEqual(
            block.candidatesTried.map(\.why),
            ["weekly 99% >= 95%", "fable weekly 99% >= 97%"],
            "the trace must carry why each candidate was rejected"
        )
        XCTAssertEqual(block.oracle.weekly, 99, "and the snapshot those reasons came from")

        let records = await auditStore.recordsSnapshot
        XCTAssertTrue(records.isEmpty, "a block is never a decision record")
    }

    func test_noHeadroomPick_thatTheRefreshRepairs_returnsADecisionAndRecordsNoBlock() async throws {
        let dir = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: dir)
        let spy = DecideSpy { call in
            guard call.oracle != nil else { throw cappedReviewRole }
            return makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: auditStore,
            livenessChecker: FakeT3LivenessChecker(),
            decide: spy.decide
        )
        await service.setRefreshHandler {
            await service.updateOracleSnapshot(
                OracleSnapshot(
                    generatedAt: Date(), accounts: [], chatGPTState: .fresh, chatGPTRows: []
                )
            )
        }

        let decision = try await service.pick(role: "review", caller: "claude-code")

        XCTAssertEqual(decision.role, "review")
        XCTAssertEqual(spy.calls.count, 2)
        let blocks = await auditStore.blocksSnapshot
        XCTAssertTrue(blocks.isEmpty, "a pick that healed itself must not log a phantom block")
        let records = await auditStore.recordsSnapshot
        XCTAssertEqual(records.count, 1)
    }

    /// Re-polling quota cannot turn an unknown role or a malformed caller into
    /// a pick, so neither costs a refresh — or leaves a block.
    func test_callerInputErrors_neverRefresh_andNeverRecordABlock() async throws {
        let errors: [BrokerError] = [
            .unknownRole(role: "nonsense", known: ["review"]),
            .malformedCaller(caller: "not a caller"),
        ]

        for thrown in errors {
            let dir = try makeTempDirectory()
            let auditStore = BrokerAuditStore(storeDirectory: dir)
            let refreshes = CallCounter()
            let spy = DecideSpy { _ in throw thrown }
            let service = BrokerService(
                cooldownStore: BrokerCooldownStore(
                    storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
                ),
                auditStore: auditStore,
                livenessChecker: FakeT3LivenessChecker(),
                decide: spy.decide
            )
            await service.setRefreshHandler { await refreshes.increment() }

            do {
                _ = try await service.pick(role: "review", caller: "claude-code")
                XCTFail("expected \(thrown) to surface")
            } catch let error as BrokerError {
                XCTAssertEqual(error, thrown, "the caller\'s own error must surface unchanged")
            }

            XCTAssertEqual(spy.calls.count, 1, "no retry for an error a refresh cannot fix")
            let refreshCount = await refreshes.count
            XCTAssertEqual(refreshCount, 0)
            let blocks = await auditStore.blocksSnapshot
            XCTAssertTrue(blocks.isEmpty)
        }
    }

    /// A failed block write must never replace the no-headroom message: that
    /// message is the only thing telling the caller why the pick failed.
    func test_blockWriteFailure_stillSurfacesTheOriginalPickError() async throws {
        let dir = try makeTempDirectory()
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(
                storeDirectory: dir,
                writer: { _, _ in throw BrokerServiceAuditTestError.writeFailed }
            ),
            livenessChecker: FakeT3LivenessChecker(),
            decide: DecideSpy { _ in throw cappedReviewRole }.decide
        )

        do {
            _ = try await service.pick(role: "review", caller: "claude-code")
            XCTFail("the pick must still fail")
        } catch let error as BrokerError {
            XCTAssertEqual(error, cappedReviewRole)
        } catch {
            XCTFail("the audit failure must not replace the pick error: \(error)")
        }
    }

    /// Behavior test 2: down("t3", 45) via the tool path puts key "t3" with
    /// availableAt ≈ now + 45 min into the next decide call's cooldown map;
    /// up("t3") removes it.
    func test_downThenUp_viaToolPath_changesTheCooldownMapPassedToDecide() async throws {
        let dir = try makeTempDirectory()
        let store = BrokerCooldownStore(
            storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
        )
        let clock = MutableClock(Date())
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(
            policy: .default,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(),
            now: { clock.now },
            decide: spy.decide
        )

        try await service.down(target: "t3", minutes: 45)
        _ = try await service.pick(role: "planning", caller: nil)
        let cooledCall = try XCTUnwrap(spy.calls.last)
        let availableAt = try XCTUnwrap(cooledCall.cooldowns["t3"])
        XCTAssertEqual(availableAt.timeIntervalSince(clock.now), 45 * 60, accuracy: 1)

        try await service.up(target: "t3")
        _ = try await service.pick(role: "planning", caller: nil)
        let restoredCall = try XCTUnwrap(spy.calls.last)
        XCTAssertNil(restoredCall.cooldowns["t3"])
    }

    func test_configuredT3Instances_areValidIndependentCooldownTargets() async throws {
        let dir = try makeTempDirectory()
        let now = Date()
        let store = BrokerCooldownStore(
            storeDirectory: dir,
            cliCooldownsURL: dir.appendingPathComponent("cli.json"),
            now: { now }
        )
        let policy = BrokerPolicy(
            roles: [
                "planning": [
                    BrokerCandidate(
                        route: .t3,
                        instance: BrokerCandidate.anyInstance,
                        model: "claude-fable-5"
                    ),
                ],
            ],
            t3Instances: [
                T3InstanceConfig(id: "alpha", name: "Alpha", detectedModels: ["claude-fable-5"]),
                T3InstanceConfig(id: "beta", name: "Beta", detectedModels: ["claude-fable-5"]),
            ]
        )
        let service = BrokerService(
            policy: policy,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            now: { now }
        )

        try await service.down(target: "t3:alpha/claude-fable-5", minutes: 60)
        try await service.down(target: "t3:beta/claude-fable-5", minutes: 60)
        try await service.up(target: "t3:alpha/claude-fable-5")

        let cooldowns = await store.mergedSnapshot()
        XCTAssertNil(cooldowns["t3:alpha/claude-fable-5"])
        XCTAssertNotNil(cooldowns["t3:beta/claude-fable-5"])
    }

    func test_wildcardCooldownTarget_isRejected() async throws {
        let dir = try makeTempDirectory()
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir)
        )

        do {
            try await service.down(target: "t3:*/claude-fable-5", minutes: 60)
            XCTFail("Expected wildcard cooldown target to be rejected")
        } catch {
            XCTAssertEqual(error as? BrokerCooldownError, .invalidTarget)
        }
    }

    /// Recording an instruction check publishes a fresh `BrokerUIState` whose
    /// stamp tells an open Instructions pane to reload the stored record.
    func test_recordInstructionCheck_publishesTheLastCheckStamp() async throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date())
        let service = BrokerService(
            policy: .default,
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            instructionCheckStore: InstructionCheckStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(),
            appVersion: "1.2.3",
            setupRevision: 7,
            now: { clock.now }
        )

        let stream = await service.uiStateUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNil(try XCTUnwrap(initial).lastInstructionCheckAt)

        let report = InstructionAuditService.analyze(
            sources: [
                InstructionAuditSource(path: "~/.claude/CLAUDE.md", kind: .instructionRoot, content: nil),
            ],
            endpoint: "http://127.0.0.1:43117/mcp"
        )
        await service.recordInstructionCheck(report: report, runID: "run-1", caller: "claude-code")

        let updated = await iterator.next()
        XCTAssertEqual(try XCTUnwrap(updated).lastInstructionCheckAt, clock.now)
        let recorded = await service.latestInstructionCheck()
        XCTAssertEqual(try XCTUnwrap(recorded).caller, "claude-code")
        // The grading build is stamped by the service, not by the caller: it
        // is what the record has to be re-checked against after an update.
        XCTAssertEqual(try XCTUnwrap(recorded).gradedBy, "1.2.3")
        XCTAssertEqual(try XCTUnwrap(recorded).setupRevision, 7)
    }

    /// Behavior test 3: refresh invokes the injected refresh handler exactly
    /// once and returns only after the handler completes.
    func test_refresh_invokesTheHandlerExactlyOnce_andReturnsAfterItCompletes() async throws {
        let dir = try makeTempDirectory()
        let store = BrokerCooldownStore(
            storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
        )
        let service = BrokerService(
            policy: .default,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker()
        )
        let counter = CallCounter()
        let completionFlag = CompletionFlag()

        await service.setRefreshHandler {
            await counter.increment()
            try await Task.sleep(nanoseconds: 5_000_000)
            await completionFlag.markComplete()
        }

        try await service.refresh()

        let handlerCompleted = await completionFlag.isComplete
        XCTAssertTrue(handlerCompleted, "refresh must not return before the handler completes")

        let count = await counter.count
        XCTAssertEqual(count, 1, "the refresh handler must be invoked exactly once per refresh call")
    }

    func test_refresh_throttlesCallsInsideTenSeconds() async throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date())
        let checker = FakeT3LivenessChecker()
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: checker,
            now: { clock.now }
        )
        let counter = CallCounter()
        await service.setRefreshHandler { await counter.increment() }

        try await service.refresh()
        clock.now = clock.now.addingTimeInterval(9)
        try await service.refresh()

        let handlerCalls = await counter.count
        let livenessCalls = await checker.callCount
        XCTAssertEqual(handlerCalls, 1)
        XCTAssertEqual(livenessCalls, 1)
    }

    func test_unavailableOverride_refreshesOnceAndRetries() async throws {
        let dir = try makeTempDirectory()
        let policy = BrokerFixture.policy(
            roles: ["review": ["t3/gpt-5.6-sol"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3])],
            t3: BrokerT3Config(
                instanceByModel: ["gpt-5.6-sol": "codex"],
                defaultInstance: "claudeAgent"
            )
        )
        let checker = FakeT3LivenessChecker(
            result: ["codex": T3Liveness(reachable: true, why: "http 200")]
        )
        let refreshes = CallCounter()
        let service = BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: checker
        )
        await service.setRefreshHandler { await refreshes.increment() }

        let decision = try await service.pick(
            role: "review",
            caller: "codex",
            overrideCandidate: "t3/gpt-5.6-sol"
        )

        XCTAssertEqual(decision.source, .humanOverride)
        XCTAssertEqual(decision.model, "t3/gpt-5.6-sol")
        let livenessChecks = await checker.callCount
        let refreshCount = await refreshes.count
        XCTAssertEqual(livenessChecks, 1)
        XCTAssertEqual(refreshCount, 1)
    }

    func test_callerFilteredWildcardOverrideDoesNotRefresh() async throws {
        let dir = try makeTempDirectory()
        let policy = BrokerFixture.policy(
            roles: ["review": ["auto/claude-fable-5-1"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.codex, .t3])],
            agentModelAliases: ["claude-fable-5-1": "fable"]
        )
        let refreshes = CallCounter()
        let service = BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker()
        )
        await service.setRefreshHandler { await refreshes.increment() }

        do {
            _ = try await service.pick(
                role: "review",
                caller: "codex",
                overrideCandidate: "auto/claude-fable-5-1"
            )
            XCTFail("a structurally forbidden override must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("override rejected"))
        }

        let refreshCount = await refreshes.count
        XCTAssertEqual(refreshCount, 0)
    }

    func test_newerRefreshCannotBeOverwrittenByAnOlderProbe() async throws {
        let dir = try makeTempDirectory()
        let checker = SuspendedT3LivenessChecker()
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli-cooldowns.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            instructionCheckStore: InstructionCheckStore(storeDirectory: dir),
            livenessChecker: checker,
            decide: spy.decide
        )

        let olderRefresh = Task { await service.refreshT3Liveness() }
        await checker.waitForCallCount(1)
        let newerRefresh = Task { await service.refreshT3Liveness() }
        await checker.waitForCallCount(2)

        await checker.complete(
            call: 1,
            with: ["claudeAgent": T3Liveness(reachable: true, why: "newer")]
        )
        _ = await newerRefresh.value
        await checker.complete(
            call: 0,
            with: ["claudeAgent": T3Liveness(reachable: false, why: "older")]
        )
        _ = await olderRefresh.value

        _ = try await service.pick(role: "planning", caller: "claude-code")
        XCTAssertEqual(spy.calls.last?.t3["claudeAgent"]?.why, "newer")
    }

    func testUpdatePolicyImmediatelyFiltersRemovedLivenessAndMarksNewInstancesUnreachable() async throws {
        let dir = try makeTempDirectory()
        let oldPolicy = BrokerPolicy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(id: "removed", name: "Removed"),
                T3InstanceConfig(id: "retained", name: "Retained"),
            ]
        )
        let service = BrokerService(
            policy: oldPolicy,
            cooldownStore: BrokerCooldownStore(
                storeDirectory: dir,
                cliCooldownsURL: dir.appendingPathComponent("cli-cooldowns.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: dir),
            instructionCheckStore: InstructionCheckStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker()
        )
        await service.updateT3Liveness([
            "removed": T3Liveness(reachable: true, why: "reachable"),
            "retained": T3Liveness(reachable: true, why: "reachable"),
        ])
        let newPolicy = BrokerPolicy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(id: "retained", name: "Retained"),
                T3InstanceConfig(id: "added", name: "Added"),
            ]
        )

        await service.updatePolicy(newPolicy)

        let snapshot = await service.t3LivenessSnapshot()
        XCTAssertNil(snapshot["removed"])
        XCTAssertEqual(snapshot["retained"]?.reachable, true)
        XCTAssertEqual(snapshot["added"], T3Liveness(reachable: false, why: "not probed"))
        let status = await service.status()
        XCTAssertEqual(Set(status.t3.map(\.instanceId)), ["retained", "added"])
    }

    /// Behavior test 4: status returns server info, oracle freshness, active
    /// cooldowns, per-instance t3 reachability, policy role names, and the
    /// recent-picks count.
    func test_status_reportsServerOracleCooldownsT3RolesAndRecentPicksCount() async throws {
        let dir = try makeTempDirectory()
        let store = BrokerCooldownStore(
            storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
        )
        let clock = MutableClock(Date())
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(
            policy: .default,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(),
            now: { clock.now },
            decide: spy.decide
        )

        await service.updateServerState(.running(port: 4123))

        let generatedAt = clock.now.addingTimeInterval(-30)
        let oracle = OracleSnapshot(
            generatedAt: generatedAt,
            accounts: [
                OracleSnapshot.AccountRow(
                    id: "acct-1", label: "Primary", isPrimary: true, lastUpdated: generatedAt,
                    state: .fresh, session: 5, weekly: 6, sonnet: nil, fable: nil
                ),
            ],
            chatGPTState: .unavailable,
            chatGPTRows: []
        )
        await service.updateOracleSnapshot(oracle)
        await service.updateT3Liveness([
            "claudeAgent": T3Liveness(reachable: true, why: "http 200"),
            "t3:pi/default": T3Liveness(reachable: false, why: "infer unhealthy"),
        ])
        try await service.down(target: "codex", minutes: 20)
        _ = try await service.pick(role: "planning", caller: "claude-code")

        let status = await service.status()

        XCTAssertTrue(status.running)
        XCTAssertEqual(status.port, 4123)
        XCTAssertTrue(status.oracle.present)
        XCTAssertFalse(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
        XCTAssertEqual(status.oracle.accounts.first?.label, "Primary")
        XCTAssertEqual(status.oracle.accounts.first?.state, "fresh")
        let cooldownEntry = try XCTUnwrap(status.cooldowns.first { $0.key == "codex" })
        XCTAssertEqual(cooldownEntry.availableAt.timeIntervalSince(clock.now), 20 * 60, accuracy: 1)
        XCTAssertEqual(status.t3.first?.instanceId, "claudeAgent")
        XCTAssertEqual(status.t3.first?.reachable, true)
        XCTAssertEqual(status.t3.count, 1)
        XCTAssertEqual(status.roles, BrokerPolicy.default.roles.keys.sorted())
        XCTAssertEqual(status.recentPicksCount, 1)

        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now.addingTimeInterval(1),
                accounts: oracle.accounts,
                chatGPTState: oracle.chatGPTState,
                chatGPTRows: oracle.chatGPTRows
            )
        )
        let rollbackStatus = await service.status()
        XCTAssertFalse(rollbackStatus.oracle.stale)
        XCTAssertEqual(rollbackStatus.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_chatGPTOnlyFreshHasAgeAndIsNotStale() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [],
                chatGPTState: .fresh,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                chatGPTLastUpdated: clock.now.addingTimeInterval(-30)
            )
        )

        let status = await service.status()
        XCTAssertFalse(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_chatGPTLastGoodAgesToStaleWhileGeneratedAtAdvances() async {
        let lastGood = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableClock(lastGood.addingTimeInterval(1_201))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [],
                chatGPTState: .error,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                chatGPTLastUpdated: lastGood
            )
        )

        let status = await service.status()
        XCTAssertTrue(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 1_201, accuracy: 1)
    }

    func test_status_mixedOracleUsesNewestRealDataTimestamp() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: clock.now.addingTimeInterval(-1_200), state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .fresh,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                chatGPTLastUpdated: clock.now.addingTimeInterval(-30),
                chatGPTConfigured: true
            )
        )

        let status = await service.status()
        XCTAssertFalse(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_nonfreshClaudeCannotBeHiddenByNewerFreshChatGPT() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))

        for state in [BrokerQuotaState.stale, .error, .unavailable] {
            let service = BrokerService(now: { clock.now })
            await service.updateOracleSnapshot(
                OracleSnapshot(
                    generatedAt: clock.now,
                    accounts: [
                        OracleSnapshot.AccountRow(
                            id: "claude", label: "Claude", isPrimary: true,
                            lastUpdated: clock.now.addingTimeInterval(-60), state: state,
                            session: nil, weekly: nil, sonnet: nil, fable: nil
                        ),
                    ],
                    chatGPTState: .fresh,
                    chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                    chatGPTLastUpdated: clock.now.addingTimeInterval(-30),
                    chatGPTConfigured: true
                )
            )

            let status = await service.status()
            XCTAssertTrue(status.oracle.stale, "Claude state \(state) must make aggregate stale")
            XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
            XCTAssertEqual(status.oracle.accounts.map(\.state), [state.rawValue])
        }
    }

    func test_status_configuredNonfreshChatGPTCannotBeHiddenByFreshClaude() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))

        for state in [BrokerQuotaState.stale, .error, .unavailable] {
            let service = BrokerService(now: { clock.now })
            await service.updateOracleSnapshot(
                OracleSnapshot(
                    generatedAt: clock.now,
                    accounts: [
                        OracleSnapshot.AccountRow(
                            id: "claude", label: "Claude", isPrimary: true,
                            lastUpdated: clock.now.addingTimeInterval(-30), state: .fresh,
                            session: 10, weekly: 20, sonnet: nil, fable: nil
                        ),
                    ],
                    chatGPTState: state,
                    chatGPTRows: [],
                    chatGPTLastUpdated: clock.now.addingTimeInterval(-60),
                    chatGPTConfigured: true
                )
            )

            let status = await service.status()
            XCTAssertTrue(status.oracle.stale, "configured ChatGPT state \(state) must make aggregate stale")
            XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
            XCTAssertEqual(status.oracle.accounts.map(\.state), ["fresh"])
        }
    }

    func test_status_unconfiguredChatGPTDoesNotMakeFreshClaudeStale() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: clock.now.addingTimeInterval(-30), state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .unavailable,
                chatGPTRows: [],
                chatGPTConfigured: false
            )
        )

        let status = await service.status()
        XCTAssertFalse(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_freshConfiguredProviderWithMissingTimestampIsStale() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: nil, state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .fresh,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                chatGPTLastUpdated: clock.now.addingTimeInterval(-30),
                chatGPTConfigured: true
            )
        )

        var status = await service.status()
        XCTAssertTrue(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)

        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now.addingTimeInterval(1),
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: clock.now.addingTimeInterval(-30), state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .fresh,
                chatGPTRows: [],
                chatGPTLastUpdated: nil,
                chatGPTConfigured: true
            )
        )

        status = await service.status()
        XCTAssertTrue(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_futureProviderTimestampIsStaleWithoutHidingNewestValidAge() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: clock.now.addingTimeInterval(1), state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .fresh,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 20)],
                chatGPTLastUpdated: clock.now.addingTimeInterval(-30),
                chatGPTConfigured: true
            )
        )

        let status = await service.status()
        XCTAssertTrue(status.oracle.stale)
        XCTAssertEqual(status.oracle.ageSeconds ?? -1, 30, accuracy: 1)
    }

    func test_status_withoutOraclePreservesAbsentContract() async {
        let service = BrokerService()

        let status = await service.status()

        XCTAssertFalse(status.oracle.present)
        XCTAssertFalse(status.oracle.stale)
        XCTAssertNil(status.oracle.ageSeconds)
        XCTAssertEqual(status.oracle.accounts, [])
    }

    func test_status_encodingKeepsExistingWireKeys() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })
        await service.updateServerState(.running(port: 43117))
        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [
                    OracleSnapshot.AccountRow(
                        id: "claude", label: "Claude", isPrimary: true,
                        lastUpdated: clock.now.addingTimeInterval(-30), state: .fresh,
                        session: 10, weekly: 20, sonnet: nil, fable: nil
                    ),
                ],
                chatGPTState: .unavailable,
                chatGPTRows: []
            )
        )

        let status = await service.status()
        let json = try status.jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oracle = try XCTUnwrap(root["oracle"] as? [String: Any])
        let accounts = try XCTUnwrap(oracle["accounts"] as? [[String: Any]])

        XCTAssertEqual(
            Set(root.keys),
            Set(["running", "port", "oracle", "cooldowns", "t3", "roles", "recentPicksCount", "pricing", "residency"])
        )
        XCTAssertEqual(Set(oracle.keys), Set(["present", "stale", "ageSeconds", "accounts"]))
        XCTAssertEqual(Set(try XCTUnwrap(accounts.first).keys), Set(["id", "label", "state"]))
    }

    func test_status_oracleWithNoDataIsStaleWithNilAge() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = BrokerService(now: { clock.now })

        await service.updateOracleSnapshot(
            OracleSnapshot(
                generatedAt: clock.now,
                accounts: [],
                chatGPTState: .unavailable,
                chatGPTRows: []
            )
        )
        let status = await service.status()
        XCTAssertTrue(status.oracle.stale)
        XCTAssertNil(status.oracle.ageSeconds)
    }

    /// Behavior test 5: the ring buffer caps at 50, newest-first, with every
    /// field the UI needs (timestamp, role, caller, candidate, route,
    /// degraded, reason).
    func test_recentPicksRingBuffer_capsAt50_newestFirst_withFullFields() async throws {
        let dir = try makeTempDirectory()
        let store = BrokerCooldownStore(
            storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")
        )
        let clock = MutableClock(Date())
        let spy = DecideSpy { call in
            makeDecision(
                role: call.role,
                caller: call.caller ?? BrokerPolicy.defaultCaller,
                model: "native/candidate-\(call.role)",
                reason: "call \(call.role)"
            )
        }
        let service = BrokerService(
            policy: .default,
            cooldownStore: store,
            auditStore: BrokerAuditStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(),
            now: { clock.now },
            decide: spy.decide
        )

        for index in 0..<55 {
            clock.now = clock.now.addingTimeInterval(1)
            _ = try await service.pick(role: "role-\(index)", caller: "caller-\(index)")
        }

        let ring = await service.recentPicksSnapshot
        XCTAssertEqual(ring.count, 50, "the ring buffer must cap at 50 entries")
        XCTAssertEqual(ring.first?.role, "role-54", "newest entry must be first")
        XCTAssertEqual(ring.last?.role, "role-5", "the oldest surviving entry after the cap")

        let newest = try XCTUnwrap(ring.first)
        XCTAssertEqual(newest.caller, "caller-54")
        XCTAssertEqual(newest.candidate, "native/candidate-role-54")
        XCTAssertEqual(newest.route, "native")
        XCTAssertFalse(newest.degraded)
        XCTAssertEqual(newest.reason, "call role-54")
    }

    func testOutcomePrePhaseReportThroughServiceStillRecorded() async throws {
        let directory = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: directory)
        let service = BrokerService(auditStore: auditStore, decide: DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }.decide)
        let decision = try await service.pick(role: "planning", caller: "codex")
        let id = try XCTUnwrap(decision.decisionID)
        let result = try await service.reportLifecycle(.init(decisionID: id, status: .completed,
                                                           durationMS: 10, actualInputTokens: 1))
        XCTAssertEqual(result, .recorded)
        let records = await auditStore.recordsSnapshot
        XCTAssertNil(records.first?.outcome)
        XCTAssertEqual(records.first?.terminal?.actualInputTokens, 1)
    }

    func testPickPersistsPickBasis() async throws {
        let directory = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: directory)
        let service = BrokerService(
            auditStore: auditStore,
            decide: DecideSpy { call in
                makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller, pickBasis: .quota)
            }.decide
        )
        let decision = try await service.pick(role: "planning", caller: "claude-code")
        XCTAssertEqual(decision.pickBasis, .quota)
        let records = await auditStore.recordsSnapshot
        XCTAssertEqual(records.first?.pickBasis, .quota)
        XCTAssertEqual(records.first?.decisionID, decision.decisionID)
    }

    func testPickPersistsStableDecisionIDBeforeReturn() async throws {
        let directory = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: directory)
        let idGenerator = IDGeneratorSpy(ids: ["decision-stable"])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = BrokerService(
            auditStore: auditStore,
            now: { now },
            idGenerator: idGenerator.next,
            decide: DecideSpy { call in
                makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
            }.decide
        )

        let decision = try await service.pick(role: "planning", caller: "claude-code")

        XCTAssertEqual(decision.decisionID, "decision-stable")
        XCTAssertEqual(idGenerator.callCount, 1)
        let records = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decisionID, decision.decisionID)
        XCTAssertEqual(records.first?.timestamp, now)
        XCTAssertEqual(records.first?.role, decision.role)
        XCTAssertEqual(records.first?.caller, decision.caller)
        XCTAssertEqual(records.first?.candidate, decision.model)
        XCTAssertEqual(records.first?.route, decision.route)
        XCTAssertEqual(records.first?.agentModel, decision.agentModel)
        XCTAssertEqual(records.first?.invocation, decision.invocation)
        XCTAssertEqual(records.first?.effort, decision.effort)
        XCTAssertEqual(records.first?.reason, decision.reason)
        XCTAssertEqual(records.first?.source, decision.source)
        XCTAssertEqual(records.first?.degraded, decision.degraded)
        XCTAssertEqual(records.first?.oracle, decision.oracle)
        XCTAssertEqual(records.first?.candidatesTried, decision.candidatesTried)
    }

    func testPickReturnsNoDecisionWhenAuditAppendFails() async throws {
        let directory = try makeTempDirectory()
        let auditStore = BrokerAuditStore(
            storeDirectory: directory,
            writer: { _, _ in throw BrokerServiceAuditTestError.writeFailed }
        )
        let service = BrokerService(
            auditStore: auditStore,
            idGenerator: { "decision-failed" },
            decide: DecideSpy { call in
                makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
            }.decide
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.pick(role: "planning", caller: "claude-code")
        }

        let recentPicks = await service.recentPicksSnapshot
        let inMemoryRecords = await auditStore.recordsSnapshot
        let restartedRecords = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(recentPicks, [])
        XCTAssertEqual(inMemoryRecords, [])
        XCTAssertEqual(restartedRecords, [])
    }

    func testPickPublishesAuditPersistenceFailureAndClearsItAfterSuccess() async throws {
        let directory = try makeTempDirectory()
        let writer = FailFirstAuditWriter()
        let service = BrokerService(
            auditStore: BrokerAuditStore(storeDirectory: directory, writer: writer.write),
            idGenerator: IDGeneratorSpy(ids: ["decision-failed", "decision-success"]).next,
            decide: DecideSpy { call in
                makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
            }.decide
        )
        let updates = await service.uiStateUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertFalse(try XCTUnwrap(initial).auditPersistenceFailed)

        do {
            _ = try await service.pick(role: "planning", caller: "claude-code")
            XCTFail("Expected audit persistence failure")
        } catch let error as BrokerAuditStoreError {
            XCTAssertEqual(error, .invalidRecord)
        }
        let failed = await iterator.next()
        XCTAssertTrue(try XCTUnwrap(failed).auditPersistenceFailed)

        _ = try await service.pick(role: "planning", caller: "claude-code")
        let recovered = await iterator.next()
        XCTAssertFalse(try XCTUnwrap(recovered).auditPersistenceFailed)
        let recentPicks = await service.recentPicksSnapshot
        XCTAssertEqual(recentPicks.count, 1)
    }

    func testPickAndReportUpdateOutcomeRollup() async throws {
        let dir = try makeTempDirectory()
        let outcomes = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now })
        let service = BrokerService(auditStore: BrokerAuditStore(storeDirectory: dir), outcomeStore: outcomes,
                                    now: { BrokerFixture.now }, idGenerator: { "rollup-pick" },
                                    decide: { role, caller, _, _, _, _, _, _, _, _, _, _ in
            makeDecision(role: role, caller: caller ?? "claude-code", pickBasis: .quality)
        })
        let d = try await service.pick(role: "planning", caller: "claude-code")
        let report = BrokerLifecycleReport(decisionID: " \(d.decisionID!) ", status: .completed)
        let result = try await service.reportLifecycle(report)
        let duplicate = try await service.reportLifecycle(report)
        let finalized = try await service.reportLifecycle(.init(decisionID: d.decisionID!, status: .failed))
        let unknown = try await service.reportLifecycle(.init(decisionID: "unknown", status: .completed))
        XCTAssertEqual(result, .recorded); XCTAssertEqual(duplicate, .duplicate)
        XCTAssertEqual(finalized, .alreadyFinalized); XCTAssertEqual(unknown, .unknownDecision)
        let buckets = await outcomes.snapshot().buckets
        XCTAssertEqual(buckets.count, 1); XCTAssertEqual(buckets.first?.picks, 1); XCTAssertEqual(buckets.first?.completed, 1)
    }

    func testRecentPickCarriesTheDecisionsPickBasis() async throws {
        let service = BrokerService(auditStore: BrokerAuditStore(storeDirectory: try makeTempDirectory()),
                                    now: { BrokerFixture.now }, idGenerator: { "basis-pick" },
                                    decide: { role, caller, _, _, _, _, _, _, _, _, _, _ in
            makeDecision(role: role, caller: caller ?? "claude-code", pickBasis: .quota)
        })
        _ = try await service.pick(role: "planning", caller: "claude-code")
        let recentPicks = await service.recentPicksSnapshot
        XCTAssertEqual(recentPicks.first?.pickBasis, .quota)
    }

    func testOutcomeTrendReflectsThePickedModelAfterAPickAndACompletedReport() async throws {
        let dir = try makeTempDirectory()
        let outcomes = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now })
        let service = BrokerService(auditStore: BrokerAuditStore(storeDirectory: dir), outcomeStore: outcomes,
                                    now: { BrokerFixture.now }, idGenerator: { "trend-pick" },
                                    decide: { role, caller, _, _, _, _, _, _, _, _, _, _ in
            makeDecision(role: role, caller: caller ?? "claude-code", pickBasis: .quality)
        })
        let decision = try await service.pick(role: "planning", caller: "claude-code")
        _ = try await service.reportLifecycle(.init(decisionID: decision.decisionID!, status: .completed))

        let view = await service.outcomeTrend(role: nil, includeAllReasons: false)

        XCTAssertFalse(view.loadFailed)
        XCTAssertEqual(view.trend.role, "planning")
        XCTAssertEqual(view.trend.state, "populated")
        XCTAssertEqual(view.trend.groups.count, 1)
        XCTAssertEqual(view.trend.groups.first?.model, "claude-fable-5")
    }

    func testOutcomeTrendReportsNoDataBeforeAnyPick() async throws {
        let service = BrokerService(auditStore: BrokerAuditStore(storeDirectory: try makeTempDirectory()),
                                    outcomeStore: BrokerOutcomeStore(storeDirectory: try makeTempDirectory()),
                                    now: { BrokerFixture.now })
        let view = await service.outcomeTrend(role: nil, includeAllReasons: false)
        XCTAssertFalse(view.loadFailed)
        XCTAssertEqual(view.trend.state, "no-data")
        XCTAssertTrue(view.trend.groups.isEmpty)
    }

    func testConcurrentPicksCountBeyondAuditCapacity() async throws {
        let count = BrokerAuditStore.capacity + 1
        let gate = ConcurrentPickStart(count: count)
        let ids = IDGeneratorSpy(ids: (0..<count).map { "concurrent-\($0)" })
        let dir = try makeTempDirectory()
        let audit = BrokerAuditStore(storeDirectory: dir, writer: { _, _ in })
        let outcomes = BrokerOutcomeStore(storeDirectory: dir, writer: { _, _ in }, now: { BrokerFixture.now })
        let service = BrokerService(auditStore: audit, outcomeStore: outcomes, now: { BrokerFixture.now },
                                    idGenerator: { ids.next() }, decide: { role, caller, _, _, _, _, _, _, _, _, _, _ in
            makeDecision(role: role, caller: caller ?? "claude-code", pickBasis: .quality)
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    await gate.arrive()
                    _ = try await service.pick(role: "planning", caller: "claude-code")
                }
            }
            try await group.waitForAll()
        }
        let retained = await audit.recordsSnapshot
        let rollup = await outcomes.snapshot()
        XCTAssertEqual(retained.count, BrokerAuditStore.capacity)
        XCTAssertEqual(rollup.buckets.reduce(0) { $0 + $1.picks }, count)
        XCTAssertEqual(ids.callCount, count)
    }

    func testTerminalTransitionRetainsReviewRecordsAfterAuditEviction() async throws {
        let audit = BrokerAuditStore(storeDirectory: try makeTempDirectory(), writer: { _, _ in })
        for id in ["worker", "reviewer"] {
            try await audit.append(decision: makeDecision(role: "planning", caller: "claude-code", pickBasis: .quality).attachingDecisionID(id), timestamp: BrokerFixture.now)
        }
        let transition = try await audit.reportLifecycleWithRecords(.init(decisionID: "reviewer", status: .completed),
                            outcome: .init(reviewVerdict: .pass, reviewedDecisionIDs: ["worker"]))
        for i in 0..<BrokerAuditStore.capacity {
            try await audit.append(decision: makeDecision(role: "planning", caller: "claude-code", pickBasis: .quality).attachingDecisionID("later-\(i)"), timestamp: BrokerFixture.now)
        }
        let evicted = await audit.record(for: "reviewer")
        XCTAssertNil(evicted)
        XCTAssertEqual(transition.result, .recorded)
        XCTAssertEqual(transition.record?.terminal?.status, .completed)
        XCTAssertEqual(transition.record?.outcome?.reviewVerdict, .pass)
        XCTAssertEqual(transition.reviewed.map(\.decisionID), ["worker"])
    }

    func testOutcomeWriteFailuresNeverFailPickOrRecordedReport() async throws {
        let dir = try makeTempDirectory()
        let outcomes = BrokerOutcomeStore(storeDirectory: dir, writer: { _, _ in throw BrokerServiceAuditTestError.writeFailed }, now: { BrokerFixture.now })
        let audit = BrokerAuditStore(storeDirectory: dir)
        let service = BrokerService(auditStore: audit, outcomeStore: outcomes, now: { BrokerFixture.now },
                                    idGenerator: { "failed-rollup" }, decide: { role, caller, _, _, _, _, _, _, _, _, _, _ in
            makeDecision(role: role, caller: caller ?? "claude-code", pickBasis: .quality)
        })
        let decision = try await service.pick(role: "planning", caller: "claude-code")
        XCTAssertEqual(decision.decisionID, "failed-rollup")
        let report = BrokerLifecycleReport(decisionID: decision.decisionID!, status: .completed)
        let result = try await service.reportLifecycle(report)
        let duplicate = try await service.reportLifecycle(report)
        XCTAssertEqual(result, .recorded); XCTAssertEqual(duplicate, .duplicate)
        let snapshot = await outcomes.snapshot()
        let stored = await audit.record(for: decision.decisionID!)
        XCTAssertEqual(snapshot.buckets, [])
        XCTAssertEqual(stored?.terminal?.status, .completed)
    }

    func testReportLifecycleDelegatesOneValidatedTransition() async throws {
        let directory = try makeTempDirectory()
        let auditStore = BrokerAuditStore(storeDirectory: directory)
        try await auditStore.append(
            decision: makeDecision(role: "planning", caller: "claude-code")
                .attachingDecisionID("decision-report"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let service = BrokerService(auditStore: auditStore)
        let report = BrokerLifecycleReport(
            decisionID: "decision-report",
            status: .completed,
            sessionID: "session-1",
            durationMS: 42,
            actualOutputTokens: 10,
            actualReasoningTokens: 2
        )

        let result = try await service.reportLifecycle(report)
        XCTAssertEqual(result, .recorded)

        let restarted = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(
            restarted.first?.terminal,
            BrokerLifecycleReport(
                decisionID: report.decisionID,
                status: report.status,
                sessionID: BrokerLifecycleText.persistedIdentifier("session-1"),
                durationMS: report.durationMS,
                actualOutputTokens: report.actualOutputTokens,
                actualReasoningTokens: report.actualReasoningTokens
            )
        )
    }

    func testReportReturnsNoRecordedResultWhenAuditWriteFails() async throws {
        let directory = try makeTempDirectory()
        let seed = BrokerAuditStore(storeDirectory: directory)
        try await seed.append(
            decision: makeDecision(role: "planning", caller: "claude-code")
                .attachingDecisionID("decision-report-failed"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let before = await seed.recordsSnapshot
        let auditStore = BrokerAuditStore(
            storeDirectory: directory,
            writer: { _, _ in throw BrokerServiceAuditTestError.writeFailed }
        )
        let service = BrokerService(auditStore: auditStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await service.reportLifecycle(
                BrokerLifecycleReport(decisionID: "decision-report-failed", status: .failed)
            )
        }

        let inMemory = await auditStore.recordsSnapshot
        let restarted = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(inMemory, before)
        XCTAssertEqual(restarted, before)
    }

    // MARK: - Fixtures

    func testPickPassesLedgerDemandToDecide() async throws {
        let dir = try makeTempDirectory()
        let (policy, oracle) = pricingWorld()
        try seedPricingRollup(dir: dir, roles: ["standard"])
        let spy = DecideSpy { call in makeDecision(role: call.role, caller: call.caller ?? "claude-code") }
        let service = pricingService(dir: dir, policy: policy, decide: spy.decide)
        await service.updateOracleSnapshot(oracle)
        _ = try await service.pick(role: "standard", caller: nil)
        let demand = try XCTUnwrap(spy.calls.first?.demand)
        XCTAssertEqual(demand.historyDays, 3)
        XCTAssertTrue(demand.historySufficient)
        XCTAssertEqual(demand.roles, ["standard": 1000])
        XCTAssertEqual(demand.pools["claude:acct-primary:weekly"]?.rateMilli, 1000)
        XCTAssertEqual(demand.pools["chatgpt::Weekly"]?.rateMilli, 1000)
    }

    func testStatusReportsPricingBlock() async throws {
        let dir = try makeTempDirectory()
        let (policy, oracle) = pricingWorld()
        try seedPricingRollup(dir: dir, roles: ["standard"])
        let audit = BrokerAuditStore(storeDirectory: dir)
        try await seedPricingAudit(audit)
        let service = pricingService(dir: dir, policy: policy, audit: audit)
        await service.updateOracleSnapshot(oracle)
        let status = await service.status()
        XCTAssertTrue(status.pricing.enabled)
        XCTAssertEqual(status.pricing.historyDays, 3)
        XCTAssertTrue(status.pricing.historySufficient)
        XCTAssertEqual(status.pricing.roles, [.init(role: "standard", decisionsPerHourMilli: 1000)])
        XCTAssertEqual(status.pricing.pools.map(\.pool), ["chatgpt::Weekly", "claude:acct-primary:weekly"])
        for row in status.pricing.pools {
            XCTAssertEqual(row.forecast.state, "ok")
            XCTAssertEqual(row.forecast.rateMilli, 1000)
            XCTAssertEqual(row.forecast.windowDecisions, 10)
            XCTAssertEqual(row.forecast.ledgerDecisions, 10)
            XCTAssertEqual(row.headroomBp, row.capBp - row.usedBp)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.jsonString().utf8)) as? [String: Any])
        let pricing = try XCTUnwrap(json["pricing"] as? [String: Any])
        XCTAssertEqual(Set(pricing.keys), Set(["enabled", "historyDays", "historySufficient", "roles", "pools"]))
    }

    func testPricedPickPerformsNoRefresh() async throws {
        let dir = try makeTempDirectory()
        let (policy, oracle) = pricingWorld()
        try seedPricingRollup(dir: dir, roles: ["standard"])
        let audit = BrokerAuditStore(storeDirectory: dir)
        try await seedPricingAudit(audit)
        let service = pricingService(dir: dir, policy: policy, audit: audit)
        await service.updateOracleSnapshot(oracle)
        let refreshes = CallCounter()
        await service.setRefreshHandler { await refreshes.increment() }
        let unpriced = try BrokerEngine.decide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: BrokerFixture.now, t3: [:])
        let priced = try await service.pick(role: "standard", caller: nil)
        XCTAssertEqual(unpriced.model, "native/claude-opus-5")
        XCTAssertEqual(priced.model, "codex/gpt-6-astra")
        XCTAssertEqual(priced.pickBasis, .quota)
        let count = await refreshes.count
        XCTAssertEqual(count, 0)
    }

    func testFreshInstallPricingIsShortHistoryAndPickUnchanged() async throws {
        let dir = try makeTempDirectory()
        let (policy, oracle) = pricingWorld()
        let service = pricingService(dir: dir, policy: policy)
        await service.updateOracleSnapshot(oracle)
        let status = await service.status()
        XCTAssertFalse(status.pricing.historySufficient)
        XCTAssertEqual(status.pricing.historyDays, 0)
        XCTAssertEqual(status.pricing.roles, [])
        XCTAssertEqual(status.pricing.pools.count, 2)
        XCTAssertTrue(status.pricing.pools.allSatisfy { $0.forecast.state == "short_history" && $0.price == 1000 })
        let expected = try BrokerEngine.decide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: BrokerFixture.now, t3: [:]).attachingDecisionID("priced-pick")
        let actual = try await service.pick(role: "standard", caller: nil)
        XCTAssertEqual(try actual.jsonString(), try expected.jsonString())
    }

    func testPricingOffKeepsChainOrder() async throws {
        let dir = try makeTempDirectory()
        var (policy, oracle) = pricingWorld()
        policy.thresholds.preferExpiringQuota = false
        try seedPricingRollup(dir: dir, roles: ["standard"])
        let audit = BrokerAuditStore(storeDirectory: dir)
        try await seedPricingAudit(audit)
        let service = pricingService(dir: dir, policy: policy, audit: audit)
        await service.updateOracleSnapshot(oracle)
        let status = await service.status()
        XCTAssertFalse(status.pricing.enabled)
        XCTAssertTrue(status.pricing.historySufficient)
        XCTAssertEqual(status.pricing.pools.count, 2)
        XCTAssertTrue(status.pricing.pools.allSatisfy { $0.forecast.state == "pricing_off" && $0.price == 1000 })
        let expected = try BrokerEngine.decide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: BrokerFixture.now, t3: [:]).attachingDecisionID("priced-pick")
        let actual = try await service.pick(role: "standard", caller: nil)
        XCTAssertEqual(try actual.jsonString(), try expected.jsonString())
        XCTAssertEqual(actual.model, "native/claude-opus-5")
    }

    func testStatusPricingCapsAt32() async throws {
        let dir = try makeTempDirectory()
        let roles = ["a\u{10000}", "a\u{E000}"] + (0..<38).map { String(format: "role-%02d", $0) }
        let labels = ["A\u{10000}", "A\u{E000}"] + (0..<38).map { String(format: "Pool-%02d", $0) }
        var policy = BrokerFixture.policy(roles: [:])
        for role in roles { policy.roles[role] = [.init(route: .codex, model: "gpt-6-astra")] }
        try seedPricingRollup(dir: dir, roles: roles)
        let oracle = BrokerFixture.oracle(accounts: [], chatGPTRows: labels.reversed().map {
            .init(label: $0, usedPercent: 10, resetAt: BrokerFixture.now.addingTimeInterval(3600), windowRole: .chatGPTWeekly)
        }, chatGPTConfigured: true)
        let service = pricingService(dir: dir, policy: policy)
        await service.updateOracleSnapshot(oracle)
        let status = await service.status()
        XCTAssertEqual(status.pricing.roles.count, 32)
        XCTAssertEqual(status.pricing.pools.count, 32)
        XCTAssertEqual(status.pricing.roles.map(\.role), Array(roles.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.prefix(32)))
        XCTAssertEqual(status.pricing.pools.map(\.pool), Array(labels.map { "chatgpt::" + $0 }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }.prefix(32)))
        XCTAssertLessThan(try status.jsonString().utf8.count, 64 << 10)
    }

    func testPickRecomputesDemandAfterEachRecovery() async throws {
        for retryable in [false, true] {
            let dir = try makeTempDirectory()
            let (policy, initial) = pricingWorld()
            try seedPricingRollup(dir: dir, roles: ["standard"])
            let spy = DecideSpy { call in
                if call.oracle?.chatGPTRows.first?.label == "Weekly" {
                    if !retryable { throw cappedReviewRole }
                    return makeDecision(role: call.role, caller: "claude-code", degraded: true, retryable: true)
                }
                return makeDecision(role: call.role, caller: "claude-code")
            }
            let service = pricingService(dir: dir, policy: policy, decide: spy.decide)
            await service.updateOracleSnapshot(initial)
            let repaired = BrokerFixture.oracle(accounts: [], chatGPTRows: [.init(label: "Repaired", usedPercent: 10,
                resetAt: BrokerFixture.now.addingTimeInterval(3600), windowRole: .chatGPTWeekly)], chatGPTConfigured: true)
            await service.setRefreshHandler { await service.updateOracleSnapshot(repaired) }
            _ = try await service.pick(role: "standard", caller: nil)
            XCTAssertEqual(spy.calls.count, 2)
            XCTAssertNotNil(spy.calls[0].demand?.pools["chatgpt::Weekly"])
            XCTAssertNil(spy.calls[1].demand?.pools["chatgpt::Weekly"])
            XCTAssertEqual(spy.calls[1].demand?.pools["chatgpt::Repaired"]?.rateMilli, 1000)
        }
    }

    /// SCORE-04: `scoreSnapshot(role:)` must score from the exact same
    /// policy/oracle/demand inputs `pick` assembles, so the view never shows
    /// an order different from the one the engine actually walks.
    func testScoreSnapshotMatchesPickOrder() async throws {
        let dir = try makeTempDirectory()
        var (policy, oracle) = pricingWorld()
        policy.scoring.roles["standard"] = .init(quality: [
            "claude-opus-5": ["_default": 512], "gpt-6-astra": ["_default": 496],
        ])
        try seedPricingRollup(dir: dir, roles: ["standard"])
        let audit = BrokerAuditStore(storeDirectory: dir)
        try await seedPricingAudit(audit)
        let service = pricingService(dir: dir, policy: policy, audit: audit)
        await service.updateOracleSnapshot(oracle)

        let rawSnapshot = await service.scoreSnapshot(role: "standard")
        let snapshot = try XCTUnwrap(rawSnapshot)
        let decision = try await service.pick(role: "standard", caller: "claude-code")

        XCTAssertFalse(snapshot.isDerived)
        XCTAssertEqual(snapshot.orderRows.first?.candidate, decision.model, "the snapshot must walk the same order pick does")
        XCTAssertEqual(snapshot.moved, 1)
    }

    func testHealthSnapshotUsesEachPickTimestampIncludingRecovery() async throws {
        for retryable in [false, true] {
            let directory = try HealthTestSupport.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = HealthMutableDate(HealthTestSupport.now)
            let payload = try XCTUnwrap(BrokerHealthDocument.accept(
                body: HealthTestSupport.body("valid-two-demotions"), stored: nil,
                keys: HealthTestSupport.keys(), now: clock.now
            ).payload)
            let state = BrokerHealthState(payload: payload)
            let spy = DecideSpy { call in
                if call.now == HealthTestSupport.now {
                    if !retryable { throw cappedReviewRole }
                    return makeDecision(role: call.role, caller: "claude-code", degraded: true, retryable: true)
                }
                return makeDecision(role: call.role, caller: "claude-code")
            }
            let service = BrokerService(policy: HealthTestSupport.policy,
                cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
                auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
                now: { clock.now }, decide: spy.decide)
            await service.setModelHealth(state)
            await service.setRefreshHandler { clock.advance(3 * 86400) }
            _ = try await service.pick(role: "review", caller: nil)
            XCTAssertEqual(spy.calls.count, 2)
            for call in spy.calls { XCTAssertEqual(call.health, state.snapshot(now: call.now)) }
            XCTAssertEqual(spy.calls.first?.health?.demotions.count, 2)
            XCTAssertEqual(spy.calls.last?.health?.demotions.count, 0)
        }
    }

    func testHealthStatusMatchesCommittedGoldenCases() async throws {
        struct Expected: Decodable {
            let now: Date
            let stored_case: String?
            let use_model_health: Bool
        }
        for name in ["valid-empty", "valid-two-demotions", "lower-seq", "equal-seq-same-bytes", "tampered-payload", "expiry-at-entry", "expiry-at-document", "status-opt-out"] {
            let directory = try HealthTestSupport.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let data = try Data(contentsOf: HealthTestSupport.corpus.appendingPathComponent(name + ".expect.json"))
            let expected = try BrokerHealthDocument.decoder().decode(Expected.self, from: data)
            let stored = try expected.stored_case.map(HealthTestSupport.body)
            let keys = try HealthTestSupport.keys()
            let accepted = BrokerHealthDocument.accept(body: try HealthTestSupport.body(name), stored: stored, keys: keys, now: expected.now)
            let payload = accepted.payload ?? stored.flatMap {
                BrokerHealthDocument.accept(body: $0, stored: nil, keys: keys, now: expected.now).payload
            }
            let state = BrokerHealthState(payload: payload,
                lastCheck: .init(at: expected.now, result: accepted.category?.rawValue ?? accepted.outcome.rawValue))
            let service = HealthTestSupport.broker(directory: directory, now: { expected.now })
            var policy = HealthTestSupport.policy
            policy.thresholds.useModelHealth = expected.use_model_health
            await service.updatePolicy(policy)
            await service.setModelHealth(state)
            let status = await service.status()
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.jsonString().utf8)) as? [String: Any])
            let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(actual["health"] as? NSDictionary, golden["status"] as? NSDictionary, name)
        }
    }

    func testHealthAgeUsesWholeSecondsAndOverrideIgnoresDemotions() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = HealthTestSupport.now.addingTimeInterval(123.875)
        let service = HealthTestSupport.broker(directory: directory, now: { now })
        let acceptance = BrokerHealthDocument.accept(body: try HealthTestSupport.body("valid-two-demotions"), stored: nil,
            keys: try HealthTestSupport.keys(), now: now)
        await service.setModelHealth(.init(payload: acceptance.payload))
        let status = await service.status()
        XCTAssertEqual(status.health?.ageSeconds, 123)
        let decision = try await service.pick(role: "review", caller: nil, overrideCandidate: "native/model-alpha")
        XCTAssertEqual(decision.model, "native/model-alpha")
        XCTAssertEqual(decision.pickBasis, .humanOverride)
    }

    private func pricingWorld() -> (BrokerPolicy, OracleSnapshot) {
        var policy = BrokerFixture.policy(
            roles: ["standard": ["native/claude-opus-5", "codex/gpt-6-astra"]],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        policy.equalQuality = ["standard": [["claude-opus-5", "gpt-6-astra"]]]
        let oracle = BrokerFixture.oracle(
            accounts: [BrokerFixture.account(label: "Account A", weekly: 20,
                weeklyResetAt: BrokerFixture.now.addingTimeInterval(5 * 86400))],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 10,
                resetAt: BrokerFixture.now.addingTimeInterval(3600), windowRole: .chatGPTWeekly)],
            chatGPTConfigured: true)
        return (policy, oracle)
    }

    private func seedPricingRollup(dir: URL, roles: [String]) throws {
        let day = String(ISO8601DateFormatter().string(from: BrokerFixture.now.addingTimeInterval(-3 * 86400)).prefix(10))
        let buckets = roles.map { BrokerOutcomeBucket(day: day, role: $0, model: "claude-opus-5",
            effort: "default", pickBasis: "quality", picks: 72) }
        try JSONEncoder().encode(BrokerOutcomeRollup(buckets: buckets.sorted(by: BrokerOutcomeStore.ordered))).write(
            to: dir.appendingPathComponent(BrokerOutcomeStore.fileName))
    }

    private func seedPricingAudit(_ audit: BrokerAuditStore) async throws {
        for index in 0..<20 {
            let route: BrokerPolicy.Route = index < 10 ? .native : .codex
            let model = index < 10 ? "native/claude-opus-5" : "codex/gpt-6-astra"
            _ = try await audit.append(decision: makeDecision(role: "standard", caller: "claude-code",
                model: model, route: route, pickBasis: .quality).attachingDecisionID("seed-\(index)"),
                timestamp: BrokerFixture.now.addingTimeInterval(-3600))
        }
    }

    func test_scoreSnapshotIncludesDeclaredLocalRouteWithUnknownLoad() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = pricingService(dir: dir, policy: BrokerLocalRouteTests.policy())
        let rawSnapshot = await service.scoreSnapshot(role: "explore")
        let snapshot = try XCTUnwrap(rawSnapshot)
        XCTAssertTrue(snapshot.orderRows.contains { $0.candidate == BrokerLocalRouteTests.route().candidate })
    }

    private func pricingService(dir: URL, policy: BrokerPolicy, audit: BrokerAuditStore? = nil,
                                decide: BrokerService.DecideFunction? = nil) -> BrokerService {
        let engine: BrokerService.DecideFunction = { role, caller, policy, oracle, cooldowns, now, t3, demand, health, local, residency, executionContext in
            try BrokerEngine.decide(role: role, caller: caller, policy: policy, oracle: oracle,
                cooldowns: cooldowns, now: now, t3: t3, demand: demand, health: health, local: local, residency: residency, executionContext: executionContext)
        }
        return BrokerService(policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: dir, cliCooldownsURL: dir.appendingPathComponent("cli.json")),
            auditStore: audit ?? BrokerAuditStore(storeDirectory: dir),
            outcomeStore: BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now }),
            instructionCheckStore: InstructionCheckStore(storeDirectory: dir),
            livenessChecker: FakeT3LivenessChecker(), now: { BrokerFixture.now },
            idGenerator: { "priced-pick" }, decide: decide ?? engine)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sourceContents(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = relativePath.split(separator: "/").reduce(repositoryRoot) { url, component in
            url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// Matches the real CLI file shape: the reference broker CLI writes this file
    /// with JS `Date.toISOString()`, which always emits fractional seconds.
    private func writeCLICooldowns(_ cooldowns: [String: Date], to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: String] = [:]
        for (key, date) in cooldowns { object[key] = formatter.string(from: date) }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}

// MARK: - Test doubles

/// Thread-safe mutable injected clock. `@unchecked Sendable` guarded by a
/// lock, matching `LoopbackHTTPServer.ResumeOnce`'s established pattern for
/// callback/actor-crossing state in this codebase.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ date: Date) {
        self._now = date
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock()
            _now = newValue
            lock.unlock()
        }
    }
}

/// Records every `BrokerEngine.decide`-shaped call BrokerService assembles,
/// without depending on the real engine's gate internals (plan's
/// file-ownership note: assert the INPUTS, not decision outcomes).
private final class DecideSpy: @unchecked Sendable {
    struct Call {
        let role: String
        let caller: String?
        let policy: BrokerPolicy
        let oracle: OracleSnapshot?
        let cooldowns: [String: Date]
        let now: Date
        let t3: [String: T3Liveness]
        let demand: BrokerDemand?
        let health: BrokerHealthSnapshot?
        let local: BrokerLocalLoad?
        let residency: BrokerResidency?
        let executionContext: BrokerExecutionContext?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let decisionProvider: @Sendable (Call) throws -> BrokerDecision

    init(decisionProvider: @escaping @Sendable (Call) throws -> BrokerDecision) {
        self.decisionProvider = decisionProvider
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func decide(
        role: String,
        caller: String?,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness],
        demand: BrokerDemand?,
        health: BrokerHealthSnapshot?,
        local: BrokerLocalLoad?,
        residency: BrokerResidency?,
        executionContext: BrokerExecutionContext?
    ) throws -> BrokerDecision {
        let call = Call(
            role: role, caller: caller, policy: policy, oracle: oracle,
            cooldowns: cooldowns, now: now, t3: t3, demand: demand, health: health, local: local, residency: residency, executionContext: executionContext
        )
        lock.lock()
        _calls.append(call)
        lock.unlock()
        return try decisionProvider(call)
    }
}

private final class IDGeneratorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]
    private var _callCount = 0

    init(ids: [String]) {
        self.ids = ids
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        _callCount += 1
        return ids.removeFirst()
    }
}

/// The shape `BrokerEngine.decide` throws when every pool is over its ceiling
/// and the role forbids forcing one anyway — the `review` incident, frozen.
private let cappedReviewRole = BrokerError.noHeadroom(
    role: "review",
    candidatesTried: [
        BrokerCandidateTried(
            candidate: "native/claude-opus-5", available: false, why: "weekly 99% >= 95%"
        ),
        BrokerCandidateTried(
            candidate: "native/claude-fable-5-1", available: false, why: "fable weekly 99% >= 97%"
        ),
    ],
    oracle: BrokerOracleBlock(present: true, stale: false, session: 99, weekly: 99)
)

private enum BrokerServiceAuditTestError: Error {
    case writeFailed
}

private final class FailFirstAuditWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            shouldFail = false
            throw BrokerServiceAuditTestError.writeFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

/// Minimal stub decision, cheap to build per-test without exercising the real
/// engine. A free function so it never captures `self` of an XCTestCase into a
/// `@Sendable` closure.
private func makeDecision(
    role: String,
    caller: String,
    model: String = "native/claude-fable-5",
    route: BrokerPolicy.Route = .native,
    degraded: Bool = false,
    retryable: Bool = false,
    reason: String = "ok",
    pickBasis: BrokerPickBasis? = nil
) -> BrokerDecision {
    BrokerDecision(
        role: role,
        caller: caller,
        model: model,
        route: route,
        agentModel: route == .native ? "fable" : nil,
        invocation: .agent(model: "fable"),
        reason: reason,
        source: .policy,
        oracle: .absent,
        degraded: degraded,
        retryable: retryable,
        candidatesTried: [],
        pickBasis: pickBasis
    )
}

/// Never probes the network; returns a fixed (empty by default) liveness map.
private actor FakeT3LivenessChecker: T3LivenessCheckerProtocol {
    private let result: [String: T3Liveness]
    private(set) var callCount = 0

    init(result: [String: T3Liveness] = [:]) {
        self.result = result
    }

    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] {
        callCount += 1
        return result
    }
}

private actor SuspendedT3LivenessChecker: T3LivenessCheckerProtocol {
    private var calls: [CheckedContinuation<[String: T3Liveness], Never>?] = []

    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] {
        await withCheckedContinuation { continuation in
            calls.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }

    func complete(call index: Int, with result: [String: T3Liveness]) {
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(returning: result)
    }
}

private actor ProbeCallCounter {
    private(set) var calls: [String] = []

    func record(_ origin: String) {
        calls.append(origin)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

/// Synchronize before picks; blocking the audit actor would also block demand reads.
private actor ConcurrentPickStart {
    private let count: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(count: Int) { self.count = count }
    func arrive() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == count {
                let ready = waiting
                waiting.removeAll()
                for waiter in ready { waiter.resume() }
            }
        }
    }
}
