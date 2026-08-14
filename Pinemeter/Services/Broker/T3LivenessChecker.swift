//
//  T3LivenessChecker.swift
//  Pinemeter
//
//  Pointer-file discovery + reachability probe for the local T3 desktop app,
//  ported from the trixie-box reference's `checkT3Reachable`
//  (scripts/my-v2/t3-dispatch.mjs): ANY HTTP response — including 401 — proves
//  a server is listening. "No credential" is not "app not running", so a probe
//  never carries the T3 auth token; the reachability question does not need it.
//
//  Fails closed (D-03): a missing, unparseable, or origin-less pointer file
//  means unreachable with no HTTP request attempted at all.
//

import Foundation

actor T3LivenessChecker: T3LivenessCheckerProtocol {
    /// The endpoint probed to answer the reachability question. Any status
    /// code counts; only a connection failure/timeout means unreachable.
    static let probePath = "/api/orchestration/snapshot"

    /// The local server answers in single-digit ms when up (RESEARCH), so this
    /// budget is generous while still keeping `refresh` snappy.
    static let requestTimeoutInterval: TimeInterval = 0.75

    /// One HTTP probe: GET `origin + probePath`, injectable so tests can spy
    /// call counts and simulate any-status / connection-error / timeout without
    /// a real socket.
    typealias ProbeFunction = @Sendable (_ origin: String) async -> (status: Int?, errorText: String?)

    private let fileManager: FileManager
    private let pointerFileURL: URL
    private let probeFn: ProbeFunction

    /// - Parameters:
    ///   - fileManager: Injectable for tests.
    ///   - pointerFileURL: The T3 server pointer file. Defaults to
    ///     `~/.t3/userdata/server-runtime.json`. Injectable so tests use a temp file.
    ///   - probeFn: The HTTP probe. Defaults to a real `URLSession` GET with the
    ///     0.75s timeout; tests inject a stub to spy on call counts and simulate
    ///     any response/error without a real socket.
    init(
        fileManager: FileManager = .default,
        pointerFileURL: URL? = nil,
        probeFn: @escaping ProbeFunction = T3LivenessChecker.defaultProbe
    ) {
        self.fileManager = fileManager
        self.pointerFileURL = pointerFileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3", isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
            .appendingPathComponent("server-runtime.json")
        self.probeFn = probeFn
    }

    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] {
        let pointerOrigin = readPointerOrigin()

        var instancesByOrigin: [String: [String]] = [:]
        var result: [String: T3Liveness] = [:]

        for instance in instances {
            let origin = instance.baseURLOverride ?? pointerOrigin
            guard let origin, !origin.isEmpty else {
                // Fail closed, no HTTP attempted: no pointer file and no override.
                result[instance.id] = T3Liveness(reachable: false, why: "no server-runtime.json")
                continue
            }
            instancesByOrigin[origin, default: []].append(instance.id)
        }

        for (origin, instanceIds) in instancesByOrigin {
            let liveness = await probe(origin: origin)
            for id in instanceIds {
                result[id] = liveness
            }
        }

        return result
    }

    // MARK: - Pointer file

    private func readPointerOrigin() -> String? {
        guard let data = try? Data(contentsOf: pointerFileURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let origin = object["origin"] as? String, !origin.isEmpty else { return nil }
        return origin
    }

    // MARK: - Probe

    private func probe(origin: String) async -> T3Liveness {
        let (status, errorText) = await probeFn(origin)
        if let status {
            // Any HTTP response — including 401 — proves the server is
            // listening. Conflating "no credential" with "app not running"
            // would wrongly send callers to a fallback route.
            return T3Liveness(reachable: true, why: "http \(status)")
        }
        return T3Liveness(reachable: false, why: errorText ?? "connect failed")
    }

    /// Real HTTP probe: GET `origin + probePath` with the pinned 0.75s timeout.
    static let defaultProbe: ProbeFunction = { origin in
        guard let url = URL(string: origin + T3LivenessChecker.probePath) else {
            return (nil, "invalid origin")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.75
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
