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
    // MARK: - BrokerCooldownStore (Task 1)

    /// Behavior test 1: down(...) persists availableAt; a fresh store
    /// instance pointed at the same file sees it (restart survival); up
    /// deletes the key.
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
            T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)"),
            T3InstanceConfig(id: "override", name: "Override", baseURLOverride: "http://127.0.0.1:9999"),
        ]

        let result = await checker.checkLiveness(instances: instances)

        XCTAssertEqual(result["claudeAgent"]?.reachable, true)
        XCTAssertEqual(result["claude_autimo"]?.reachable, true)
        XCTAssertEqual(result["override"]?.reachable, true)

        let calls = await counter.calls
        XCTAssertEqual(calls.count, 2, "one probe per distinct base URL, fanned out to instances sharing it")
        XCTAssertEqual(Set(calls), Set(["http://127.0.0.1:5199", "http://127.0.0.1:9999"]))
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

    func test_newerRefreshCannotBeOverwrittenByAnOlderProbe() async throws {
        let checker = SuspendedT3LivenessChecker()
        let spy = DecideSpy { call in
            makeDecision(role: call.role, caller: call.caller ?? BrokerPolicy.defaultCaller)
        }
        let service = BrokerService(livenessChecker: checker, decide: spy.decide)

        let olderRefresh = Task { try await service.refresh() }
        await checker.waitForCallCount(1)
        let newerRefresh = Task { try await service.refresh() }
        await checker.waitForCallCount(2)

        await checker.complete(
            call: 1,
            with: ["claudeAgent": T3Liveness(reachable: true, why: "newer")]
        )
        try await newerRefresh.value
        await checker.complete(
            call: 0,
            with: ["claudeAgent": T3Liveness(reachable: false, why: "older")]
        )
        try await olderRefresh.value

        _ = try await service.pick(role: "planning", caller: "claude-code")
        XCTAssertEqual(spy.calls.last?.t3["claudeAgent"]?.why, "newer")
    }

    func testUpdatePolicyImmediatelyFiltersRemovedLivenessAndMarksNewInstancesUnreachable() async {
        let oldPolicy = BrokerPolicy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(id: "removed", name: "Removed"),
                T3InstanceConfig(id: "retained", name: "Retained"),
            ]
        )
        let service = BrokerService(policy: oldPolicy)
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
        await service.updateT3Liveness(["claudeAgent": T3Liveness(reachable: true, why: "http 200")])
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
        XCTAssertTrue(rollbackStatus.oracle.stale)
        XCTAssertNil(rollbackStatus.oracle.ageSeconds)
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

    /// Matches the real CLI file shape: the trixie-box CLI writes this file
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
        t3: [String: T3Liveness]
    ) throws -> BrokerDecision {
        let call = Call(
            role: role, caller: caller, policy: policy, oracle: oracle,
            cooldowns: cooldowns, now: now, t3: t3
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

private enum BrokerServiceAuditTestError: Error {
    case writeFailed
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
    reason: String = "ok"
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
        candidatesTried: []
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
