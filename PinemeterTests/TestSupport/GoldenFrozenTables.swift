import Foundation
import XCTest
@testable import Pinemeter

/// Immutable recording inputs. Generators must never write these fixtures.
enum GoldenFrozenTables {
    static let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("broker-presets-golden-frozen.json")

    static func manifest() throws -> BrokerPresetManifest {
        try BrokerPresetManifest.decode(from: Data(contentsOf: manifestURL))
    }

    static func scoring(presetName: String = "Balanced") throws -> BrokerScoring {
        try XCTUnwrap(manifest().presets.first { $0.name == presetName },
            "Frozen preset missing: \(presetName)").rules.scoring
    }

    static var bundledDefault: BrokerPolicy {
        var policy = BrokerPolicy.bundledDefault
        policy.scoring = try! scoring()
        return policy
    }

    static let localModelQuality: [String: [String: Int]] = {
        let url = manifestURL.deletingLastPathComponent()
            .appendingPathComponent("golden-frozen-local-quality.json")
        return try! JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
    }()

    static func withFrozenLocalQuality<T>(_ body: () throws -> T) rethrows -> T {
        try BrokerLocalLoad.$qualityOverride.withValue(localModelQuality, operation: body)
    }
}
