import Foundation
import XCTest
@testable import Pinemeter

final class BrokerHealthStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("broker-model-health.json") }

    override func setUpWithError() throws { directory = try HealthTestSupport.directory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func seed(_ store: BrokerHealthStore, name: String = "valid-two-demotions") async throws -> BrokerHealthState {
        let keys = try HealthTestSupport.keys()
        _ = await store.load(keys: keys, now: HealthTestSupport.now)
        let acceptance = BrokerHealthDocument.accept(body: try HealthTestSupport.body(name), stored: nil, keys: keys, now: HealthTestSupport.now)
        return try await store.record(acceptance: acceptance, etag: "v10", checkedAt: HealthTestSupport.now)
    }

    func test_oneAtomicFilePersistsLineETagAndLastCheck() async throws {
        let state = try await seed(BrokerHealthStore(storeDirectory: directory))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["document"] as? String, String(decoding: state.line!, as: UTF8.self))
        XCTAssertEqual(object["etag"] as? String, "v10")
        XCTAssertEqual((object["last_check"] as? [String: String])?["result"], "accepted")
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 65536)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["broker-model-health.json"])
    }

    func test_productionKeysNeverAcceptGoldenLineOnLoad() async throws {
        _ = try await seed(BrokerHealthStore(storeDirectory: directory))
        let state = await BrokerHealthStore(storeDirectory: directory).load(now: HealthTestSupport.now)
        XCTAssertEqual(state, BrokerHealthState())
    }

    func test_editedSignedLineLoadsNoDocument() async throws {
        _ = try await seed(BrokerHealthStore(storeDirectory: directory))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var document = Array((object["document"] as! String).utf8)
        document[10] = document[10] == 65 ? 66 : 65
        object["document"] = String(decoding: document, as: UTF8.self)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let state = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        XCTAssertEqual(state, BrokerHealthState())
    }

    func test_truncatedOversizedDirectoryAndUnsupportedFilesLoadEmpty() async throws {
        for data in [Data("{\"version\":1".utf8), Data(repeating: 32, count: 65537), Data("{\"version\":2}".utf8)] {
            try data.write(to: url)
            let state = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
            XCTAssertEqual(state, BrokerHealthState())
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let state = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        XCTAssertEqual(state, BrokerHealthState())
    }

    func test_writeFailurePreservesMemoryAndPreviousFile() async throws {
        _ = try await seed(BrokerHealthStore(storeDirectory: directory))
        let before = try Data(contentsOf: url)
        let failing = BrokerHealthStore(storeDirectory: directory, writer: { _, _ in throw URLError(.cannotWriteToFile) })
        let original = await failing.load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        let acceptance = BrokerHealthDocument.accept(body: try HealthTestSupport.body("higher-seq"), stored: original.line,
            keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        do {
            _ = try await failing.record(acceptance: acceptance, etag: "v11", checkedAt: HealthTestSupport.now)
            XCTFail("write must fail")
        } catch { XCTAssertEqual(error as? URLError, URLError(.cannotWriteToFile)) }
        let after = await failing.snapshot()
        XCTAssertEqual(after, original)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_expiredDocumentRetainsSequenceButDropsSnapshotEntries() async throws {
        let seeded = try await seed(BrokerHealthStore(storeDirectory: directory))
        let now = seeded.payload!.validUntil
        let state = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: now)
        XCTAssertEqual(state.payload?.seq, 10)
        XCTAssertEqual(state.snapshot(now: now)?.demotions, [])
        XCTAssertEqual(state.status(now: now, useModelHealth: true).expired, true)
    }

    func test_overlappingAcceptancesCannotRollBackNewestSequence() async throws {
        let store = BrokerHealthStore(storeDirectory: directory)
        let initial = try await seed(store)
        let keys = try HealthTestSupport.keys()
        let higher = BrokerHealthDocument.accept(body: try HealthTestSupport.body("higher-seq"), stored: initial.line, keys: keys, now: HealthTestSupport.now)
        let earlier = BrokerHealthDocument.accept(body: initial.line!, stored: nil, keys: keys, now: HealthTestSupport.now)
        async let first = store.record(acceptance: higher, etag: "v11", checkedAt: HealthTestSupport.now)
        async let second = store.record(acceptance: earlier, etag: "v10", checkedAt: HealthTestSupport.now)
        _ = try await (first, second)
        let final = await store.snapshot()
        let disk = await BrokerHealthStore(storeDirectory: directory).load(keys: keys, now: HealthTestSupport.now)
        XCTAssertEqual(final.payload?.seq, 11)
        XCTAssertEqual(final.etag, "v11")
        XCTAssertEqual(final, disk)
    }

    func test_unrecognizedStoredCheckCannotLeakIntoStatus() async throws {
        _ = try await seed(BrokerHealthStore(storeDirectory: directory))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["last_check"] = ["at": "2026-10-13T12:00:00Z", "result": "untrusted-local-text"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let state = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        XCTAssertNil(state.lastCheck, "unsigned metadata must not expose arbitrary strings")
        XCTAssertEqual(state.payload?.seq, 10, "valid signed document remains usable")
    }
}
