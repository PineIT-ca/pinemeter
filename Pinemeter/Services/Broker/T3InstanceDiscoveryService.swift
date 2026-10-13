//
//  T3InstanceDiscoveryService.swift
//  Pinemeter
//
//  Discovers local T3 provider instances from `<t3Base>/caches/<instanceId>.json`
//  — one file per instance, written and periodically refreshed by the running
//  T3 desktop app (RESEARCH.md "Discovery Source Decision").
//
//  This is a hard trust boundary (T-pz4-01/02/03/07): every cache file is
//  untrusted JSON written by a separate Alpha-stage application. The decoded
//  DTO's `CodingKeys` deliberately omit the file's `auth` block entirely — the
//  value never enters process memory, which is stronger than decoding and
//  discarding it. This service reads only the caches directory: it never
//  opens the T3 user preferences file (a credential-bearing sibling under
//  T3's userdata directory, see RESEARCH.md "Rank 2"), never opens the T3
//  session database, and never calls the T3 HTTP API.
//
//  File-opening rules (review CR-01/W-01): the caches directory itself must
//  not be a symlink; each entry is opened with O_NOFOLLOW and then validated
//  on the open descriptor (fstat): regular file, link count 1 (a hard link
//  into the caches directory is refused), size within the cap. The read is
//  bounded at the read call itself, so a file that grows after the stat
//  (TOCTOU) cannot exceed the cap either. Symlinks, hard links, FIFOs, and
//  device files are all refused before any content is read.
//  See SecurityInvariantTests for the source-scan invariants that enforce
//  the path constraints.
//

import Foundation
import Darwin
import os

/// One provider instance as reported by a T3 cache file.
///
/// `CodingKeys` enumerate exactly these members and no others — the file's
/// `auth` block (and every other key) is never decoded, so it never enters
/// process memory. Do not widen this key set (T-pz4-02, Task 3 source scan).
struct DiscoveredT3Instance: Sendable, Equatable, Codable {
    var instanceId: String
    var driver: String
    var displayName: String?
    var installed: Bool
    var checkedAt: Date?
    var modelSlugs: [String]

    init(
        instanceId: String,
        driver: String,
        displayName: String? = nil,
        installed: Bool = false,
        checkedAt: Date? = nil,
        modelSlugs: [String] = []
    ) {
        self.instanceId = instanceId
        self.driver = driver
        self.displayName = displayName
        self.installed = installed
        self.checkedAt = checkedAt
        self.modelSlugs = modelSlugs
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId
        case driver
        case displayName
        case installed
        case checkedAt
        case models
    }

    /// The one field of each `models[]` entry this DTO reads. Every other
    /// field on a model entry (capabilities, option descriptors, …) is
    /// dropped by never being decoded.
    private struct ModelEntry: Codable {
        var slug: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // instanceId and driver are required: a file missing either decodes
        // to a thrown error, which the caller (T3InstanceDiscoveryService)
        // treats as "skip this file, keep scanning siblings."
        instanceId = try container.decode(String.self, forKey: .instanceId)
        driver = try container.decode(String.self, forKey: .driver)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false

        // `checkedAt` carries fractional seconds
        // ("2026-08-15T01:42:30.729Z"), which the app's standard
        // `.iso8601` JSONDecoder strategy rejects. Parse it as a plain
        // string and convert manually; an absent or unparseable value
        // yields `nil` rather than failing the whole file. The parsed value
        // is truncated to whole seconds so it survives SettingsRepository's
        // `.iso8601` save/load round trip byte-identically — otherwise the
        // first reconcile after every launch would see a phantom
        // sub-second `lastSeenAt` change and push a redundant policy
        // (review IN-09).
        let checkedAtString = try container.decodeIfPresent(String.self, forKey: .checkedAt)
        checkedAt = checkedAtString.flatMap(Self.parseCheckedAt)

        let modelEntries = try container.decodeIfPresent([ModelEntry].self, forKey: .models) ?? []
        modelSlugs = modelEntries.compactMap(\.slug)
    }

