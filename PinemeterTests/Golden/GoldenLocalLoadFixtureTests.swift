import Foundation
import XCTest
@testable import Pinemeter

final class GoldenLocalLoadFixtureTests: XCTestCase {
    struct Input: Codable {
        var schema = 1
        var now: Date
        var routes: [BrokerLocalRoute]
        var local: BrokerLocalLoad?
        enum CodingKeys: String, CodingKey { case schema, now, routes, local }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schema, forKey: .schema)
            try c.encode(now, forKey: .now)
            try c.encode(routes, forKey: .routes)
            try c.encode(local, forKey: .local)
        }
    }
    struct Row: Codable, Equatable {
        var candidate: String
        var available: Bool
        var level: Int?
        var reason: String?
    }
    private func vector(_ name: String, load: BrokerLocalLoad?, level: Int? = nil, reason: String? = nil) throws {
        let route = BrokerLocalRouteTests.route()
        let gate = BrokerLocalRouting.gate(route: route, load: load, now: BrokerFixture.now)
        let row = Row(candidate: route.candidate, available: gate == nil,
                      level: gate == nil ? BrokerLocalRouting.level(route: route, load: load, now: BrokerFixture.now) : nil,
                      reason: gate)
        XCTAssertEqual(row, Row(candidate: route.candidate, available: reason == nil, level: level, reason: reason))
        guard GoldenFixture.exportDirectory() != nil else { return }
        let dir = GoldenFixture.goldenDirectory.appendingPathComponent("local")
        try GoldenFixture.write(try GoldenFixture.inputEncoder().encode(Input(now: BrokerFixture.now, routes: [route], local: load)),
            to: dir, named: name + ".input.json")
        try GoldenFixture.write(try GoldenFixture.canonicalEncoder().encode([row]), to: dir, named: name + ".levels.json")
    }
    func test_loaded_idle() throws { try vector("loaded-idle", load: BrokerLocalRouteTests.snapshot(), level: 0) }
    func test_unloaded() throws { try vector("unloaded", load: BrokerLocalRouteTests.snapshot(status: "unloaded"), level: 1) }
    func test_sleeping() throws { try vector("sleeping", load: BrokerLocalRouteTests.snapshot(status: "sleeping"), level: 1) }
    func test_loading() throws { try vector("loading", load: BrokerLocalRouteTests.snapshot(status: "loading"), level: 2) }
    func test_busy_one_of_one() throws { try vector("busy-one-of-one", load: BrokerLocalRouteTests.snapshot(busy: 1), level: 3) }
    func test_busy_one_of_two() throws { try vector("busy-one-of-two", load: BrokerLocalRouteTests.snapshot(total: 2, busy: 1), level: 2) }
    func test_loaded_ahead_two() throws { try vector("loaded-ahead-two", load: BrokerLocalRouteTests.snapshot(total: 1, busy: 1), level: 3) }
    func test_pending_one() throws { try vector("pending-one", load: BrokerLocalRouteTests.snapshot(pending: 1), level: 2) }
    func test_pending_three() throws { try vector("pending-three", load: BrokerLocalRouteTests.snapshot(pending: 3), level: 4) }
    func test_clamp_65() throws { try vector("clamp-65", load: BrokerLocalRouteTests.snapshot(total: 65, busy: 65), level: 3) }
    func test_clamp_negative() throws { try vector("clamp-negative", load: BrokerLocalRouteTests.snapshot(busy: -1, pending: -1), level: 0) }
    func test_clamp_total_negative() throws { try vector("clamp-total-negative", load: BrokerLocalRouteTests.snapshot(total: -1, busy: -1, pending: -1), level: 2) }
    func test_clamp_pending_65() throws { try vector("clamp-pending-65", load: BrokerLocalRouteTests.snapshot(total: 64, pending: 65), level: 2) }
    func test_fresh_60() throws { try vector("fresh-60", load: BrokerLocalRouteTests.snapshot(age: 60), level: 0) }
    func test_stale_61() throws { try vector("stale-61", load: BrokerLocalRouteTests.snapshot(age: 61), reason: "local host 'gpu-a' load unknown") }
    func test_future() throws { try vector("future", load: BrokerLocalRouteTests.snapshot(age: -1), reason: "local host 'gpu-a' load unknown") }
    func test_unreachable() throws { try vector("unreachable", load: BrokerLocalRouteTests.snapshot(state: "unreachable"), reason: "local host 'gpu-a' load unknown") }
    func test_error() throws { try vector("error", load: BrokerLocalRouteTests.snapshot(state: "error"), reason: "local host 'gpu-a' load unknown") }
    func test_missing_host() throws { try vector("missing-host", load: BrokerLocalLoad(hosts: []), reason: "local host 'gpu-a' load unknown") }
    func test_nil_load() throws { try vector("nil-load", load: nil, reason: "local host 'gpu-a' load unknown") }
    func test_failed() throws { try vector("failed", load: BrokerLocalRouteTests.snapshot(status: "failed"), reason: "local host 'gpu-a' model failed to load") }
    func test_busy_other_model() throws { try vector("busy-other-model", load: BrokerLocalRouteTests.snapshot(other: "loaded", otherBusy: 1), reason: "local host 'gpu-a' busy with another model") }
    func test_loading_other_model() throws { try vector("loading-other-model", load: BrokerLocalRouteTests.snapshot(other: "loading"), reason: "local host 'gpu-a' busy with another model") }
    func test_gate_order_busy_before_failed() throws { try vector("gate-order-busy-before-failed", load: BrokerLocalRouteTests.snapshot(status: "failed", other: "loading"), reason: "local host 'gpu-a' busy with another model") }
    func test_eviction() throws { try vector("eviction", load: BrokerLocalRouteTests.snapshot(status: "unloaded", other: "loaded"), level: 4) }
    func test_sleeping_eviction() throws { try vector("sleeping-eviction", load: BrokerLocalRouteTests.snapshot(status: "sleeping", other: "loaded"), level: 4) }
    func test_loading_eviction() throws { try vector("loading-eviction", load: BrokerLocalRouteTests.snapshot(status: "loading", other: "loaded"), level: 4) }

    func test_missing_preset() throws {
        var load = BrokerLocalRouteTests.snapshot(); load.hosts[0].presets = [:]
        try vector("missing-preset", load: load, reason: "local host 'gpu-a' model failed to load")
    }
    func test_alias_utf8_order() throws {
        var load = BrokerLocalRouteTests.snapshot(); let preset = load.hosts[0].presets.removeValue(forKey: "qwen-27b")!
        var a = preset; a.aliases = ["qwen-27b"]
        var z = a; z.status = "failed"
        load.hosts[0].presets = ["z-target": z, "a-target": a]
        try vector("alias-utf8-order", load: load, level: 0)
    }
    func test_exact_id_beats_alias() throws {
        var load = BrokerLocalRouteTests.snapshot()
        load.hosts[0].presets["a-target"] = .init(status: "failed", aliases: ["qwen-27b"], slotsTotal: 0, slotsBusy: 0)
        try vector("exact-id-beats-alias", load: load, level: 0)
    }

    func test_decisionSchemaRejectsMismatches() throws {
        for hasLocal in [false, true] {
            for hasHealth in [false, true] {
                for hasDemand in [false, true] {
                    let input = GoldenInput(role: "explore", caller: nil, overrideCandidate: nil,
                        now: BrokerFixture.now, policy: .bundledDefault, oracle: nil, cooldowns: [:], t3: [:],
                        demand: hasDemand ? .init(historyDays: 0, historySufficient: false, roles: [:], pools: [:]) : nil,
                        health: hasHealth ? .init(validUntil: BrokerFixture.now.addingTimeInterval(60), demotions: []) : nil,
                        local: hasLocal ? BrokerLocalRouteTests.snapshot() : nil)
                    let expected = hasLocal ? 4 : (hasHealth ? 3 : (hasDemand ? 2 : 1))
                    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: GoldenFixture.inputEncoder().encode(input)) as? [String: Any])
                    for schema in [-1, 0, 1, 2, 3, 4, 5] {
                        root["schema"] = schema
                        let decoded = try GoldenFixture.decoder().decode(GoldenInput.self, from: JSONSerialization.data(withJSONObject: root))
                        XCTAssertEqual(decoded.schemaIsValid, schema == expected)
                    }
                }
            }
        }
    }
}
