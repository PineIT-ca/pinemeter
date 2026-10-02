//
//  LocalCLIFiles.swift
//  Pinemeter
//
//  Shared, read-only local-file primitives for CLI login readers (D-02,
//  D-07): locating Codex CLI's auth file, and reading any local file under
//  the same safety checks `CodexCLIWorkspaceResolver` already applies, so the
//  resolver and `CodexCLILoginReader` can never disagree about where
//  `auth.json` lives or what counts as a safe file to read.
//

import Darwin
import Foundation

/// Locates `$CODEX_HOME/auth.json`, falling back to `~/.codex/auth.json`
/// (Codex CLI's own default). Shared by `CodexCLIWorkspaceResolver` and
/// `CodexCLILoginReader` so a change to the lookup rule can never make the
/// two types resolve different files.
enum CodexCLIAuthFileLocation {
    static func authFileURL(environment: [String: String]) -> URL? {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent(".codex").appendingPathComponent("auth.json")
    }
}

/// Reads a local file under the same safety checks as
/// `CodexCLIWorkspaceResolver.resolve()`, generalized to any caller that
/// needs to read a credential file whose path is derived from environment
/// variables (T-19-01): resolve symlinks, require a regular file, require
/// the file is owned by the current user, cap the size, and reject a file
/// that grew past the cap between the size check and the read. Strictly
/// read-only -- no write, create, or attribute-change call exists in this
/// type (D-07).
///
/// The regular-file, ownership, and size checks run against an already-open
/// file descriptor (`open` + `fstat`), not a separate `stat`-then-`open`
/// pair: a check-then-open race would let whatever sits at the resolved path
/// change between the check and the read (e.g. swapped for a FIFO that
/// blocks the open indefinitely, or a symlink planted after resolution).
/// `O_NOFOLLOW` rejects a symlink at the final path component, and
/// `O_NONBLOCK` keeps `open` from blocking forever if a FIFO is there
/// instead -- the `fstat` below then rejects it as not a regular file.
enum BoundedLocalFileReader {
    static func read(_ url: URL, maxBytes: Int, expectedOwnerId: uid_t = getuid()) -> Data? {
        let resolved = url.resolvingSymlinksInPath()

        let fd = resolved.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedOwnerId,
              info.st_size >= 0,
              info.st_size <= maxBytes else {
            return nil
        }

        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? fileHandle.read(upToCount: maxBytes + 1) else { return nil }
        // More than `maxBytes` bytes arrived: the file grew after the fstat
        // check above (a TOCTOU race), so reject it rather than silently
        // truncating or accepting a now-larger-than-intended file.
        guard data.count <= maxBytes else { return nil }
        return data
    }
}
