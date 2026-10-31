import Foundation
import os

protocol LocalModelLoadServiceProtocol: Sendable {
    func configure(routes: [BrokerLocalRoute]) async
    func start(publish: @escaping @Sendable (BrokerLocalLoad) async -> Void) async
    func stop() async
    func requestCycle() async
}

struct LocalProbeResponse: Sendable {
    let status: Int
    let body: Data
}

struct LocalProbeLog: Equatable, Sendable {
    let host: String
    let statusClass: Int
    let durationMilliseconds: Int
    let state: String
}

/// The only local-host network reader. Picks consume its immutable snapshots.
actor LocalModelLoadService: LocalModelLoadServiceProtocol {
    typealias Transport = @Sendable (URLRequest) async throws -> LocalProbeResponse
    typealias Publisher = @Sendable (BrokerLocalLoad) async -> Void
    static let modelsCap = 262144
    static let slotsCap = 65536
    enum ProbeError: Error { case invalidResponse, tooLarge }
    private static let logger = Logger(subsystem: "com.pinemeter", category: "LocalModelLoad")

    private let transport: Transport
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let log: @Sendable (LocalProbeLog) -> Void
    private var routes: [BrokerLocalRoute] = []
    private var publish: Publisher?
    private var generation = 0
    private var loops: [String: Task<Void, Never>] = [:]
    private var cycles: [String: Task<Void, Never>] = [:]
    private var snapshots: [String: BrokerLocalLoad.Host] = [:]
    private var failures: [String: Int] = [:]

    init(transport: @escaping Transport = LocalModelLoadService.defaultTransport,
         clock: @escaping @Sendable () -> Date = { Date() },
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: -3...3) },
         log: @escaping @Sendable (LocalProbeLog) -> Void = { entry in
             logger.info("host=\(entry.host, privacy: .public) status_class=\(entry.statusClass) duration_ms=\(entry.durationMilliseconds) state=\(entry.state, privacy: .public)")
         }) {
        self.transport = transport
        self.clock = clock
        self.sleeper = sleeper
        self.jitter = jitter
        self.log = log
    }

    func configure(routes: [BrokerLocalRoute]) async {
        let routes = BrokerLocalRoute.normalized(routes).filter(\.enabled)
        guard self.routes != routes else { return }
        cancelTasks()
        self.routes = routes
        snapshots = [:]
        failures = [:]
        if let publish {
            let epoch = generation
            await publish(BrokerLocalLoad(hosts: []))
            guard epoch == generation, self.publish != nil else { return }
            launchLoops()
        }
    }

    func start(publish: @escaping Publisher) {
        self.publish = publish
        if loops.isEmpty { launchLoops() }
    }

    func stop() async {
        cancelTasks()
        snapshots = [:]
        failures = [:]
        let previous = publish
        publish = nil
        await previous?(BrokerLocalLoad(hosts: []))
    }

    private func cancelTasks() {
        generation += 1
        for task in loops.values { task.cancel() }
        for task in cycles.values { task.cancel() }
        loops = [:]
        cycles = [:]
    }

    private func launchLoops() {
        let epoch = generation
        for host in Set(routes.map(\.host)) {
            loops[host] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.runCycle(host: host, epoch: epoch)
                    guard !Task.isCancelled else { return }
                    let delay = await self.delay(host: host)
                    do { try await self.sleeper(.seconds(delay)) } catch { return }
                }
            }
        }
    }

    func requestCycle() {
        guard publish != nil else { return }
        for host in Set(routes.map(\.host)) { enqueueCycle(host: host, epoch: generation) }
    }

    private func enqueueCycle(host: String, epoch: Int) {
        guard cycles[host] == nil, epoch == generation else { return }
        cycles[host] = Task { [weak self] in await self?.probe(host: host, epoch: epoch) }
    }

    private func runCycle(host: String, epoch: Int) async {
        enqueueCycle(host: host, epoch: epoch)
        await cycles[host]?.value
    }

    private func delay(host: String) -> Double {
        let count = failures[host, default: 0]
        return count == 0 ? 15 + min(3, max(-3, jitter())) : min(300, 15 * pow(2, Double(min(5, count))))
    }

    private func probe(host: String, epoch: Int) async {
        guard epoch == generation, let route = routes.first(where: { $0.host == host }) else { return }
        let began = clock()
        var result = BrokerLocalLoad.Host(host: host, state: "ok", observedAt: began, presets: [:], pending: 0)
        var statusClass = 0
        do {
            let response = try await transport(Self.request(route.probeURL, path: "models"))
            statusClass = response.status / 100
            try Self.check(response, cap: Self.modelsCap)
            let models = try JSONDecoder().decode(Models.self, from: response.body).data
            guard models.count <= 64, Set(models.map(\.id)).count == models.count,
                  models.allSatisfy({ Self.validID($0.id) && $0.aliases.count <= 8 && $0.aliases.allSatisfy(Self.validID) }),
                  models.filter({ $0.status.value == "loaded" }).count <= 4 else { throw ProbeError.invalidResponse }
            for model in models {
                let status: String
                switch model.status.value {
                case "loaded", "loading", "sleeping": status = model.status.value
                case "unloaded": status = model.status.failed ? "failed" : "unloaded"
                default: status = "loading"
                }
                var preset = BrokerLocalLoad.Preset(status: status, aliases: model.aliases, slotsTotal: 0, slotsBusy: 0)
                if status == "loaded" {
                    // autoload=false prevents an unload race from triggering a new load.
                    let response = try await transport(Self.request(route.probeURL, path: "slots", model: model.id))
                    statusClass = response.status / 100
                    try Self.check(response, cap: Self.slotsCap)
                    let slots = try JSONDecoder().decode([Slot].self, from: response.body)
                    guard slots.count <= 64 else { throw ProbeError.invalidResponse }
                    preset.slotsTotal = slots.count
                    preset.slotsBusy = slots.filter(\.isProcessing).count
                }
                result.presets[model.id] = preset
            }
            for declared in routes where declared.host == host {
                if !models.contains(where: { $0.id == declared.preset || $0.aliases.contains(declared.preset) }) {
                    result.presets[declared.preset] = .init(status: "failed", aliases: [], slotsTotal: 0, slotsBusy: 0)
                }
            }
        } catch {
            let code = (error as? URLError)?.code
            result.state = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost, .notConnectedToInternet].contains(code) ? "unreachable" : "error"
            result.presets = [:]
        }
        guard epoch == generation, !Task.isCancelled else { return }
        failures[host] = result.state == "ok" ? 0 : min(5, failures[host, default: 0] + 1)
        snapshots[host] = result
        log(.init(host: host, statusClass: statusClass, durationMilliseconds: Int(max(0, clock().timeIntervalSince(began) * 1000)), state: result.state))
        await publish?(BrokerLocalLoad(hosts: snapshots.keys.sorted().compactMap { snapshots[$0] }))
        if epoch == generation { cycles[host] = nil }
    }

    private static func validID(_ id: String) -> Bool {
        (1...128).contains(id.unicodeScalars.count) && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func check(_ response: LocalProbeResponse, cap: Int) throws {
        guard (200..<300).contains(response.status) else { throw ProbeError.invalidResponse }
        guard response.body.count <= cap else { throw ProbeError.tooLarge }
    }
    private static func request(_ origin: String, path: String, model: String? = nil) -> URLRequest {
        var url = URLComponents(string: origin)!
        url.path = "/" + path
        if let model { url.queryItems = [.init(name: "model", value: model), .init(name: "autoload", value: "false")] }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        return request
    }

    static let defaultTransport: Transport = { request in
        let session = URLSession(configuration: sessionConfiguration())
        defer { session.invalidateAndCancel() }
        return try await boundedResponse(request, session: session)
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return configuration
    }

    static func boundedResponse(_ request: URLRequest, session: URLSession) async throws -> LocalProbeResponse {
        let cap = request.url?.path == "/slots" ? slotsCap : modelsCap
        let (bytes, response) = try await session.bytes(for: request, delegate: LocalProbeRedirectDelegate())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.url == request.url, (200..<300).contains(response.statusCode) else {
            // Preserve the status class without ever returning a response body.
            return .init(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: Data())
        }
        guard response.expectedContentLength <= Int64(cap) else { throw ProbeError.tooLarge }
        var body = Data()
        for try await byte in bytes {
            guard body.count < cap else { throw ProbeError.tooLarge }
            body.append(byte)
        }
        return .init(status: response.statusCode, body: body)
    }

    private struct Models: Decodable { let data: [Model] }
    private struct Model: Decodable {
        let id: String
        let aliases: [String]
        let status: Status
        enum CodingKeys: String, CodingKey { case id, aliases, status }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
            status = try c.decode(Status.self, forKey: .status)
        }
    }
    private struct Status: Decodable {
        let value: String
        let failed: Bool
        enum CodingKeys: String, CodingKey { case value, failed }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decode(String.self, forKey: .value)
            failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        }
    }
    private struct Slot: Decodable {
        let id: Int
        let isProcessing: Bool
        let context: Int
        enum CodingKeys: String, CodingKey { case id; case isProcessing = "is_processing"; case context = "n_ctx" }
    }
}

private final class LocalProbeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