    /// Encoding exists only for the round-trip secrecy tests (prove the
    /// `auth` block can never survive decode→re-encode); nothing in the app
    /// persists this DTO (review I-08).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceId, forKey: .instanceId)
        try container.encode(driver, forKey: .driver)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(installed, forKey: .installed)
        if let checkedAt {
            try container.encode(Self.formatCheckedAt(checkedAt), forKey: .checkedAt)
        }
        try container.encode(modelSlugs.map { ModelEntry(slug: $0) }, forKey: .models)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseCheckedAt(_ raw: String) -> Date? {
        guard let parsed = fractionalFormatter.date(from: raw) ?? wholeSecondFormatter.date(from: raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: parsed.timeIntervalSince1970.rounded(.down))
    }

    private static func formatCheckedAt(_ date: Date) -> String {
        wholeSecondFormatter.string(from: date)
    }
}

/// Scans `<t3Base>/caches/*.json` for local T3 provider instances.
///
/// Never reads T3's user preferences file, its session database, or the T3
/// HTTP API — the caches directory is the sole discovery source (RESEARCH.md).
actor T3InstanceDiscoveryService: T3InstanceDiscoveryProtocol {
    private static let logger = Logger(subsystem: "com.pinemeter", category: "T3InstanceDiscoveryService")

    /// Directory scan is capped so an unbounded caches directory cannot be
    /// used to exhaust memory during a refresh tick (T-pz4-07).
    static let maxFileCount = 64
    /// Per-file size cap. Checked on the stat before any read, and enforced
    /// again by bounding the read itself (`FileHandle.read(upToCount:)`), so
    /// a file that grows between stat and read cannot exceed it (CR-01/IN-07).
    static let maxFileSizeBytes = 1_048_576
    /// `models[].slug` length cap (T-pz4-01). `instanceId`/`driver` use
    /// `T3InstanceConfig.isValidId`'s 64-character cap.
    static let maxSlugLength = 128
    /// `displayName` is rendered in Settings rows, menus, and accessibility
    /// labels, and persisted into `app_settings` — cap it at the boundary so
    /// a planted cache file cannot inject megabytes of text into the UI or
    /// UserDefaults (review WR-05).
    static let maxDisplayNameLength = 64
    /// A `checkedAt` further than this into the future is discarded: a
    /// forged future timestamp would otherwise pin the row's staleness badge
    /// at "Detected" indefinitely (review IN-04). Small positive skew
    /// tolerates clock drift between whatever wrote the file and this app.
    static let maxCheckedAtFutureSkew: TimeInterval = 300

    /// Controls directory enumeration only — per-file opens go through
    /// `open(2)`/`FileHandle` directly, so a `FileManager` double cannot
    /// influence what is read (review I-08). Tests point the service at a
    /// temp `cachesDirectoryURL` instead.
    private let fileManager: FileManager
    private let cachesDirectoryURL: URL

    /// - Parameters:
    ///   - fileManager: Injectable for tests.
    ///   - pointerFileURL: The T3 server pointer file, mirroring
    ///     `T3LivenessChecker`'s init exactly. Defaults to
    ///     `~/.t3/userdata/server-runtime.json`. The caches directory is
    ///     derived from it: `<base>/userdata/<file>` → `<base>/caches`
    ///     (ported from the reference dispatcher's base-dir rule).
    init(fileManager: FileManager = .default, pointerFileURL: URL? = nil) {
        self.fileManager = fileManager
        let pointer = pointerFileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3", isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
            .appendingPathComponent("server-runtime.json")
        self.cachesDirectoryURL = pointer
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("caches", isDirectory: true)
    }

    /// Test convenience: point discovery directly at a caches directory,
    /// bypassing pointer-file derivation entirely.
    init(fileManager: FileManager = .default, cachesDirectoryURL: URL) {
        self.fileManager = fileManager
        self.cachesDirectoryURL = cachesDirectoryURL
    }

    func scan() async -> [DiscoveredT3Instance]? {
        // Pin a real caches directory descriptor. `O_NOFOLLOW` rejects a
        // symlink at the directory boundary, and every file is opened
        // relative to this descriptor below, so a path swap after this point
        // can only make the scan miss data, never read outside the directory.
        let directoryFD: Int32 = cachesDirectoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { return nil }
        defer { Darwin.close(directoryFD) }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: cachesDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Missing/unreadable directory: "no information," not "empty."
            return nil
        }

        let jsonFiles = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maxFileCount)

        // Filename identity (`<instanceId>.json`) makes duplicate ids
        // structurally impossible within one directory; the seen-set is a
        // second, independent enforcement of the same invariant (WR-07) so
        // uniqueness does not hinge on filesystem semantics.
        var seenIds = Set<String>()
        var results: [DiscoveredT3Instance] = []
        for url in jsonFiles {
            guard let discovered = decodeInstance(named: url.lastPathComponent, directoryFD: directoryFD),
                  seenIds.insert(discovered.instanceId).inserted else { continue }
            results.append(discovered)
        }
        // Never log file contents — a count is the most this may reveal.
        Self.logger.info("T3 discovery scanned \(results.count, privacy: .public) instance(s)")
        return results
    }

    private func decodeInstance(named filename: String, directoryFD: Int32) -> DiscoveredT3Instance? {
        // Open first (refusing to traverse a symlink at the leaf), then
        // validate the *opened* descriptor with fstat, so the checks and the
        // read cannot be raced apart (review CR-01/W-01):
        // - regular file only (no FIFO/device/socket),
        // - link count 1: a hard link planted in the caches directory would
        //   be a regular file pointing at another file's inode (for example
        //   a credential file elsewhere in `~/.t3`), so any multiply-linked
        //   inode is refused outright,
        // - size within the cap.
        let descriptor = filename.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= Int64(Self.maxFileSizeBytes) else {
            return nil
        }
        // Read one byte beyond the limit. This rejects a file that grows
        // after fstat instead of accepting a truncated JSON prefix.
        guard let data = try? handle.read(upToCount: Self.maxFileSizeBytes + 1),
              data.count <= Self.maxFileSizeBytes else { return nil }
        guard var discovered = try? JSONDecoder().decode(DiscoveredT3Instance.self, from: data) else {
            return nil
        }
        guard T3InstanceConfig.isValidId(discovered.instanceId),
              T3InstanceConfig.isValidId(discovered.driver) else {
            return nil
        }
        // The file must be named `<instanceId>.json` (WR-07): a file cannot
        // claim another instance's id, and — because filenames are unique in
        // a directory — two files cannot claim the same id.
        guard filename == "\(discovered.instanceId).json" else {
            return nil
        }
        discovered.modelSlugs = discovered.modelSlugs.filter {
            T3InstanceConfig.isValidIdentifier($0, maxLength: Self.maxSlugLength)
        }
        discovered.displayName = Self.sanitizedDisplayName(discovered.displayName)
        if let checkedAt = discovered.checkedAt,
           checkedAt.timeIntervalSinceNow > Self.maxCheckedAtFutureSkew {
            discovered.checkedAt = nil
        }
        return discovered
    }

    /// Sanitizes an untrusted display name before the DTO leaves the service
    /// (WR-05): strips control characters, line/paragraph separators
    /// (U+2028/U+2029 are Zl/Zp, not control characters — review I-03), and
    /// default-ignorable code points (bidi overrides such as U+202E,
    /// zero-width joiners) that could make a planted instance render as a
    /// trusted one, then caps the length. An empty result becomes `nil`, so
    /// the row name falls back to the validated `instanceId`.
    static func sanitizedDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let filtered = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !scalar.properties.isDefaultIgnorableCodePoint
        }
        let trimmed = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxDisplayNameLength))
    }
}
