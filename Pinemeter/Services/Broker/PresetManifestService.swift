//
//  PresetManifestService.swift
//  Pinemeter
//
//  Fetches the remote broker preset manifest. Pure fetch+validate: it talks
//  to the network, enforces the trust-boundary limits (https only, size cap,
//  timeout), and hands back a validated `BrokerPresetManifest` or a typed
//  reason it refused. Everything about WHEN to fetch and WHAT to do with the
//  result — the 6-hour throttle, storing presets/etag/lastCheckedAt, keeping
//  stale presets on failure — is `AppModel`'s job, matching how
//  `ReleaseCheckService` stays a dumb HTTP client and `AppModel` owns the
//  scheduling and persistence around it.
//

import Foundation

actor PresetManifestService: PresetManifestServiceProtocol {
    /// Reasons a fetch is refused before or after the network round-trip.
    enum FetchError: LocalizedError, Equatable {
        case insecureScheme
        case badStatus(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .insecureScheme:
                return "The manifest URL must use https."
            case .badStatus(let code):
                return "The manifest server returned status \(code)."
            case .tooLarge:
                return "The manifest is larger than Pinemeter will accept."
            }
        }
    }

    /// Request timeout. The manifest is small and fetched on a schedule, not
    /// on demand from a user action waiting on a spinner, so this stays short
    /// rather than inheriting `URLSession`'s much longer default.
    static let timeoutInterval: TimeInterval = 10

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(from url: URL, etag: String?) async throws -> PresetManifestFetchOutcome {
        // The manifest URL is user-editable (Broker settings), so this is a
        // trust-boundary check, not a convenience default: refuse anything
        // that is not https rather than silently sending credentials-free
        // plaintext or falling back to some other scheme.
        guard url.scheme?.lowercased() == "https" else {
            throw FetchError.insecureScheme
        }

        var request = URLRequest(url: url, timeoutInterval: Self.timeoutInterval)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pinemeter", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 304 {
            return .notModified
        }
        guard httpResponse.statusCode == 200 else {
            throw FetchError.badStatus(httpResponse.statusCode)
        }
        // Reject before reading a single byte when the server already
        // admits the body is too big -- no reason to open the tap at all.
        if httpResponse.expectedContentLength > 0,
           httpResponse.expectedContentLength > Int64(BrokerPresetManifest.maxPayloadBytes) {
            throw FetchError.tooLarge
        }

        // Streamed, not buffered: `session.data(for:)` hands back the whole
        // body before this cap is ever checked, so a hostile or misbehaving
        // server answering 200 with a huge (or infinite, chunked) body could
        // make this process buffer arbitrarily much data first and only then
        // get told no. Reading the response byte-by-byte and aborting the
        // moment the running count passes the cap means `data` here is
        // genuinely bounded -- this process never holds more than
        // `maxPayloadBytes + 1` bytes of an untrusted body, streamed or not.
        var data = Data()
        data.reserveCapacity(min(BrokerPresetManifest.maxPayloadBytes, 64 * 1024))
        for try await byte in byteStream {
            data.append(byte)
            guard data.count <= BrokerPresetManifest.maxPayloadBytes else {
                throw FetchError.tooLarge
            }
        }

        let manifest = try BrokerPresetManifest.decode(from: data)
        let newETag = httpResponse.value(forHTTPHeaderField: "Etag")
        return .updated(manifest: manifest, etag: newETag)
    }
}
