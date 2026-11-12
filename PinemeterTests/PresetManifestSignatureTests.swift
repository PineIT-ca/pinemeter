import CryptoKit
import Foundation
import XCTest
@testable import Pinemeter

final class PresetManifestSignatureTests: XCTestCase {
    private var directory: URL { GoldenFixture.goldenDirectory.appendingPathComponent("presets") }

    func test_everyCommittedPresetVector() throws {
        struct Expectation: Decodable {
            let stored: String?
            let now: Date
            let outcome: String
            let category: String
            let seq: UInt64?
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let signed = files.filter { $0.pathExtension == "signed" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(signed.isEmpty, "empty corpus must fail")
        XCTAssertEqual(Set(signed.map { $0.deletingPathExtension().lastPathComponent }),
            Set(files.filter { $0.lastPathComponent.hasSuffix(".expect.json") }
                .map { String($0.lastPathComponent.dropLast(".expect.json".count)) }), "orphaned vectors must fail")
        let encoded = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("keys.json")))
        let keys = try encoded.mapValues {
            try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: $0)))
        }
        XCTAssertEqual(keys[PresetSigningFixture.kid]?.rawRepresentation,
                       try PresetSigningFixture.keys[PresetSigningFixture.kid]?.rawRepresentation)
        for file in signed {
            let name = file.deletingPathExtension().lastPathComponent
            let expected = try BrokerHealthDocument.decoder().decode(Expectation.self,
                from: Data(contentsOf: directory.appendingPathComponent(name + ".expect.json")))
            let stored = try expected.stored.map { try Data(contentsOf: directory.appendingPathComponent($0 + ".signed")) }
            let result = BrokerPresetSignature.accept(line: try Data(contentsOf: file), stored: stored, keys: keys, now: expected.now)
            XCTAssertEqual(result.outcome.rawValue, expected.outcome, name)
            XCTAssertEqual(result.category?.rawValue ?? "", expected.category, name)
            XCTAssertEqual(result.payload?.seq, expected.seq, name)
        }
    }

    func test_versionOverflowIsMalformedBeforeUnsupportedVersion() throws {
        let raw = try BrokerPresetSignature.verify(line: PresetSigningFixture.line(), keys: PresetSigningFixture.keys)
        let text = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":9223372036854775808")
        let result = BrokerPresetSignature.accept(line: try PresetSigningFixture.sign(Data(text.utf8)),
            stored: nil, keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(result.category, .malformed, "Go rejects a version outside its signed integer range")
    }

    func test_rejectionTextsAreClosedAndKeepCurrentPresets() {
        for rejection in [BrokerPresetSignature.Rejection.tooLarge, .malformed, .signature, .wrongType, .unsupportedVersion, .seqConflict] {
            XCTAssertEqual(rejection.errorDescription,
                "The official preset update failed its signature check. Current presets stay in use.")
        }
        XCTAssertEqual(BrokerPresetSignature.Rejection.unknownKey.errorDescription,
            "This build cannot verify official preset updates. Current presets stay in use.")
        XCTAssertEqual(BrokerPresetSignature.Rejection.futureIssued.errorDescription,
            "The official preset update has a date in the future. Current presets stay in use.")
        XCTAssertEqual(BrokerPresetSignature.Rejection.undecodable.errorDescription,
            "This version cannot read the official preset update. Update Pinemeter to receive it. Current presets stay in use.")
    }

    func test_signedTransportUsesCompiledURLTimeoutAndStoreETag() async throws {
        let body = try PresetSigningFixture.line()
        let session = HealthTestSupport.session(body: body, headers: ["ETag": "next"])
        defer { session.invalidateAndCancel() }
        let outcome = try await PresetManifestService(session: session).fetchSigned(etag: "stored")
        XCTAssertEqual(outcome, .updated(line: body, etag: "next"))
        let request = try XCTUnwrap(HealthStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, BrokerPresetDistribution.officialURL)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "stored")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pinemeter")
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
    }

    func test_signedTransportEnforcesDeclaredAndStreamedCaps() async throws {
        for declared in [false, true] {
            let session = HealthTestSupport.session(
                body: declared ? Data() : Data(repeating: 32, count: BrokerPresetSignature.maxBytes + 1),
                headers: declared ? ["Content-Length": "524289"] : [:])
            defer { session.invalidateAndCancel() }
            do {
                _ = try await PresetManifestService(session: session).fetchSigned(etag: nil)
                XCTFail("oversized line must be refused")
            } catch { XCTAssertEqual(error as? PresetManifestService.FetchError, .tooLarge) }
        }
    }

    func test_signedTransportAcceptsExactCapAndSkips304Body() async throws {
        let body = Data(repeating: 32, count: BrokerPresetSignature.maxBytes)
        let session = HealthTestSupport.session(body: body)
        defer { session.invalidateAndCancel() }
        let outcome = try await PresetManifestService(session: session).fetchSigned(etag: "")
        XCTAssertEqual(outcome, .updated(line: body, etag: nil))
        XCTAssertNil(HealthStubURLProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"))
        let unchanged = HealthTestSupport.session(status: 304, body: body, headers: ["Content-Length": "524289"])
        defer { unchanged.invalidateAndCancel() }
        let result = try await PresetManifestService(session: unchanged).fetchSigned(etag: "same")
        XCTAssertEqual(result, .notModified)
    }

    func test_signedTransportRefusesCrossHostAndPlaintextRedirects() async throws {
        for destination in ["https://example.invalid/presets.signed", "http://pinemeter-dist.pineit.ca/presets.signed"] {
            let session = HealthTestSupport.session()
            defer { session.invalidateAndCancel() }
            HealthStubURLProtocol.configure { _ in .init(status: 301, redirect: URL(string: destination)) }
            do {
                _ = try await PresetManifestService(session: session).fetchSigned(etag: nil)
                XCTFail("redirect must be refused")
            } catch { XCTAssertEqual(error as? PresetManifestService.FetchError, .badStatus(301)) }
            XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        }
    }

    func test_signedTransportFollowsSameHTTPSHostRedirect() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        let body = try PresetSigningFixture.line()
        HealthStubURLProtocol.configure { request in
            if request.url?.path == "/v1/broker-presets.signed" {
                return .init(status: 302, redirect: URL(string: "https://pinemeter-dist.pineit.ca/next.signed"))
            }
            return .init(body: body)
        }
        let outcome = try await PresetManifestService(session: session).fetchSigned(etag: nil)
        XCTAssertEqual(outcome, .updated(line: body, etag: nil))
        XCTAssertEqual(HealthStubURLProtocol.requests.map { $0.url?.path }, ["/v1/broker-presets.signed", "/next.signed"])
    }

    func test_unsignedUserSourceStillUsesExistingDecodePath() async throws {
        let accepted = BrokerPresetSignature.accept(line: try PresetSigningFixture.line(), stored: nil,
            keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        let session = HealthTestSupport.session(body: try XCTUnwrap(accepted.payload?.manifest))
        defer { session.invalidateAndCancel() }
        let outcome = try await PresetManifestService(session: session).fetch(
            from: URL(string: "https://example.invalid/custom.json")!, etag: "user-etag")
        XCTAssertEqual(outcome, .updated(manifest: try PresetSigningFixture.manifest(), etag: nil))
        XCTAssertEqual(HealthStubURLProtocol.requests.first?.url?.host, "example.invalid")
        XCTAssertEqual(HealthStubURLProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "user-etag")
    }
}
