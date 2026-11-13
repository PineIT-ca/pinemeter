import Foundation
import XCTest
@testable import Pinemeter

final class BrokerProposalTaintTests: XCTestCase {
    private func inject(_ node: inout Any, path: ArraySlice<String>, values: [String: Any], context: String) throws -> Int {
        guard let component = path.first else {
            var object = try XCTUnwrap(node as? [String: Any], context)
            for (key, value) in values {
                XCTAssertNil(object[key], "\(context)/\(key) overwrites a schema field")
                object[key] = value
            }
            node = object
            return 1
        }
        if component == "*" {
            var count = 0
            if var array = node as? [Any] {
                for index in array.indices {
                    count += try inject(&array[index], path: path.dropFirst(), values: values, context: "\(context)/\(index)")
                }
                node = array
            } else {
                var object = try XCTUnwrap(node as? [String: Any], context)
                for key in object.keys.sorted() {
                    var child = try XCTUnwrap(object[key], context)
                    count += try inject(&child, path: path.dropFirst(), values: values, context: "\(context)/\(key)")
                    object[key] = child
                }
                node = object
            }
            return count
        }
        var object = try XCTUnwrap(node as? [String: Any], context)
        var child = try XCTUnwrap(object[component], "Missing path \(context)/\(component)")
        let count = try inject(&child, path: path.dropFirst(), values: values, context: "\(context)/\(component)")
        object[component] = child
        node = object
        return count
    }

    private func scores(_ data: Data, context: String) throws -> [String: BrokerScoredRole] {
        let presets = try BrokerPresetManifest.decode(from: data).presets
        XCTAssertEqual(presets.count, 7, "\(context): preset rejected")
        let now = BrokerFixture.now
        let reset = now.addingTimeInterval(96 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            session: 0, weekly: 0, sonnet: 0, fable: 0,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 0, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
            "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        var result: [String: BrokerScoredRole] = [:]
        for preset in presets {
            var policy = BrokerPolicy.bundledDefault
            policy.assignExactRules(preset.rules)
            XCTAssertEqual(policy.roles.count, 10, "\(context)/\(preset.id)")
            XCTAssertEqual(policy.scoring.roles.count, 10, "\(context)/\(preset.id)")
            let demand = BrokerDemand(historyDays: 3, historySufficient: true,
                roles: policy.roles.mapValues { _ in 100 },
                pools: Dictionary(uniqueKeysWithValues: keys.map {
                    ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
                }))
            let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(prices.count, 4, context)
            XCTAssertTrue(prices.allSatisfy { $0.price == 500 }, "\(context): not a 500-price world")
            for role in policy.roles.keys.sorted() {
                result["\(preset.id)/\(role)"] = try BrokerScoringEngine.scoredRole(
                    role: role, policy: policy, oracle: oracle, demand: demand, now: now)
            }
        }
        XCTAssertEqual(result.count, 70, context)
        return result
    }

    func test_proposalKeysNeverFeedScores() throws {
        let liveURL = try XCTUnwrap(BrokerPresetManifestTests.bundledManifestURL())
        let live = try Data(contentsOf: liveURL)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("TestSupport/proposal-taint-keys.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["v"] as? Int, 1)
        let injections = try XCTUnwrap(fixture["injections"] as? [[String: Any]])
        XCTAssertEqual(injections.count, 5)
        let clean = try scores(live, context: "clean")
        func check(_ entries: [[String: Any]], context: String) throws {
            var document = try JSONSerialization.jsonObject(with: live)
            for entry in entries {
                let path = try XCTUnwrap(entry["path"] as? String)
                let values = try XCTUnwrap(entry["values"] as? [String: Any])
                let parts = path.split(separator: "/").map(String.init)
                XCTAssertGreaterThan(try inject(&document, path: parts[...], values: values, context: path), 0, path)
            }
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            let tainted = try scores(data, context: context)
            XCTAssertEqual(Set(tainted.keys), Set(clean.keys), "\(context): rejected preset or role")
            for pair in clean.keys.sorted() {
                XCTAssertEqual(tainted[pair], clean[pair], "\(context): score changed for \(pair)")
            }
        }
        for entry in injections {
            let path = try XCTUnwrap(entry["path"] as? String)
            let values = try XCTUnwrap(entry["values"] as? [String: Any])
            XCTAssertEqual(values.count, 8, path)
            for key in values.keys.sorted() {
                try check([["path": path, "values": [key: try XCTUnwrap(values[key])]]], context: "\(path)/\(key)")
            }
        }
        try check(injections, context: "combined proposal keys")
    }
}
