import Foundation
import XCTest
@testable import Pinemeter

final class BrokerLocalRouteTests: XCTestCase {
    func test_executionIdleLocal_precedesPiDefault() throws {
        let p = Self.policy()
        let injection = BrokerLocalRouting.inject(p.roles["execution"]!, role: "execution", policy: p)
        XCTAssertEqual(injection.candidates.last?.id, "t3:pi/default")
        XCTAssertEqual(injection.policy.roles["execution"]?.last?.id, "t3:pi/default")
        let scored = try BrokerScoringEngine.scoredRole(role: "execution", policy: p, oracle: nil,
            demand: nil, now: Self.now, local: Self.snapshot())
        let local = try XCTUnwrap(scored.rows.first { $0.candidate == Self.route().candidate })
        XCTAssertEqual(local.effective, 256)
        XCTAssertEqual(local.score, 236)
        let pick = try recordedDecide(role: "execution", caller: nil, policy: p, oracle: nil,
            cooldowns: ["native": Self.now.addingTimeInterval(3600), "codex": Self.now.addingTimeInterval(3600)],
            now: Self.now, t3: Self.t3.merging(["t3:pi/default": .init(reachable: true, why: "infer http 200")]) { _, rhs in rhs },
            local: Self.snapshot())
        XCTAssertEqual(pick.model, Self.route().candidate)
        XCTAssertEqual(pick.backups.first?.candidate, "t3:pi/default")
    }

    func test_customExecutionPiFirst_localAppendsWithoutQualityCap() throws {
        var p = Self.policy()
        p.roles["execution"] = [
            .init(route: .t3, instance: "pi", model: "default"),
            .init(route: .codex, model: "gpt-6.1-sol", effort: .high)]
        let injection = BrokerLocalRouting.inject(p.roles["execution"]!, role: "execution", policy: p)
        let expected = ["t3:pi/default", "codex/gpt-6.1-sol", Self.route().candidate]
        XCTAssertEqual(injection.candidates.map(\.id), expected)
        XCTAssertEqual(injection.policy.roles["execution"]?.map(\.id), expected)
        let scored = try BrokerScoringEngine.scoredRole(role: "execution", policy: p, oracle: nil,
            demand: nil, now: Self.now, local: Self.snapshot())
        let established = try XCTUnwrap(scored.rows.first { $0.candidate == "codex/gpt-6.1-sol" })
        XCTAssertEqual(established.effective, 502)
        XCTAssertTrue(established.eligible)
        XCTAssertNil(established.reason)
        let pick = try recordedDecide(role: "execution", caller: nil, policy: p, oracle: nil,
            cooldowns: [:], now: Self.now,
            t3: Self.t3.merging(["t3:pi/default": .init(reachable: true, why: "infer http 200")]) { _, rhs in rhs },
            local: Self.snapshot())
        XCTAssertEqual(pick.model, "codex/gpt-6.1-sol")
        XCTAssertEqual(pick.backups.first?.candidate, "t3:pi/default")
        XCTAssertEqual(pick.backups.last?.candidate, Self.route().candidate)
    }

    func test_controlledT3Child_keepsResidencyAndFailsClosed() throws {
        var p = Self.policy()
        p.localRoutes[0].residency = .controlled
        let healthy = try recordedDecide(role: "explore", caller: "codex", policy: p,
            oracle: Self.oracle(gated: false), cooldowns: [:], now: Self.now, t3: Self.t3,
            local: Self.snapshot(), residency: .controlled, executionContext: .t3Child)
        XCTAssertEqual(healthy.residency, "controlled")
        XCTAssertEqual(healthy.routeClass, "controlled")
        XCTAssertEqual(healthy.invocation.kind, "t3-delegate")
        if case .t3Delegate(_, _, _, let t3Role) = healthy.invocation {
            XCTAssertEqual(t3Role, "research")
        } else {
            XCTFail("Expected t3-delegate")
        }
        XCTAssertTrue(healthy.backups.isEmpty)
        XCTAssertThrowsError(try recordedDecide(role: "explore", caller: "codex", policy: p,
            oracle: Self.oracle(gated: false), cooldowns: [:], now: Self.now, t3: Self.t3,
            local: nil, residency: .controlled, executionContext: .t3Child)) { error in
            guard case BrokerError.noControlledRoute = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try recordedDecideOverride(role: "explore", caller: "codex",
            overrideCandidate: "t3:pi/default", policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot(),
            residency: .controlled, executionContext: .t3Child))
    }

