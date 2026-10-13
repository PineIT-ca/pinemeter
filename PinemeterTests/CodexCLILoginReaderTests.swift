//
//  CodexCLILoginReaderTests.swift
//  PinemeterTests
//

import Darwin
import Foundation
import XCTest
@testable import Pinemeter

final class CodexCLILoginReaderTests: XCTestCase {
    // Rounded to a whole second: `exp` round-trips through a JSON number
    // (Double -> String -> Double) when it is embedded in the synthetic
    // token's payload below, and a sub-second `now` can land exactly on the
    // `exp <= now + skew` boundary where that round trip's last-bit rounding
    // decides the outcome -- flaky by construction. A whole-second value
    // always round-trips exactly.
    private static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private var tempDirectoryURL: URL?

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinemeter-codex-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectoryURL = url
        return url
    }

    // MARK: - decode(_:now:)

    func test_decode_returnsLoginForValidChatGPTAuth() throws {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: "pro",
            email: "user@example.com"
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")

        let login = try XCTUnwrap(CodexCLILoginReader.decode(json, now: Self.now))
        XCTAssertEqual(login.accountId, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(login.chatgptUserId, "user-TESTuser0001")
        XCTAssertEqual(login.planType, "pro")
        XCTAssertEqual(login.email, "user@example.com")
    }

    func test_decode_returnsLoginForTokenExpiringOneSecondAfterSkewBoundary() throws {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(61).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNotNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForNonChatGPTAuthMode() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "apikey", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForTokenExpiringExactlyAtSkewBoundary() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(60).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForAlreadyExpiredToken() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(-1).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForMissingExp() {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = """
        {"https://api.openai.com/auth":{"chatgpt_user_id":"user-TESTuser0001","chatgpt_account_id":"00000000-0000-0000-0000-000000000001"}}
        """
        let token = "\(Self.base64url(header)).\(Self.base64url(payload)).signature-not-checked"
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForBlankAccessToken() {
        let json = Self.authJSON(authMode: "chatgpt", accessToken: "   ", accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForBlankAccountId() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "   ")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilWhenChatgptAccountIdClaimDiffersFromTokensAccountId() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000002",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))
    }

    func test_decode_returnsNilForAccessTokenWithoutThreeSegments() {
        let json = Self.authJSON(authMode: "chatgpt", accessToken: "only.two", accountId: "00000000-0000-0000-0000-000000000001")
        XCTAssertNil(CodexCLILoginReader.decode(json, now: Self.now))

        let fourSegments = Self.authJSON(
            authMode: "chatgpt",
            accessToken: "a.b.c.d",
            accountId: "00000000-0000-0000-0000-000000000001"
        )
        XCTAssertNil(CodexCLILoginReader.decode(fourSegments, now: Self.now))
    }

    func test_decode_returnsNilForMalformedJSON() {
        let malformed = Data("not json at all {{{".utf8)
        XCTAssertNil(CodexCLILoginReader.decode(malformed, now: Self.now))
    }

    func test_decode_returnsNilForTruncatedJSON() {
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let full = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        let truncated = full.prefix(full.count / 2)
        XCTAssertNil(CodexCLILoginReader.decode(Data(truncated), now: Self.now))
    }

    // MARK: - read(environment:now:expectedOwnerId:)

    func test_read_returnsNilForDirectoryAtAuthFilePath() throws {
        let tempDirectory = try makeTempDirectory()
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("auth.json"),
            withIntermediateDirectories: true
        )
        let login = CodexCLILoginReader.read(environment: ["CODEX_HOME": tempDirectory.path], now: Self.now)
        XCTAssertNil(login)
    }

    func test_read_returnsNilForFIFOAtAuthFilePath() throws {
        let tempDirectory = try makeTempDirectory()
        let fifoPath = tempDirectory.appendingPathComponent("auth.json").path
        let result = mkfifo(fifoPath, 0o600)
        XCTAssertEqual(result, 0, "mkfifo must succeed for this test to be meaningful")

        let login = CodexCLILoginReader.read(environment: ["CODEX_HOME": tempDirectory.path], now: Self.now)
        XCTAssertNil(login)
    }

    func test_read_returnsNilForFileOverMaxBytes() throws {
        let tempDirectory = try makeTempDirectory()
        let oversized = Data(repeating: 0x20, count: CodexCLILoginReader.maxAuthFileBytes + 1)
        try oversized.write(to: tempDirectory.appendingPathComponent("auth.json"))

        let login = CodexCLILoginReader.read(environment: ["CODEX_HOME": tempDirectory.path], now: Self.now)
        XCTAssertNil(login)
    }

    func test_read_returnsNilForWrongExpectedOwner() throws {
        let tempDirectory = try makeTempDirectory()
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: nil,
            email: nil
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        try json.write(to: tempDirectory.appendingPathComponent("auth.json"))

        let login = CodexCLILoginReader.read(
            environment: ["CODEX_HOME": tempDirectory.path],
            now: Self.now,
            expectedOwnerId: getuid() + 1
        )
        XCTAssertNil(login)
    }

    func test_read_followsSymlinkToValidRegularFile() throws {
        let tempDirectory = try makeTempDirectory()
        let token = Self.fakeAccessToken(
            exp: Self.now.addingTimeInterval(3600).timeIntervalSince1970,
            chatgptUserId: "user-TESTuser0001",
            chatgptAccountId: "00000000-0000-0000-0000-000000000001",
            chatgptPlanType: "pro",
            email: "user@example.com"
        )
        let json = Self.authJSON(authMode: "chatgpt", accessToken: token, accountId: "00000000-0000-0000-0000-000000000001")
        let realFile = tempDirectory.appendingPathComponent("real-auth.json")
        try json.write(to: realFile)
        let symlinkPath = tempDirectory.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: realFile)

        let login = CodexCLILoginReader.read(environment: ["CODEX_HOME": tempDirectory.path], now: Self.now)
        XCTAssertNotNil(login)
        XCTAssertEqual(login?.chatgptUserId, "user-TESTuser0001")
    }

    // MARK: - Decode surface (reflection + source assertion)

    func test_decodeSurface_mirrorLabelsAreExactlyTheDocumentedFields() throws {
        let json = Self.authJSON(authMode: "chatgpt", accessToken: "x.y.z", accountId: "00000000-0000-0000-0000-000000000001")
        let payload = try JSONDecoder().decode(CodexCLILoginReader.AuthPayload.self, from: json)

        let payloadMirror = Mirror(reflecting: payload)
        XCTAssertEqual(payloadMirror.children.map(\.label), [Optional("authMode"), Optional("tokens")])

        let tokensMirror = Mirror(reflecting: try XCTUnwrap(payload.tokens))
        XCTAssertEqual(tokensMirror.children.map(\.label), [Optional("accessToken"), Optional("accountId")])
    }

    func test_decodeSurface_sourceNeverQuotesSensitiveCodingKeys() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter/Services/CodexCLILoginReader.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("\"refresh_token\""))
        XCTAssertFalse(source.contains("\"id_token\""))
        XCTAssertFalse(source.contains("\"OPENAI_API_KEY\""))
    }

    // MARK: - CLIAccessToken redaction

    func test_cliAccessToken_redactsEveryReflectiveSurface() {
        let secret = "sk-synthetic-should-never-appear-anywhere"
        let token = CLIAccessToken(secret)

        XCTAssertEqual(String(describing: token), "<redacted>")
        XCTAssertEqual(String(reflecting: token), "<redacted>")
        XCTAssertEqual("\(token)", "<redacted>")

        var dumpOutput = ""
        dump(token, to: &dumpOutput)
        XCTAssertFalse(dumpOutput.contains(secret))
        XCTAssertTrue(dumpOutput.contains("<redacted>"))

        XCTAssertEqual(token.authorizationHeaderValue, "Bearer \(secret)")
    }

    // MARK: - Helpers

    private static func authJSON(authMode: String, accessToken: String, accountId: String) -> Data {
        let escapedToken = accessToken.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAccountId = accountId.replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {
          "auth_mode": "\(authMode)",
          "tokens": {
            "access_token": "\(escapedToken)",
            "account_id": "\(escapedAccountId)"
          },
          "last_refresh": "2026-09-25T23:27:57.129430Z"
        }
        """
        return Data(json.utf8)
    }

    private static func fakeAccessToken(
        exp: Double,
        chatgptUserId: String,
        chatgptAccountId: String,
        chatgptPlanType: String?,
        email: String?
    ) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        var authFields = [
            #""chatgpt_user_id":"\#(chatgptUserId)""#,
            #""chatgpt_account_id":"\#(chatgptAccountId)""#,
        ]
        if let chatgptPlanType {
            authFields.append(#""chatgpt_plan_type":"\#(chatgptPlanType)""#)
        }
        var payloadFields = [
            #""exp":\#(exp)"#,
            #""https://api.openai.com/auth":{\#(authFields.joined(separator: ","))}"#,
        ]
        if let email {
            payloadFields.append(#""https://api.openai.com/profile":{"email":"\#(email)"}"#)
        }
        let payload = "{\(payloadFields.joined(separator: ","))}"
        return "\(base64url(header)).\(base64url(payload)).signature-not-checked"
    }

    private static func base64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
