import CryptoKit
import Foundation
import XCTest
@testable import Pinemeter

final class BrokerHealthDocumentTests: XCTestCase {
    private var directory: URL { GoldenFixture.goldenDirectory.appendingPathComponent("health") }

    private func keys() throws -> [String: Curve25519.Signing.PublicKey] {
        let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("keys.json")))
        return try encoded.mapValues { text in
            let data = try XCTUnwrap(Data(base64Encoded: text))
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        }
    }

    func test_releaseKeysRejectGoldenDocument() throws {
        let body = try Data(contentsOf: directory.appendingPathComponent("valid-empty.signed"))
        let result = BrokerHealthDocument.accept(body: body, stored: nil, keys: BrokerHealthKeys.trusted, now: try XCTUnwrap(BrokerHealthDocument.parseTime("2026-10-13T12:00:00Z")))
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.category, .unknownKey)
    }

    func test_everyCommittedHealthFixture() throws {
        struct Expectation: Decodable {
            let now: Date
            let stored_case: String?
            let use_model_health: Bool
            let outcome: String
            let category: String
            let snapshot: BrokerHealthSnapshot?
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "signed" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "empty health corpus must fail")
        let keys = try keys()
        let decoder = BrokerHealthDocument.decoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = BrokerHealthDocument.parseTime(text) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try XCTUnwrap(formatter.date(from: text))
        }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let expected = try decoder.decode(Expectation.self, from: Data(contentsOf: directory.appendingPathComponent(name + ".expect.json")))
            let stored = try expected.stored_case.map { try Data(contentsOf: directory.appendingPathComponent($0 + ".signed")) }
            let result = BrokerHealthDocument.accept(body: try Data(contentsOf: file), stored: stored, keys: keys, now: expected.now)
            XCTAssertEqual(result.outcome.rawValue, expected.outcome, name)
            XCTAssertEqual(result.category?.rawValue ?? "", expected.category, name)
            let payload = result.payload ?? stored.flatMap {
                BrokerHealthDocument.accept(body: $0, stored: nil, keys: keys, now: expected.now).payload
            }
            XCTAssertEqual(payload?.snapshot(now: expected.now), expected.snapshot, name)
            let check = BrokerHealthCheck(at: expected.now, result: result.category?.rawValue ?? result.outcome.rawValue)
            let status = BrokerHealthDocument.status(stored: payload, now: expected.now, useModelHealth: expected.use_model_health, lastCheck: check)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let actual = try JSONSerialization.jsonObject(with: encoder.encode(status)) as? NSDictionary
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name + ".expect.json"))) as? [String: Any]
            XCTAssertEqual(actual, document?["status"] as? NSDictionary, name)
            if let payload {
                let snapshot = try JSONSerialization.jsonObject(with: encoder.encode(payload.snapshot(now: expected.now))) as? NSDictionary
                XCTAssertEqual(snapshot, document?["snapshot"] as? NSDictionary, name)
            }
        }
    }

    func test_statusAbsentOmitsUnknownValues() throws {
        let status = BrokerHealthDocument.status(stored: nil, now: Date(timeIntervalSince1970: 0), useModelHealth: false, lastCheck: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["present", "useModelHealth", "demotions", "sources"]))
        XCTAssertEqual(object["present"] as? Bool, false)
        XCTAssertEqual((object["demotions"] as? [Any])?.count, 0)
        XCTAssertEqual((object["sources"] as? [Any])?.count, 0)
    }

    func test_timestampUsesGregorianCalendarAndExactForm() throws {
        for text in ["0000-02-29T00:00:00Z", "0001-01-01T00:00:00Z", "1000-01-01T00:00:00Z", "1582-10-10T00:00:00Z", "2000-02-29T23:59:59Z", "9999-12-31T23:59:59Z"] {
            let date = try XCTUnwrap(BrokerHealthDocument.parseTime(text), text)
            XCTAssertEqual(BrokerHealthDocument.formatTime(date), text)
        }
        XCTAssertEqual(BrokerHealthDocument.parseTime("1000-01-01T00:00:00Z")?.timeIntervalSince1970, -30610224000)
        for text in ["1900-02-29T00:00:00Z", "2026-02-30T00:00:00Z", "2026-10-13T24:00:00Z", "2026-10-13T12:00:60Z", "2026-10-13T12:00:00.0Z", "2026-10-13T12:00:00+00:00"] {
            XCTAssertNil(BrokerHealthDocument.parseTime(text), text)
        }
    }
}
