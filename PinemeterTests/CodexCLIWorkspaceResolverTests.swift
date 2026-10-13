//
//  CodexCLIWorkspaceResolverTests.swift
//  PinemeterTests
//

import Darwin
import Foundation
import XCTest
@testable import Pinemeter

final class CodexCLIWorkspaceResolverTests: XCTestCase {
    // MARK: - resolve(data:)

    func test_resolve_readsAccountIdAndNeverDecodesTokensOrAPIKey() throws {
        let json = """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": "sk-should-never-be-read",
          "tokens": {
            "access_token": "should-never-be-read",
            "refresh_token": "should-never-be-read",
            "id_token": "\(Self.fakeIdToken(chatgptUserId: "user-TESTuser0002"))",
            "account_id": "00000000-0000-0000-0000-000000000002"
          },
          "last_refresh": "2026-09-25T23:27:57.129430Z"
        }
        """.data(using: .utf8)!

        let workspace = try XCTUnwrap(CodexCLIWorkspaceResolver.resolve(data: json))

        XCTAssertEqual(workspace.accountId, "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(workspace.chatgptUserId, "user-TESTuser0002")

        // The decode target itself has no CodingKeys/properties for these --
        // asserted directly against the source's coding-key declarations
        // (not prose, which can legitimately mention these names in a
        // comment), since a future careless edit adding a real
        // `access_token`/`refresh_token`/`OPENAI_API_KEY` CodingKey would
        // silently start reading it without any behavioral test catching it.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter/Services/CodexCLIWorkspaceResolver.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains(#"case "access_token""#) || source.contains("\"access_token\""))
        XCTAssertFalse(source.contains("\"refresh_token\""))
        XCTAssertFalse(source.contains("\"OPENAI_API_KEY\""))
    }

    func test_resolve_returnsNilForMissingOrBlankAccountId() {
        let missing = #"{"tokens": {"id_token": "x"}}"#.data(using: .utf8)!
        XCTAssertNil(CodexCLIWorkspaceResolver.resolve(data: missing))

        let blank = #"{"tokens": {"account_id": "   "}}"#.data(using: .utf8)!
        XCTAssertNil(CodexCLIWorkspaceResolver.resolve(data: blank))
    }

    func test_resolve_returnsNilForMalformedJSON() {
        let malformed = Data("not json at all {{{".utf8)
        XCTAssertNil(CodexCLIWorkspaceResolver.resolve(data: malformed))
    }

    func test_resolve_returnsAccountIdWithNilUserIdWhenIdTokenClaimIsUndecodable() throws {
        let json = """
        {"tokens": {"id_token": "not-a-jwt", "account_id": "00000000-0000-0000-0000-000000000003"}}
        """.data(using: .utf8)!

        let workspace = try XCTUnwrap(CodexCLIWorkspaceResolver.resolve(data: json))

        XCTAssertEqual(workspace.accountId, "00000000-0000-0000-0000-000000000003")
        XCTAssertNil(workspace.chatgptUserId)
    }

    func test_resolve_returnsAccountIdWithNilUserIdWhenIdTokenIsAbsent() throws {
        let json = #"{"tokens": {"account_id": "00000000-0000-0000-0000-000000000004"}}"#.data(using: .utf8)!

        let workspace = try XCTUnwrap(CodexCLIWorkspaceResolver.resolve(data: json))

        XCTAssertEqual(workspace.accountId, "00000000-0000-0000-0000-000000000004")
        XCTAssertNil(workspace.chatgptUserId)
    }

    // MARK: - resolve(environment:) file resolution

    func test_resolve_prefersCodexHomeOverHomeFallback() throws {
        let fileManager = FileManager.default
        let codexHomeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let homeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: codexHomeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: codexHomeDir)
            try? fileManager.removeItem(at: homeDir)
        }

