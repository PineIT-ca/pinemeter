import Foundation
import XCTest
@testable import Pinemeter

final class NoPrimarySourceFetchTests: XCTestCase {
    private static let deniedHosts = [
        "marginlab.ai", "artificialanalysis.ai", "status.claude.com", "status.anthropic.com",
        "status.openai.com", "bridgebench", "aistupidlevel"
    ]

    private static func violations(in contents: String) -> [String] {
        let lowercase = contents.lowercased()
        return deniedHosts.filter { lowercase.contains($0) }
    }

    func test_everyMacSwiftSourceHasNoPrimarySourceHost() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Pinemeter")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            scanned += 1
            let hits = Self.violations(in: try String(contentsOf: url, encoding: .utf8))
            XCTAssertTrue(hits.isEmpty, "primary-source host in \(url.lastPathComponent): \(hits)")
        }
        XCTAssertGreaterThan(scanned, 0, "empty source scan must fail")
    }

    func test_negativeControlFlagsEachHostIncludingMixedCase() {
        for host in Self.deniedHosts {
            XCTAssertEqual(Self.violations(in: "fetch https://\(host)/data"), [host])
            XCTAssertEqual(Self.violations(in: "fetch https://\(host.uppercased())/data"), [host])
        }
        XCTAssertEqual(Self.violations(in: Self.deniedHosts.joined(separator: "\n")), Self.deniedHosts)
    }

    func test_cleanControlAllowsCompiledHealthChannel() {
        XCTAssertEqual(Self.violations(in: BrokerHealthDocument.officialURL), [])
        XCTAssertEqual(Self.violations(in: BrokerPresetDistribution.officialURL), [])
        XCTAssertEqual(Self.violations(in: "import Foundation\nlet value = 1"), [])
    }
}
