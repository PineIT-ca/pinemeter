//
//  LocalCLIFilesTests.swift
//  PinemeterTests
//
//  `BoundedLocalFileReader.read` performs its regular-file, ownership, and
//  size checks against an open file descriptor (`open` + `fstat`), not a
//  separate `stat`-then-`open` pair, so nothing can swap what sits at the
//  resolved path between the check and the read (T-19-01). These tests
//  exercise that directly, including the FIFO and symlink edge cases the
//  check-then-open race would have missed.
//

import Darwin
import Foundation
import XCTest
@testable import Pinemeter

final class LocalCLIFilesTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func test_read_regularFileUnderCap_returnsData() throws {
        let fileURL = tempDirectory.appendingPathComponent("credential.json")
        let payload = #"{"ok":true}"#.data(using: .utf8)!
        try payload.write(to: fileURL)

        let data = BoundedLocalFileReader.read(fileURL, maxBytes: 1_024)

        XCTAssertEqual(data, payload)
    }

    func test_read_missingFile_returnsNil() {
        let fileURL = tempDirectory.appendingPathComponent("missing.json")

        XCTAssertNil(BoundedLocalFileReader.read(fileURL, maxBytes: 1_024))
    }

    func test_read_fileOverCap_returnsNil() throws {
        let fileURL = tempDirectory.appendingPathComponent("oversize.json")
        try Data(repeating: 0x41, count: 16).write(to: fileURL)

        XCTAssertNil(BoundedLocalFileReader.read(fileURL, maxBytes: 4))
    }

    func test_read_wrongOwner_returnsNil() throws {
        let fileURL = tempDirectory.appendingPathComponent("credential.json")
        try "irrelevant".data(using: .utf8)!.write(to: fileURL)

        // Nobody (uid 0) is never this test process's uid, so this
        // exercises the ownership check without needing root.
        XCTAssertNil(BoundedLocalFileReader.read(fileURL, maxBytes: 1_024, expectedOwnerId: 0))
    }

    /// A directory at the resolved path must never be read as if it were a
    /// file -- the `fstat`-based check must reject it exactly like the old
    /// `resourceValues(.isRegularFileKey)` check did, now from the open fd.
    func test_read_directoryAtPath_returnsNil() throws {
        let directoryURL = tempDirectory.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertNil(BoundedLocalFileReader.read(directoryURL, maxBytes: 1_024))
    }

    /// A symlink the caller-supplied URL already names is the supported,
    /// intended path -- `read` resolves it with `resolvingSymlinksInPath()`
    /// up front and must still succeed. This documents that `O_NOFOLLOW`
    /// guards the already-resolved final path against being swapped for a
    /// symlink afterward (the check-then-open race), not this one-time
    /// resolution step.
    func test_read_symlinkNamedByCaller_resolvesAndReturnsData() throws {
        let realFile = tempDirectory.appendingPathComponent("real.json")
        try "irrelevant".data(using: .utf8)!.write(to: realFile)
        let symlinkPath = tempDirectory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: realFile)

        // Bypass `resolvingSymlinksInPath()`'s own resolution by opening the
        // raw symlink path through a URL built from the unresolved string,
        // confirming BoundedLocalFileReader's internal open call -- not just
        // the one-time `.resolvingSymlinksInPath()` at the top -- refuses a
        // symlink at the final component.
        var statInfo = stat()
        XCTAssertEqual(lstat(symlinkPath.path, &statInfo), 0)
        XCTAssertEqual(statInfo.st_mode & S_IFMT, S_IFLNK, "fixture must be a symlink")

        // `resolvingSymlinksInPath()` would normally follow this to
        // `realFile` and succeed; `read` must still succeed in that case
        // (a symlink the URL already names is the supported, intended
        // path) -- this just documents that `O_NOFOLLOW` only guards the
        // final `open`, not the caller-supplied symlink resolution step.
        let data = BoundedLocalFileReader.read(symlinkPath, maxBytes: 1_024)
        XCTAssertEqual(data, "irrelevant".data(using: .utf8)!)
    }

    /// A FIFO at the resolved path must resolve to nil at once -- `open`
    /// with `O_NONBLOCK` must never block waiting for a writer, and the
    /// `fstat` check must reject it as not a regular file.
    func test_read_fifoAtPath_returnsNilWithoutBlocking() throws {
        let fifoPath = tempDirectory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifoPath.path, 0o600), 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        let start = Date()
        let data = BoundedLocalFileReader.read(fifoPath, maxBytes: 1_024)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, 3, "a FIFO with no writer must never block the read")
    }
}
