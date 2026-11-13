import Darwin
import Foundation
import XCTest

final class SSHPreflightTests: XCTestCase {
    func testRealSSHAuthentication() throws {
        let report = SSHFixture.runPreflight()
        try report.writeIfRequested()

        switch report.status {
        case .pass:
            let attempt = try XCTUnwrap(report.attempts.last)
            XCTAssertTrue(attempt.authenticated)
            XCTAssertTrue(attempt.wrongPinRefused)
            XCTAssertTrue(attempt.wrongClientKeyRefused)
        case .blocked:
            throw XCTSkip("BLOCKED: \(report.reason)")
        case .error:
            XCTFail(report.reason)
        }
    }

    func testSetupFailureRemovesPrivateFixtureFiles() {
        var configuration = SSHFixture.Configuration()
        configuration.modes = [.standalone]
        configuration.fault = .setupFailure

        let result = runTrackingCleanup(configuration)

        XCTAssertEqual(result.report.status, .error)
        XCTAssertEqual(result.roots.count, 1)
        XCTAssertTrue(result.report.reason.contains("injected setup failure"))
    }

    func testMissingExecutableReportsBothModesBlocked() throws {
        var configuration = SSHFixture.Configuration()
        configuration.sshd = URL(fileURLWithPath: "/definitely/missing/pinemeter-sshd")

        let report = SSHFixture.runPreflight(configuration: configuration)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        XCTAssertEqual(report.status, .blocked)
        XCTAssertEqual(report.attempts.map(\.mode), [.standalone, .proxyCommand])
        XCTAssertTrue(report.attempts.allSatisfy { $0.exitStatus == 127 })
        XCTAssertFalse(encoded.contains("pinemeter-preflight-input"))
    }

    func testAuthenticationTimeoutTerminatesOnlyFixtureProcessesAndCleansFiles() {
        var configuration = SSHFixture.Configuration()
        configuration.modes = [.standalone]
        configuration.fault = .authenticationTimeout

        let result = runTrackingCleanup(configuration)

        XCTAssertEqual(result.report.status, .blocked)
        XCTAssertEqual(result.report.attempts.first?.exitStatus, 124)
        XCTAssertTrue(result.report.reason.contains("authentication timeout"))
        XCTAssertFalse(result.processIDs.isEmpty)
    }

    func testEarlyServerExitIsBlockedAndCleansFiles() {
        var configuration = SSHFixture.Configuration()
        configuration.modes = [.standalone]
        configuration.fault = .earlyServerExit

        let result = runTrackingCleanup(configuration)

        XCTAssertEqual(result.report.status, .blocked)
        XCTAssertTrue(result.report.reason.contains("sshd exited before authentication"))
        XCTAssertFalse(result.processIDs.isEmpty)
    }

    func testPassRequiresAuthenticationAndBothNegativeControls() {
        let complete = attempt(authenticated: true, wrongPinRefused: true, wrongClientKeyRefused: true)
        let missingWrongPin = attempt(authenticated: true, wrongPinRefused: false, wrongClientKeyRefused: true)
        let missingWrongClient = attempt(authenticated: true, wrongPinRefused: true, wrongClientKeyRefused: false)
        let noAuthentication = attempt(authenticated: false, wrongPinRefused: true, wrongClientKeyRefused: true)

        XCTAssertEqual(SSHFixture.report(for: [complete]).status, .pass)
        XCTAssertEqual(SSHFixture.report(for: [missingWrongPin]).status, .error)
        XCTAssertEqual(SSHFixture.report(for: [missingWrongClient]).status, .error)
        XCTAssertEqual(SSHFixture.report(for: [noAuthentication]).status, .blocked)
    }

    func testBlockedPreflightMapsToExit77() throws {
        let run = try runScript(
            "--preflight",
            environment: ["PINEMETER_SSH_PREFLIGHT_SSHD": "/definitely/missing/pinemeter-sshd"]
        )

        XCTAssertEqual(run.status, 77, "script output:\n\(run.output)")
        XCTAssertTrue(run.output.contains("\"status\":\"BLOCKED\""), "script output:\n\(run.output)")
        XCTAssertFalse(run.output.contains("pinemeter-preflight-input"))
    }

    func testIntegrationModeReportsBlockedPreflight() throws {
        let run = try runScript(
            "--integration",
            environment: ["PINEMETER_SSH_PREFLIGHT_SSHD": "/definitely/missing/pinemeter-sshd"]
        )

        XCTAssertEqual(run.status, 77, "script output:\n\(run.output)")
        XCTAssertTrue(run.output.contains("\"status\":\"BLOCKED\""), "script output:\n\(run.output)")
        XCTAssertFalse(run.output.contains("unimplemented"))
    }

    private func runTrackingCleanup(_ input: SSHFixture.Configuration) -> (
        report: SSHFixture.Report,
        roots: [URL],
        processIDs: [pid_t]
    ) {
        var roots: [URL] = []
        var processIDs: [pid_t] = []
        var configuration = input
        configuration.onFixtureCreated = { roots.append($0) }
        configuration.onProcessStarted = { processIDs.append($0) }

        let report = SSHFixture.runPreflight(configuration: configuration)

        for root in roots {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "fixture root remained: \(root.lastPathComponent)")
        }
        for processID in processIDs {
            XCTAssertEqual(kill(processID, 0), -1, "fixture process \(processID) remained alive")
            XCTAssertEqual(errno, ESRCH)
        }
        return (report, roots, processIDs)
    }

    private func attempt(
        authenticated: Bool,
        wrongPinRefused: Bool,
        wrongClientKeyRefused: Bool
    ) -> SSHFixture.Attempt {
        SSHFixture.Attempt(
            mode: .standalone,
            command: "synthetic",
            exitStatus: authenticated ? 0 : 255,
            authenticated: authenticated,
            wrongPinRefused: wrongPinRefused,
            wrongClientKeyRefused: wrongClientKeyRefused,
            reason: "synthetic classification input"
        )
    }

    private func runScript(
        _ argument: String,
        environment additions: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = repository
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/test-mac-ssh-push.sh").path, argument]
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
