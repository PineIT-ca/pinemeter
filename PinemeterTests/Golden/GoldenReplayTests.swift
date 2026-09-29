//
//  GoldenReplayTests.swift
//  PinemeterTests
//
//  Drift guard for the golden decision corpus (ENGINE-01, D-03).
//
//  Every committed fixture is replayed through the engine and its output is
//  compared against the committed bytes. A failure here means one of two
//  things, and the reviewer must decide which: the engine's behaviour changed
//  (regenerate and review the corpus diff as a behaviour change), or the
//  engine regressed (fix the engine). It is never "just update the fixtures".
//
//  This test must not depend on the recorder or its environment variable —
//  it reads what is committed, not what a run happens to produce.
//

import Foundation
import XCTest
@testable import Pinemeter

final class GoldenReplayTests: XCTestCase {

    // MARK: - Encoder pin

    func test_canonicalEncoderIsPinned() {
        XCTAssertTrue(
            BrokerDecision.makeEncoder().outputFormatting.contains(.sortedKeys),
            "the golden corpus stores canonical decision bytes; without .sortedKeys "
                + "the wire encoder's key order varies per process launch and every "
                + "replay comparison becomes a coin flip"
        )
        XCTAssertTrue(
            BrokerDecision.makeEncoder().outputFormatting.contains(.withoutEscapingSlashes),
            "candidate ids and slash commands are stored unescaped in the corpus"
        )
    }

    // MARK: - Replay

    func test_everyCommittedFixtureReplaysByteForByte() throws {
        let inputs = try fixtureInputs()
        XCTAssertGreaterThan(
            inputs.count,
            0,
            "no fixtures found in \(GoldenFixture.decisionsDirectory.path) — an empty "
                + "corpus must fail loudly rather than pass vacuously; "
                + "run scripts/golden-export.sh"
        )

        for inputURL in inputs {
            let caseName = caseName(for: inputURL)
            let input: GoldenInput
            do {
                input = try GoldenFixture.decoder().decode(
                    GoldenInput.self, from: try Data(contentsOf: inputURL)
                )
            } catch {
                XCTFail("\(caseName): could not decode input fixture: \(error)")
                continue
            }
            XCTAssertEqual(
                input.schema,
                GoldenInput.currentSchema,
                "\(caseName): fixture schema \(input.schema) is not the schema this "
                    + "build understands (\(GoldenInput.currentSchema))"
            )

            let oracle: OracleSnapshot?
            do {
                oracle = try input.oracle?.snapshot()
            } catch {
                XCTFail("\(caseName): could not rebuild the oracle snapshot: \(error)")
                continue
            }

            let decisionURL = sibling(of: inputURL, suffix: "decision.json")
            let errorURL = sibling(of: inputURL, suffix: "error.json")

            do {
                let decision: BrokerDecision
                if let override = input.overrideCandidate {
                    decision = try BrokerEngine.decideOverride(
                        role: input.role,
                        caller: input.caller,
                        overrideCandidate: override,
                        policy: input.policy,
                        oracle: oracle,
                        cooldowns: input.cooldowns,
                        now: input.now,
                        t3: input.liveness()
                    )
                } else {
                    decision = try BrokerEngine.decide(
                        role: input.role,
                        caller: input.caller,
                        policy: input.policy,
                        oracle: oracle,
                        cooldowns: input.cooldowns,
                        now: input.now,
                        t3: input.liveness()
                    )
                }
                guard let expected = try? Data(contentsOf: decisionURL) else {
                    XCTFail(
                        "\(caseName): the engine returned a decision but "
                            + "\(decisionURL.lastPathComponent) is missing"
                    )
                    continue
                }
                assertBytesEqual(
                    try GoldenFixture.canonicalEncoder().encode(decision),
                    expected,
                    caseName: caseName,
                    file: decisionURL.lastPathComponent
                )
            } catch let error as BrokerError {
                guard let fixture = GoldenErrorFixture(error) else {
                    XCTFail("\(caseName): could not describe thrown error \(error)")
                    continue
                }
                guard let expected = try? Data(contentsOf: errorURL) else {
                    XCTFail(
                        "\(caseName): the engine threw \(fixture.caseName) but "
                            + "\(errorURL.lastPathComponent) is missing"
                    )
                    continue
                }
                assertBytesEqual(
                    try GoldenFixture.canonicalEncoder().encode(fixture),
                    expected,
                    caseName: caseName,
                    file: errorURL.lastPathComponent
                )
            }
        }
    }

    // MARK: - Corpus integrity

    func test_fixtureDirectoryHasNoOrphans() throws {
        let files = try corpusFiles()
        let inputs = Set(
            files.filter { $0.hasSuffix(".input.json") }
                .map { String($0.dropLast(".input.json".count)) }
        )
        let decisions = files.filter { $0.hasSuffix(".decision.json") }
            .map { String($0.dropLast(".decision.json".count)) }
        let errors = files.filter { $0.hasSuffix(".error.json") }
            .map { String($0.dropLast(".error.json".count)) }

        for name in decisions where !inputs.contains(name) {
            XCTFail("\(name).decision.json has no sibling .input.json")
        }
        for name in errors where !inputs.contains(name) {
            XCTFail("\(name).error.json has no sibling .input.json")
        }
        XCTAssertEqual(
            inputs.count,
            decisions.count + errors.count,
            "every input must have exactly one outcome file; "
                + "\(inputs.count) inputs vs \(decisions.count) decisions "
                + "+ \(errors.count) errors"
        )

        let unexpected = files.filter {
            !$0.hasSuffix(".input.json") && !$0.hasSuffix(".decision.json")
                && !$0.hasSuffix(".error.json")
        }
        XCTAssertEqual(unexpected, [], "unexpected files in the decision corpus")
    }

    // MARK: - Helpers

    private func corpusFiles() throws -> [String] {
        let directory = GoldenFixture.decisionsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func fixtureInputs() throws -> [URL] {
        try corpusFiles()
            .filter { $0.hasSuffix(".input.json") }
            .map { GoldenFixture.decisionsDirectory.appendingPathComponent($0) }
    }

    private func caseName(for inputURL: URL) -> String {
        let name = inputURL.lastPathComponent
        guard name.hasSuffix(".input.json") else { return name }
        return String(name.dropLast(".input.json".count))
    }

    private func sibling(of inputURL: URL, suffix: String) -> URL {
        inputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(caseName(for: inputURL)).\(suffix)")
    }

    private func assertBytesEqual(
        _ actual: Data,
        _ expected: Data,
        caseName: String,
        file: String
    ) {
        guard actual != expected else { return }
        let offset = Self.firstDifference(actual, expected)
        XCTFail(
            """
            \(caseName): replay does not match \(file)
            first differing byte offset: \(offset.map(String.init) ?? "n/a (length only)")
            expected (\(expected.count) bytes): \(String(decoding: expected, as: UTF8.self))
            actual   (\(actual.count) bytes): \(String(decoding: actual, as: UTF8.self))
            """
        )
    }

    static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        let shared = min(lhs.count, rhs.count)
        for offset in 0..<shared where lhs[lhs.startIndex + offset] != rhs[rhs.startIndex + offset] {
            return offset
        }
        return lhs.count == rhs.count ? nil : shared
    }
}