    static let now = BrokerFixture.now
    static func route() -> BrokerLocalRoute {
        .init(candidate: "t3:pi/lab/qwen-27b", host: "gpu-a", probeURL: "http://gpu-a.example:11434",
              preset: "qwen-27b", enabled: true, roles: ["explore", "verification", "execution"], quality: ["high": 256])
    }
    static func snapshot(status: String = "loaded", total: Int = 1, busy: Int = 0, pending: Int = 0,
                     age: TimeInterval = 10, state: String = "ok", other: String? = nil, otherBusy: Int = 0) -> BrokerLocalLoad {
        var presets: [String: BrokerLocalLoad.Preset] = ["qwen-27b": .init(status: status, aliases: [], slotsTotal: total, slotsBusy: busy)]
        if let other { presets["other-model"] = .init(status: other, aliases: [], slotsTotal: 1, slotsBusy: otherBusy) }
        return .init(hosts: [.init(host: "gpu-a", state: state, observedAt: now.addingTimeInterval(-age), presets: presets, pending: pending)])
    }
    static func policy() -> BrokerPolicy {
        var p = GoldenFrozenTables.bundledDefault
        p.localRoutes = [route()]
        return p
    }
    static func oracle(gated: Bool = true) -> OracleSnapshot {
        BrokerFixture.oracle(accounts: [BrokerFixture.account(session: gated ? 100 : 0, weekly: gated ? 100 : 0,
            sonnet: gated ? 100 : 0, fable: gated ? 100 : 0)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: gated ? 100 : 0,
                               windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
    }
    static let t3: [String: T3Liveness] = ["pi": .init(reachable: true, why: "fixture")]

    static func bundledQualityWorld(preset: String = "qwen3.8-27b") -> (BrokerPolicy, OracleSnapshot, BrokerDemand, BrokerLocalLoad) {
        var p = Self.policy()
        p.roles["explore"] = [.init(route: .codex, model: "gpt-6-luna", effort: .medium)]
        p.models["gpt-6-luna"] = .init(quota: .chatGPT(labelContains: nil))
        p.scoring = .init(roles: ["explore": .init(floor: 250, quality: ["gpt-6-luna": ["medium": 256]])])
        p.thresholds.preferExpiringQuota = true
        p.localRoutes[0].preset = preset
        p.localRoutes[0].quality = [:]
        let oracle = BrokerFixture.oracle(accounts: [], chatGPTRows: [
            .init(label: "Weekly", usedPercent: 0, resetAt: now.addingTimeInterval(96 * 3600),
                  windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["explore": 100], pools: [
            "chatgpt:Workspace A:Weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12)])
        var load = Self.snapshot()
        load.hosts[0].presets[preset] = load.hosts[0].presets.removeValue(forKey: "qwen-27b")
        return (p, oracle, demand, load)
    }

    func test_bundledQuality_appliesByPreset() throws {
        let (p, oracle, demand, load) = Self.bundledQualityWorld()
        let scored = try BrokerScoringEngine.scoredRole(role: "explore", policy: p, oracle: oracle,
            demand: demand, now: Self.now, local: load)
        XCTAssertEqual(scored.rows.first { $0.candidate == "codex/gpt-6-luna" }?.level, 2)
        let local = try XCTUnwrap(scored.rows.first { $0.candidate == Self.route().candidate })
        XCTAssertEqual(local.quality, 256)
        XCTAssertTrue(local.eligible)
        XCTAssertEqual(local.level, 0)
        let decision = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: oracle,
            cooldowns: [:], now: Self.now, t3: Self.t3, demand: demand, local: load)
        XCTAssertEqual(decision.model, Self.route().candidate)
        XCTAssertEqual(decision.pickBasis, .quota)
    }

    func test_unknownPreset_staysNoEstimate() throws {
        let (p, oracle, demand, load) = Self.bundledQualityWorld(preset: "unknown-quant")
        let scored = try BrokerScoringEngine.scoredRole(role: "explore", policy: p, oracle: oracle,
            demand: demand, now: Self.now, local: load)
        let local = try XCTUnwrap(scored.rows.first { $0.candidate == Self.route().candidate })
        XCTAssertNil(local.quality)
        XCTAssertFalse(local.eligible)
        XCTAssertEqual(local.reason, "noEstimate")
        let decision = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: oracle,
            cooldowns: [:], now: Self.now, t3: Self.t3, demand: demand, local: load)
        XCTAssertEqual(decision.model, "codex/gpt-6-luna")
        XCTAssertEqual(decision.pickBasis, .quality)
    }

    func test_bundledQuality_scoreSnapshotFallbackOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = BrokerService(
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            now: { Self.now })
        for preset in ["qwen3.8-27b", "qwen3.8:27b", "unknown-quant"] {
            for effort in [BrokerEffort.low, .medium, .high] {
                for explicit in [nil, 0, 300] as [Int?] {
                    var (p, _, _, load) = Self.bundledQualityWorld(preset: preset)
                    p.localRoutes[0].baseEffort = effort
                    p.localRoutes[0].quality = explicit.map { [effort.rawValue: $0] } ?? [:]
                    await broker.updatePolicy(p)
                    await broker.setLocalLoad(load)
                    let snapshot = await broker.scoreSnapshot(role: "explore")
                    let table = try XCTUnwrap(snapshot?.modelTables.first { $0.model == "lab/qwen-27b" })
                    let row = table.rows.first { $0.isBase }
                    let order = try XCTUnwrap(snapshot?.orderRows.first { $0.candidate == Self.route().candidate })
                    let bundled = BrokerBuiltInScoring.localModelQuality[preset]?[effort.rawValue]
                    if preset == "unknown-quant" {
                        XCTAssertNil(bundled)
                    } else {
                        XCTAssertNotNil(bundled, "\(preset)/\(effort)")
                    }
                    let expected = explicit ?? bundled
                    XCTAssertEqual(row?.quality, expected, "\(preset)/\(effort)/\(String(describing: explicit))")
                    XCTAssertEqual(table.hasBaseEstimate, expected != nil)
                    XCTAssertEqual(row == nil, expected == nil)
                    XCTAssertEqual(order.ineligibleReason, expected == nil ? "noEstimate" : (expected! < 250 ? "belowFloor" : nil))
                    XCTAssertNil(row?.latency)
                    XCTAssertEqual(snapshot?.floor, 250)
                }
            }
        }
    }

    func test_cloudGated_idleLocalHostWinsExplore() throws {
        let p = Self.policy()
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot())
        XCTAssertEqual(d.model, Self.route().candidate)
        XCTAssertEqual(d.route, .t3)
        XCTAssertEqual(d.effort, .high)
        XCTAssertEqual(d.invocation, .t3Dispatch(model: "lab/qwen-27b", instanceId: "pi", effort: .high))
        XCTAssertEqual(d.invocation.model, "lab/qwen-27b")
        XCTAssertEqual(d.candidatesTried.last?.candidate, Self.route().candidate)
        XCTAssertTrue(d.candidatesTried.dropLast().allSatisfy { !$0.available })
        var empty = p; empty.localRoutes = []
        XCTAssertEqual(try BrokerEngine.decide(role: "explore", caller: nil, policy: empty, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot()),
            try BrokerEngine.decide(role: "explore", caller: nil, policy: empty, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3))
    }

    private func noHeadroom(_ name: String = "explore", policy: BrokerPolicy? = nil, load: BrokerLocalLoad?, reason: String?) throws {
        var p = policy ?? Self.policy(); p.allowForcedDegraded[p.resolveRole(name)] = false
        do {
            _ = try recordedDecide(role: name, caller: nil, policy: p, oracle: Self.oracle(), cooldowns: [:],
                now: Self.now, t3: Self.t3, local: load)
            XCTFail("expected noHeadroom")
        } catch BrokerError.noHeadroom(_, let tried, _) {
            if let reason { XCTAssertEqual(tried.last?.why, reason); XCTAssertEqual(tried.last?.candidate, Self.route().candidate) }
            else { XCTAssertFalse(tried.contains { $0.candidate == Self.route().candidate }) }
        }
    }
    func test_cloudAvailable_winsWithEstablishedBackupsFirst() throws {
        let d = try recordedDecide(role: "explore", caller: nil, policy: Self.policy(), oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot())
        XCTAssertNotEqual(d.model, Self.route().candidate)
        var sawLocal = false
        for backup in d.backups {
            if backup.candidate == Self.route().candidate { sawLocal = true }
            else { XCTAssertFalse(sawLocal) }
        }
    }
    func test_unknownLoad_noHeadroom() throws { try noHeadroom(load: nil, reason: "local host 'gpu-a' load unknown") }
    func test_busyOtherModel_noHeadroom() throws { try noHeadroom(load: Self.snapshot(other: "loaded", otherBusy: 1), reason: "local host 'gpu-a' busy with another model") }
    func test_failed_noHeadroom() throws { try noHeadroom(load: Self.snapshot(status: "failed"), reason: "local host 'gpu-a' model failed to load") }
    func test_stale_noHeadroom() throws { try noHeadroom(load: Self.snapshot(age: 61), reason: "local host 'gpu-a' load unknown") }
    func test_forcedDegraded_neverSelectsUnknownLocal() throws {
        var p = Self.policy(); p.allowForcedDegraded["explore"] = true
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3)
        XCTAssertEqual(d.source, .forcedDegraded)
        XCTAssertNotEqual(d.model, Self.route().candidate)
        XCTAssertFalse(d.backups.contains { $0.candidate == Self.route().candidate })
    }
    func test_eviction_idleOtherModelStillAvailable() throws {
        let d = try recordedDecide(role: "explore", caller: nil, policy: Self.policy(), oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot(status: "unloaded", other: "loaded"))
        XCTAssertEqual(d.model, Self.route().candidate)
    }
    func test_disabled_notInjected() throws {
        var p = Self.policy(); p.localRoutes[0].enabled = false
        try noHeadroom(policy: p, load: Self.snapshot(), reason: nil)
    }
    func test_missingRole_notInjected() throws {
        var p = Self.policy(); p.localRoutes[0].roles = ["execution"]
        try noHeadroom(policy: p, load: Self.snapshot(), reason: nil)
    }
    func test_review_notInjected() throws { try noHeadroom("review", load: Self.snapshot(), reason: nil) }
    func test_architecture_notInjected() throws { try noHeadroom("architecture", load: Self.snapshot(), reason: nil) }
    private func twoLocalWorld(pricing: Bool) -> (BrokerPolicy, BrokerLocalLoad) {
        var p = Self.policy()
        var b = Self.route(); b.candidate = "t3:pi/lab/qwen-27b-b"; b.host = "gpu-b"; b.probeURL = "http://gpu-b.example:11434"
        p.localRoutes.append(b)
        p.thresholds.preferExpiringQuota = pricing
        p.scoring.roles["explore"] = .init(floor: 1, quality: Dictionary(uniqueKeysWithValues:
            p.roles["explore"]!.map { ($0.model, [BrokerScoring.effortKey($0.effort): 256]) }))
        var load = Self.snapshot(busy: 1)
        var host = Self.snapshot().hosts[0]; host.host = "gpu-b"; load.hosts.append(host)
        return (p, load)
    }
    func test_pricingOn_idleHostWins() throws {
        let (p, load) = twoLocalWorld(pricing: true)
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load)
        XCTAssertEqual(d.model, "t3:pi/lab/qwen-27b-b")
    }
    func test_pricingOff_keepsRouteOrder() throws {
        let (p, load) = twoLocalWorld(pricing: false)
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load)
        XCTAssertEqual(d.model, Self.route().candidate)
    }
    func test_override_busyOtherModelUnavailable() throws {
        do {
            _ = try recordedDecideOverride(role: "explore", caller: nil, overrideCandidate: Self.route().candidate,
                policy: Self.policy(), oracle: Self.oracle(), cooldowns: [:], now: Self.now, t3: Self.t3,
                local: Self.snapshot(other: "loaded", otherBusy: 1))
            XCTFail("expected overrideUnavailable")
        } catch BrokerError.overrideUnavailable(_, let reasons, _) {
            XCTAssertEqual(reasons, ["local host 'gpu-a' busy with another model"])
        }
    }

    func test_shippedPresetOrderInvariant() throws {
        let manifest = try BrokerPresetManifest.decode(from: Data(contentsOf: XCTUnwrap(
            BrokerPresetManifestTests.bundledManifestURL())))
        XCTAssertEqual(manifest.presets.count, 7)
        for preset in manifest.presets {
            for count in [1, 2, 8] {
                var p = BrokerPolicy.bundledDefault; p.assignExactRules(preset.rules)
                let models = Array(Set(p.roles.values.flatMap { $0.map(\.model) })).sorted()
                p.t3Instances = ["alpha", "beta"].map {
                    .init(id: $0, name: $0, boundAccountId: "acct-primary", origin: .detected,
                          driver: "claudeAgent", detectedModels: models, lastSeenAt: Self.now)
                }
                p.localRoutes = (0..<count).map { i in
                    var r = Self.route(); r.candidate = "t3:pi/lab/local-\(i)"; return r
                }
                let original = p
                let localIDs = Set(p.localRoutes.map(\.candidate))
                for role in BrokerLocalRoute.allowedRoles {
                    let ranked = BrokerEngine.rankingEquivalentCandidatesByHeadroom(
                        BrokerEngine.expandingModelChoices(p.roles[role]!, policy: p, oracle: Self.oracle(gated: false), now: Self.now),
                        policy: p, oracle: Self.oracle(gated: false), now: Self.now)
                    let injected = BrokerLocalRouting.inject(ranked, role: role, policy: p)
                    XCTAssertEqual(injected.candidates.filter { !localIDs.contains($0.id) }, ranked)
                    XCTAssertEqual(injected.candidates.filter { localIDs.contains($0.id) }.map(\.id), p.localRoutes.map(\.candidate))
                    if ranked.contains(where: { $0.id == "t3:pi/default" }) {
                        XCTAssertEqual(injected.candidates.last?.id, "t3:pi/default")
                    }
                    XCTAssertEqual(p, original)
                    let d = try BrokerEngine.decide(role: role, caller: nil, policy: p, oracle: Self.oracle(gated: false),
                        cooldowns: [:], now: Self.now,
                        t3: ["alpha": .init(reachable: true, why: "fixture"), "beta": .init(reachable: true, why: "fixture"), "pi": .init(reachable: true, why: "fixture")],
                        local: Self.snapshot())
                    XCTAssertFalse(localIDs.contains(d.model), "\(preset.name)/\(role)")
                    var sawLocal = false
                    for backup in d.backups {
                        if localIDs.contains(backup.candidate) { sawLocal = true }
                        else { XCTAssertFalse(sawLocal, "\(preset.name)/\(role)") }
                    }
                }
                for role in BrokerLocalRoute.forbiddenRoles + ["architecture"] {
                    let ranked = p.roles[p.resolveRole(role)] ?? []
                    XCTAssertTrue(BrokerLocalRouting.inject(ranked, role: role, policy: p).injectedIDs.isEmpty)
                }
            }
        }
    }
    func test_scoredRoleIncludesSameLocalLevelsWithoutLatency() throws {
        var p = Self.policy()
        p.scoring.latency["lab/qwen-27b"] = ["high": 1000]
        p.scoring.roles["explore"]?.latencyLimit = 1
        let originalLimit = p.scoring.roles["explore"]?.latencyLimit
        for (load, expected) in [(Self.snapshot(), 0), (Self.snapshot(busy: 1), 3), (nil, 4)] as [(BrokerLocalLoad?, Int)] {
            let scored = try BrokerScoringEngine.scoredRole(role: "explore", policy: p, oracle: Self.oracle(gated: false),
                demand: nil, now: Self.now, local: load)
            let row = try XCTUnwrap(scored.rows.first { $0.candidate == Self.route().candidate })
            XCTAssertEqual(row.level, expected)
            XCTAssertNil(row.latency)
            XCTAssertEqual(scored.latencyLimit, originalLimit)
            XCTAssertEqual(row.score, row.effective.map { $0 - 20 }) // Below-floor routes use level 4 without demand.
        }
    }

    func test_existingConfiguredLocalOverrideStillUsesGate() throws {
        var p = Self.policy()
        p.roles["explore"] = [try XCTUnwrap(BrokerCandidate(id: Self.route().candidate))]
        XCTAssertThrowsError(try BrokerEngine.decideOverride(role: "explore", caller: nil,
            overrideCandidate: Self.route().candidate, policy: p, oracle: nil, cooldowns: [:],
            now: Self.now, t3: Self.t3, local: Self.snapshot(other: "loading"))) { error in
            guard case BrokerError.overrideUnavailable(_, let reasons, _) = error else {
                return XCTFail("expected overrideUnavailable, got \(error)")
            }
            XCTAssertEqual(reasons, ["local host 'gpu-a' busy with another model"])
        }
    }
    private func controlledWorld() -> (BrokerPolicy, BrokerLocalLoad) {
        var (p, load) = twoLocalWorld(pricing: true)
        for i in p.localRoutes.indices { p.localRoutes[i].residency = .controlled }
        p.scoring.roles["explore"]?.floor = 299
        return (p, load)
    }
    func test_residency_restrictedPick_choosesIdleControlledHost() throws {
        let (p, load) = controlledWorld()
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .controlled)
        XCTAssertEqual(d.model, "t3:pi/lab/qwen-27b-b")
        XCTAssertEqual(d.residency, "controlled")
        XCTAssertEqual(d.routeClass, "controlled")
        let ids = Set(p.localRoutes.map(\.candidate))
        XCTAssertTrue(d.candidatesTried.allSatisfy { ids.contains($0.candidate) })
        XCTAssertFalse(d.backups.isEmpty)
        XCTAssertTrue(d.backups.allSatisfy { ids.contains($0.candidate) })
        let cloud = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load)
        XCTAssertFalse(ids.contains(cloud.model))
        XCTAssertNil(cloud.residency)
        XCTAssertNil(cloud.routeClass)
    }
    func test_residency_roleSetting_restrictsWithoutArgument() throws {
        var (p, load) = controlledWorld()
        p.residencyRoles = ["explore": .controlled]
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load)
        XCTAssertEqual(d.model, "t3:pi/lab/qwen-27b-b")
        XCTAssertEqual(d.residency, "controlled")
        XCTAssertEqual(d.routeClass, "controlled")
    }

    private func restrictedFailure(role: String = "explore", policy: BrokerPolicy, load: BrokerLocalLoad?,
                                   cooldowns: [String: Date] = [:], expected: [String]) throws {
        XCTAssertThrowsError(try recordedDecide(role: role, caller: nil, policy: policy, oracle: Self.oracle(gated: false),
            cooldowns: cooldowns, now: Self.now, t3: Self.t3, local: load, residency: .controlled)) { error in
            guard case BrokerError.noControlledRoute(let requestedRole, let tried) = error else { return XCTFail("expected noControlledRoute, got \(error)") }
            XCTAssertEqual(requestedRole, role)
            XCTAssertEqual(tried.map(\.why), expected)
            XCTAssertTrue(tried.allSatisfy { BrokerResidencyFilter.controlledIDs(role: role, policy: policy).contains($0.candidate) })
            XCTAssertEqual(GoldenErrorFixture(error)?.caseName, "noControlledRoute")
            XCTAssertNil(GoldenErrorFixture(error)?.trace)
        }
    }
    func test_residency_backupsOnlyControlled() throws {
        let (p, load) = controlledWorld()
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .controlled)
        XCTAssertEqual(d.backups.map(\.candidate), [Self.route().candidate])
        XCTAssertEqual(d.pickBasis, .quota)
        XCTAssertTrue(d.candidatesTried.allSatisfy { $0.candidate.hasPrefix("t3:pi/") })
    }
    func test_residency_unknownAll_forcingOffFailsClosed() throws {
        var (p, _) = controlledWorld(); p.allowForcedDegraded["explore"] = false
        try restrictedFailure(policy: p, load: nil, expected: ["local host 'gpu-a' load unknown", "local host 'gpu-b' load unknown"])
    }
    func test_residency_unknownAll_forcingOnFailsClosed() throws {
        var (p, _) = controlledWorld(); p.allowForcedDegraded["explore"] = true
        try restrictedFailure(policy: p, load: nil, expected: ["local host 'gpu-a' load unknown", "local host 'gpu-b' load unknown"])
    }
    func test_residency_forcedDegraded_controlledCooldownOnly() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .controlled; p.allowForcedDegraded["explore"] = true
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [Self.route().candidate: Self.now.addingTimeInterval(60)], now: Self.now, t3: Self.t3,
            local: Self.snapshot(), residency: .controlled)
        XCTAssertEqual(d.model, Self.route().candidate)
        XCTAssertEqual(d.source, .forcedDegraded)
        XCTAssertTrue(d.degraded)
        XCTAssertEqual(d.residency, "controlled")
        XCTAssertEqual(d.routeClass, "controlled")
    }
    func test_residency_noControlledDeclaration() throws {
        var p = Self.policy(); p.localRoutes = []
        try restrictedFailure(policy: p, load: Self.snapshot(), expected: [])
    }
    func test_residency_reviewForbidden() throws {
        let (p, load) = controlledWorld()
        try restrictedFailure(role: "review", policy: p, load: load, expected: [])
    }
    func test_residency_architectureForbidden() throws {
        var (p, load) = controlledWorld(); p.residencyRoles["planning"] = .controlled
        try restrictedFailure(role: "architecture", policy: p, load: load, expected: [])
    }
    func test_residency_overrideVendorRefused() throws {
        let (p, load) = controlledWorld()
        let requested = "native/claude-sonnet-5"
        XCTAssertThrowsError(try recordedDecideOverride(role: "explore", caller: nil, overrideCandidate: requested,
            policy: p, oracle: Self.oracle(gated: false), cooldowns: [:], now: Self.now, t3: Self.t3,
            local: load, residency: .controlled)) { error in
            guard case BrokerError.noControlledRoute(_, let tried) = error else { return XCTFail("expected noControlledRoute, got \(error)") }
            XCTAssertEqual(tried, [.init(candidate: requested, available: false, why: "not controlled infrastructure")])
        }
    }
    func test_residency_overrideControlledEcho() throws {
        let (p, load) = controlledWorld()
        let d = try recordedDecideOverride(role: "explore", caller: nil, overrideCandidate: Self.route().candidate,
            policy: p, oracle: Self.oracle(), cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .controlled)
        XCTAssertEqual(d.residency, "controlled")
        XCTAssertEqual(d.routeClass, "controlled")
        XCTAssertEqual(d.source, .humanOverride)
        XCTAssertEqual(d.pickBasis, .humanOverride)
        XCTAssertTrue(d.backups.isEmpty)
    }
    func test_residency_overrideControlledStillGated() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .controlled
        XCTAssertThrowsError(try recordedDecideOverride(role: "explore", caller: nil, overrideCandidate: Self.route().candidate,
            policy: p, oracle: nil, cooldowns: [:], now: Self.now, t3: Self.t3, residency: .controlled)) { error in
            guard case BrokerError.overrideUnavailable(_, let reasons, _) = error else { return XCTFail("expected overrideUnavailable, got \(error)") }
            XCTAssertEqual(reasons, ["local host 'gpu-a' load unknown"])
        }
    }
    func test_residency_floorLift_ordersByLoad() throws {
        let (p, load) = controlledWorld()
        XCTAssertEqual(p.scoring.roles["explore"]?.floor, 299)
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .controlled)
        XCTAssertEqual(d.model, p.localRoutes[1].candidate)
        XCTAssertEqual(d.pickBasis, .quota)
    }
    func test_residency_unrestrictedControlled_routeClassOnly() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .controlled
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot())
        XCTAssertEqual(d.model, Self.route().candidate)
        XCTAssertNil(d.residency)
        XCTAssertEqual(d.routeClass, "controlled")
        let overridden = try recordedDecideOverride(role: "explore", caller: nil, overrideCandidate: Self.route().candidate,
            policy: p, oracle: nil, cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot())
        XCTAssertNil(overridden.residency)
        XCTAssertEqual(overridden.routeClass, "controlled")
    }
    func test_residency_vendorDeclaredLocalExcluded() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .vendor
        p.localRoutes = BrokerLocalRoute.normalized(p.localRoutes)
        XCTAssertNil(p.localRoutes[0].residency)
        try restrictedFailure(policy: p, load: Self.snapshot(), expected: [])
    }
    func test_residency_vendorRequestCannotWeakenRoleSetting() throws {
        var (p, load) = controlledWorld(); p.residencyRoles["explore"] = .controlled
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .vendor)
        XCTAssertEqual(d.residency, "controlled")
        XCTAssertEqual(d.model, p.localRoutes[1].candidate)
    }

    func test_residency_callerFilterFailsClosed() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .controlled
        p.callers[BrokerPolicy.defaultCaller] = .init(routes: [.native])
        p.allowForcedDegraded["explore"] = true
        XCTAssertThrowsError(try recordedDecide(role: "explore", caller: nil, policy: p, oracle: nil,
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot(), residency: .controlled)) { error in
            guard case BrokerError.noControlledRoute(_, let tried) = error else { return XCTFail("expected noControlledRoute, got \(error)") }
            XCTAssertEqual(tried.count, 1)
            XCTAssertEqual(tried.first?.candidate, Self.route().candidate)
            XCTAssertEqual(tried.first?.callerFiltered, true)
        }
        XCTAssertThrowsError(try recordedDecideOverride(role: "explore", caller: nil,
            overrideCandidate: Self.route().candidate, policy: p, oracle: nil, cooldowns: [:], now: Self.now,
            t3: Self.t3, local: Self.snapshot(), residency: .controlled)) { error in
            guard case BrokerError.noControlledRoute(_, let tried) = error else { return XCTFail("expected noControlledRoute, got \(error)") }
            XCTAssertEqual(tried.first?.callerFiltered, true)
            XCTAssertEqual(tried.first?.candidate, Self.route().candidate)
        }
    }
    func test_residency_chainCapUsesOnlyFilteredCandidates() throws {
        var (p, load) = controlledWorld()
        for model in p.scoring.roles["explore"]!.quality.keys { p.scoring.roles["explore"]!.quality[model] = ["medium": 100, "high": 100] }
        p.localRoutes[1].quality = ["high": 240]
        let d = try recordedDecide(role: "explore", caller: nil, policy: p, oracle: Self.oracle(gated: false),
            cooldowns: [:], now: Self.now, t3: Self.t3, local: load, residency: .controlled)
        // 256 - 15 remains above 240; vendor quality must not cap either host.
        XCTAssertEqual(d.model, Self.route().candidate)
        XCTAssertEqual(d.pickBasis, .quality)
    }

    func test_residency_schemaValidation() throws {
        let input = GoldenInput(role: "explore", caller: nil, overrideCandidate: nil, now: Self.now,
            policy: Self.policy(), oracle: nil, cooldowns: [:], t3: Self.t3, residency: .controlled)
        XCTAssertEqual(input.schema, 4)
        XCTAssertTrue(input.schemaIsValid)
        let data = try GoldenFixture.inputEncoder().encode(input)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["local"])
        object["schema"] = 3
        let mismatch = try GoldenFixture.decoder().decode(GoldenInput.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(mismatch.schemaIsValid)
        object["schema"] = 4
        for raw in [42, true, [String](), [String: String]()] as [Any] {
            object["residency"] = raw
            XCTAssertThrowsError(try GoldenFixture.decoder().decode(GoldenInput.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }
    func test_residency_degradedDecisionWithoutReasonRoundTrip() throws {
        var policy = Self.policy(); policy.localRoutes[0].residency = .controlled
        let decision = try BrokerEngine.decide(role: "explore", caller: nil, policy: policy, oracle: nil,
            cooldowns: [:], now: Self.now, t3: Self.t3, local: Self.snapshot(), residency: .controlled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BrokerDecision.makeEncoder().encode(decision)) as? [String: Any])
        object["degraded"] = true
        object.removeValue(forKey: "degraded_reason")
        let decoded = try GoldenFixture.decoder().decode(BrokerDecision.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try BrokerDecision.makeEncoder().encode(decoded)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(result["degraded_reason"] as? String, decision.reason)
        XCTAssertEqual(result["residency"] as? String, "controlled")
        XCTAssertEqual(result["route_class"] as? String, "controlled")
        let roundTrip = try GoldenFixture.decoder().decode(BrokerDecision.self, from: encoded)
        XCTAssertEqual(try BrokerDecision.makeEncoder().encode(roundTrip), encoded)
    }

    func test_residency_decisionKeysDecodeLenient() throws {
        var p = Self.policy(); p.localRoutes[0].residency = .controlled
        let d = try BrokerEngine.decide(role: "explore", caller: nil, policy: p, oracle: nil, cooldowns: [:],
            now: Self.now, t3: Self.t3, local: Self.snapshot(), residency: .controlled)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: BrokerDecision.makeEncoder().encode(d)) as? [String: Any])
        for raw in ["controlled", "vendor", "future", 42, true, NSNull(), [String](), [String: String]()] as [Any] {
            var object = original; object["residency"] = raw; object["route_class"] = raw
            let decoded = try GoldenFixture.decoder().decode(BrokerDecision.self, from: JSONSerialization.data(withJSONObject: object))
            let expected: String? = raw as? String == "controlled" ? "controlled" : nil
            XCTAssertEqual(decoded.residency, expected)
            XCTAssertEqual(decoded.routeClass, expected)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: BrokerDecision.makeEncoder().encode(decoded)) as? [String: Any])
            XCTAssertEqual(encoded["residency"] as? String, expected)
            XCTAssertEqual(encoded["route_class"] as? String, expected)
        }
        var absent = original; absent.removeValue(forKey: "residency"); absent.removeValue(forKey: "route_class")
        let legacy = try GoldenFixture.decoder().decode(BrokerDecision.self, from: JSONSerialization.data(withJSONObject: absent))
        XCTAssertNil(legacy.residency)
        XCTAssertNil(legacy.routeClass)
        XCTAssertEqual(d.attachingDecisionID("echo-preserved").residency, d.residency)
        XCTAssertEqual(d.attachingDecisionID("echo-preserved").routeClass, d.routeClass)
    }

}
