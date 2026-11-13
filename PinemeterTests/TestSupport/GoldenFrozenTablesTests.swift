import XCTest
@testable import Pinemeter

final class GoldenFrozenTablesTests: XCTestCase {
    private func injectedQuality(explicit: Int? = nil) -> Int? {
        var policy = GoldenFrozenTables.bundledDefault
        var route = BrokerLocalRouteTests.route()
        route.preset = "qwen3.8-27b"
        route.baseEffort = .medium
        route.quality = explicit.map { ["medium": $0] } ?? [:]
        policy.localRoutes = [route]
        return BrokerLocalRouting.inject(policy.roles["explore"]!, role: "explore", policy: policy)
            .policy.scoring.roles["explore"]?.quality[BrokerCandidate(id: route.candidate)!.model]?["medium"]
    }

    func test_recordingUsesFrozenLocalQuality() throws {
        let quality = GoldenFrozenTables.withFrozenLocalQuality { injectedQuality() }
        XCTAssertEqual(try XCTUnwrap(quality),
            try XCTUnwrap(GoldenFrozenTables.localModelQuality["qwen3.8-27b"]?["medium"]))
    }

    func test_unboundQualityUsesGeneratedTable() {
        XCTAssertNil(BrokerLocalLoad.qualityOverride)
        XCTAssertEqual(injectedQuality(), BrokerBuiltInScoring.localModelQuality["qwen3.8-27b"]?["medium"])
    }

    func test_overridePrecedenceAndScope() {
        BrokerLocalLoad.$qualityOverride.withValue(["qwen3.8-27b": ["medium": 100]]) {
            XCTAssertEqual(injectedQuality(), 100)
            XCTAssertEqual(injectedQuality(explicit: 0), 0)
            GoldenFrozenTables.withFrozenLocalQuality {
                XCTAssertEqual(injectedQuality(), GoldenFrozenTables.localModelQuality["qwen3.8-27b"]?["medium"])
            }
            XCTAssertEqual(injectedQuality(), 100)
        }
        BrokerLocalLoad.$qualityOverride.withValue([:]) { XCTAssertNil(injectedQuality()) }
        XCTAssertNil(BrokerLocalLoad.qualityOverride)
        XCTAssertEqual(injectedQuality(), BrokerBuiltInScoring.localModelQuality["qwen3.8-27b"]?["medium"])
    }
}