        try #"{"tokens": {"account_id": "00000000-0000-0000-0000-000000000005"}}"#
            .write(to: codexHomeDir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try #"{"tokens": {"account_id": "00000000-0000-0000-0000-000000000006"}}"#
            .write(
                to: homeDir.appendingPathComponent(".codex").appendingPathComponent("auth.json"),
                atomically: true,
                encoding: .utf8
            )

        let withCodexHome = CodexCLIWorkspaceResolver.resolve(environment: [
            "CODEX_HOME": codexHomeDir.path,
            "HOME": homeDir.path,
        ])
        XCTAssertEqual(withCodexHome?.accountId, "00000000-0000-0000-0000-000000000005")

        let homeOnly = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": homeDir.path])
        XCTAssertEqual(homeOnly?.accountId, "00000000-0000-0000-0000-000000000006")
    }

    func test_resolve_returnsNilWhenAuthFileIsMissing() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": emptyDir.path])
        XCTAssertNil(result)
    }

    func test_resolve_returnsNilWithoutHomeOrCodexHome() {
        XCTAssertNil(CodexCLIWorkspaceResolver.resolve(environment: [:]))
    }

    func test_resolve_returnsNilWhenAuthFileIsADirectory() throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexDir = homeDir.appendingPathComponent(".codex")
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDir) }

        try fileManager.createDirectory(at: codexDir.appendingPathComponent("auth.json"), withIntermediateDirectories: true)

        let result = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": homeDir.path])
        XCTAssertNil(result)
    }

    func test_resolve_followsSymlinkToReadValidAuthFile() throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexDir = homeDir.appendingPathComponent(".codex")
        let realDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: homeDir)
            try? fileManager.removeItem(at: realDir)
        }

        let realAuthFile = realDir.appendingPathComponent("auth.json")
        try #"{"tokens": {"account_id": "00000000-0000-0000-0000-000000000007"}}"#
            .write(to: realAuthFile, atomically: true, encoding: .utf8)

        try fileManager.createSymbolicLink(
            at: codexDir.appendingPathComponent("auth.json"),
            withDestinationURL: realAuthFile
        )

        let result = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": homeDir.path])
        XCTAssertEqual(result?.accountId, "00000000-0000-0000-0000-000000000007")
    }

    /// A dangling symlink (target never existed) must resolve to nil at
    /// once, the same as a missing file -- never hang or throw uncaught.
    func test_resolve_returnsNilForBrokenSymlink() throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexDir = homeDir.appendingPathComponent(".codex")
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDir) }

        let missingTarget = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createSymbolicLink(
            at: codexDir.appendingPathComponent("auth.json"),
            withDestinationURL: missingTarget
        )

        let result = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": homeDir.path])
        XCTAssertNil(result)
    }

    /// A symlink to a FIFO must resolve to nil at once. `resolve` checks
    /// `isRegularFileKey` before `Data(contentsOf:)`, so it must never open
    /// the pipe -- opening a FIFO for reading blocks until a writer
    /// connects, which nothing here ever does.
    func test_resolve_returnsNilForSymlinkToFIFO() throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexDir = homeDir.appendingPathComponent(".codex")
        let realDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: homeDir)
            try? fileManager.removeItem(at: realDir)
        }

        let fifoPath = realDir.appendingPathComponent("auth.json")
        XCTAssertEqual(mkfifo(fifoPath.path, 0o600), 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        try fileManager.createSymbolicLink(
            at: codexDir.appendingPathComponent("auth.json"),
            withDestinationURL: fifoPath
        )

        let result = CodexCLIWorkspaceResolver.resolve(environment: ["HOME": homeDir.path])
        XCTAssertNil(result)
    }

    // MARK: - Test helpers

    /// Builds an unsigned test JWT carrying only the one claim this resolver
    /// reads, matching Codex CLI's real `id_token` shape
    /// (`https://api.openai.com/auth.chatgpt_user_id`). Never a real token.
    private static func fakeIdToken(chatgptUserId: String) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_user_id":"\#(chatgptUserId)"}}"#
        func base64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64url(header)).\(base64url(payload)).signature-not-checked"
    }
}
