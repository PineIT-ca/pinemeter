import CryptoKit
import Foundation
import XCTest
@testable import Pinemeter

final class BrokerOfficialPresetStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("broker-official-presets.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func seed(_ store: BrokerOfficialPresetStore) async throws -> BrokerOfficialPresetState {
        _ = await store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        return try await store.accept(line: PresetSigningFixture.line(), etag: "v1", checkedAt: PresetSigningFixture.now)
    }

    func test_atomicFilePersistsLineETagAndCheck() async throws {
        let state = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["document"] as? String, String(decoding: try XCTUnwrap(state.line), as: UTF8.self))
        XCTAssertEqual(object["etag"] as? String, "v1")
        XCTAssertEqual((object["last_check"] as? [String: String])?["result"], "accepted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["broker-official-presets.json"])
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, BrokerOfficialPresetStore.maxBytes)
        let loaded = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(loaded, state)
    }

    func test_staleCopyAfterReloadKeepsNewestLineAndETag() async throws {
        let initial = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        _ = await store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        let newer = try await store.accept(line: PresetSigningFixture.line(seq: 2, name: "Newer"), etag: "v2", checkedAt: PresetSigningFixture.now)
        let restarted = BrokerOfficialPresetStore(storeDirectory: directory)
        _ = await restarted.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        let stale = try await restarted.accept(line: XCTUnwrap(initial.line), etag: "old", checkedAt: PresetSigningFixture.now)
        XCTAssertEqual(stale.lastCheck?.result, "stale_copy")
        XCTAssertEqual(stale.payload?.seq, 2)
        XCTAssertEqual(stale.line, newer.line)
        XCTAssertEqual(stale.manifest, newer.manifest)
        XCTAssertEqual(stale.etag, "v2")
    }

    func test_equalBytesAreUnchanged() async throws {
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        let initial = try await seed(store)
        let state = try await store.accept(line: XCTUnwrap(initial.line), etag: "refreshed", checkedAt: PresetSigningFixture.now)
        XCTAssertEqual(state.lastCheck?.result, "unchanged")
        XCTAssertEqual(state.payload, initial.payload)
        XCTAssertEqual(state.manifest, initial.manifest)
        XCTAssertEqual(state.line, initial.line)
        XCTAssertEqual(state.etag, "refreshed")
    }

    func test_stalePrecomputedAcceptanceCannotOverwriteNewerRecord() async throws {
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        let initial = try await seed(store)
        let old = BrokerPresetSignature.accept(line: try XCTUnwrap(initial.line), stored: nil,
            keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        _ = try await store.accept(line: PresetSigningFixture.line(seq: 3), etag: "v3", checkedAt: PresetSigningFixture.now)
        let state = try await store.record(acceptance: old, etag: "old", checkedAt: PresetSigningFixture.now)
        XCTAssertEqual(state.payload?.seq, 3)
        XCTAssertEqual(state.etag, "v3")
        XCTAssertEqual(state.lastCheck?.result, "stale_copy")
        let disk = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(disk, state)
    }

    func test_concurrentAcceptancesRetainHighestSequence() async throws {
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        _ = try await seed(store)
        let newer = try PresetSigningFixture.line(seq: 3)
        let older = try PresetSigningFixture.line(seq: 2)
        async let a = store.accept(line: newer, etag: "v3", checkedAt: PresetSigningFixture.now)
        async let b = store.accept(line: older, etag: "v2", checkedAt: PresetSigningFixture.now)
        _ = try await (a, b)
        let state = await store.snapshot()
        XCTAssertEqual(state.payload?.seq, 3)
        XCTAssertEqual(state.line, newer)
        XCTAssertEqual(state.etag, "v3")
    }

    func test_rejectionKeepsLastGoodLineAndManifest() async throws {
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        let initial = try await seed(store)
        let rejected = try await store.accept(line: Data("invalid".utf8), etag: "bad", checkedAt: PresetSigningFixture.now)
        XCTAssertEqual(rejected.lastCheck?.result, "malformed")
        XCTAssertEqual(rejected.line, initial.line)
        XCTAssertEqual(rejected.manifest, initial.manifest)
        XCTAssertEqual(rejected.etag, initial.etag)
        let conflict = try await store.accept(line: PresetSigningFixture.line(name: "Conflict"), etag: "bad", checkedAt: PresetSigningFixture.now)
        XCTAssertEqual(conflict.lastCheck?.result, "seq_conflict")
        XCTAssertEqual(conflict.line, initial.line)
    }

    func test_corruptOversizedUnsupportedAndDirectoryFilesLoadEmpty() async throws {
        for data in [Data("{\"version\":1".utf8), Data(repeating: 32, count: BrokerOfficialPresetStore.maxBytes + 1), Data("{\"version\":2}".utf8)] {
            try data.write(to: url)
            let loaded = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
            XCTAssertEqual(loaded, BrokerOfficialPresetState())
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let loaded = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(loaded, BrokerOfficialPresetState())
    }

    func test_editedLineAndRemovedKeyLoadEmpty() async throws {
        _ = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        let removed = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: [:], now: PresetSigningFixture.now)
        XCTAssertEqual(removed, BrokerOfficialPresetState())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["document"] = "edited"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let edited = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(edited, BrokerOfficialPresetState())
    }

    func test_defaultKeysRejectGoldenSignedState() async throws {
        _ = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        let loaded = await BrokerOfficialPresetStore(storeDirectory: directory).load(now: PresetSigningFixture.now)
        XCTAssertEqual(loaded, BrokerOfficialPresetState())
    }

    func test_writeFailurePreservesMemoryAndDisk() async throws {
        _ = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        let before = try Data(contentsOf: url)
        let store = BrokerOfficialPresetStore(storeDirectory: directory, writer: { _, _ in throw URLError(.cannotWriteToFile) })
        let initial = await store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        do {
            _ = try await store.accept(line: PresetSigningFixture.line(seq: 2), etag: "v2", checkedAt: PresetSigningFixture.now)
            XCTFail("writer must fail")
        } catch { XCTAssertEqual(error as? URLError, URLError(.cannotWriteToFile)) }
        let state = await store.snapshot()
        XCTAssertEqual(state, initial)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_unknownLocalCheckIsDiscardedOnLoad() async throws {
        _ = try await seed(BrokerOfficialPresetStore(storeDirectory: directory))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["last_check"] = ["at": "2026-10-17T12:00:00Z", "result": "untrusted-local-text"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let loaded = await BrokerOfficialPresetStore(storeDirectory: directory).load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertNil(loaded.lastCheck)
        XCTAssertEqual(loaded.payload?.seq, 1)
    }

    func test_releaseKeyInvariants() throws {
        func valid(_ keys: [String: Curve25519.Signing.PublicKey]) throws -> Bool {
            let golden = try XCTUnwrap(PresetSigningFixture.keys[PresetSigningFixture.kid]).rawRepresentation
            let health = Set(BrokerHealthKeys.trusted.values.map(\.rawRepresentation))
            return keys.allSatisfy { kid, key in
                kid != PresetSigningFixture.kid
                    && kid.range(of: "^presets-[0-9]{4}-[0-9]{2}\\z", options: .regularExpression) != nil
                    && key.rawRepresentation != golden && !health.contains(key.rawRepresentation)
            }
        }
        XCTAssertTrue(try valid(BrokerPresetKeys.trusted))
        var invalid = BrokerPresetKeys.trusted
        invalid[PresetSigningFixture.kid] = try PresetSigningFixture.privateKey.publicKey
        XCTAssertFalse(try valid(invalid), "negative control must detect the golden key")
        invalid = ["presets-2099-12": try PresetSigningFixture.privateKey.publicKey]
        XCTAssertFalse(try valid(invalid), "renaming the golden kid cannot hide its key")
    }
}
