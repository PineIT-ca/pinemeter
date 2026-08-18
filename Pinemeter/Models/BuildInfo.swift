//
//  BuildInfo.swift
//  Pinemeter
//
//  Created by Edd on 2026-08-16.
//

import Foundation

/// Build identity shown in the About tab.
///
/// `CFBundleVersion` cannot serve as the human-facing build identifier: the
/// publisher derives it from the marketing version alone (`1.1.0-beta.3` is
/// always `1010003`), so it re-encodes the version rather than saying which
/// source produced the app. It stays in place because Sparkle publishes it as
/// `sparkle:version` and orders updates by it.
///
/// `PMSourceRevision` carries the private repository's short HEAD instead, and
/// is stamped by `publish/publish-public.sh` at archive time. Locally built
/// apps have no release revision, so they fall back to `CFBundleVersion` and
/// keep their existing `(1)` label.
enum BuildInfo {
    /// Value the project ships for `PM_SOURCE_REVISION` outside a release
    /// build. Treated as "no revision" rather than displayed.
    static let localRevisionPlaceholder = "dev"

    static func versionLabel(bundle: Bundle = .main) -> String? {
        versionLabel(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: bundle.infoDictionary?["CFBundleVersion"] as? String,
            sourceRevision: bundle.infoDictionary?["PMSourceRevision"] as? String
        )
    }

    static func versionLabel(
        shortVersion: String?,
        build: String?,
        sourceRevision: String?
    ) -> String? {
        guard let shortVersion = normalized(shortVersion) else { return nil }
        guard let detail = detail(build: build, sourceRevision: sourceRevision) else {
            return "Version \(shortVersion)"
        }
        return "Version \(shortVersion) (\(detail))"
    }

    private static func detail(build: String?, sourceRevision: String?) -> String? {
        if let revision = normalized(sourceRevision), revision != localRevisionPlaceholder {
            return revision
        }
        return normalized(build)
    }

    /// Rejects empty values and unsubstituted build settings. A missing
    /// `PM_SOURCE_REVISION` leaves the literal `$(PM_SOURCE_REVISION)` in the
    /// Info.plist, which must never reach the About tab.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(")
        else { return nil }
        return trimmed
    }
}
