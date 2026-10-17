//
//  PresetManifestServiceProtocol.swift
//  Pinemeter
//

import Foundation

/// What a manifest fetch produced, distinguishing "nothing changed" from
/// "here is the new content" so the caller can skip a redundant settings
/// write and leave `lastCheckedAt`-only bookkeeping to the 304 case.
enum PresetManifestFetchOutcome: Equatable, Sendable {
    case notModified
    case updated(manifest: BrokerPresetManifest, etag: String?)
}

/// Fetches and validates the broker's remote preset manifest. A pure
/// fetch+validate boundary — persistence (storing the presets, the etag, the
/// checked-at time) stays in `AppModel`, the same split `ReleaseCheckService`
/// uses for release checks.
protocol PresetManifestServiceProtocol: Actor {
    /// Fetches `url`, sending `If-None-Match: etag` when one is known.
    /// Requires `https` and HTTP 200 (or 304); rejects a body over
    /// `BrokerPresetManifest.maxPayloadBytes`.
    func fetch(from url: URL, etag: String?) async throws -> PresetManifestFetchOutcome
}
