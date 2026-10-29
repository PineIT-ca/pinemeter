import CryptoKit
import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class AppModelModelHealthTests: XCTestCase {
    func test_healthDocumentPolicyKeysCannotChangeLocalDeclarations() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try HealthTestSupport.body("policy-keys-ignored")
        let session = HealthTestSupport.session(body: body)
        defer { session.invalidateAndCancel() }
        let app = HealthTestSupport.app(directory: directory, session: session,
            store: BrokerHealthStore(storeDirectory: directory), broker: HealthTestSupport.broker(directory: directory),
            keys: try HealthTestSupport.keys())
        var route = try XCTUnwrap(try BrokerLocalRoutePolicyTests.declaredPolicy().localRoutes.first)
        // Distinct declarations make accidental adoption of the signed keys visible.
        route.candidate = "t3:pi/lab/model-b"
        route.host = "gpu-b"
        route.probeURL = "http://gpu-b.example:11434"
        app.settings.broker.policy.localRoutes = [route]
        app.settings.broker.policy.residencyRoles = ["verification": .controlled]
        let original = app.settings.broker.policy

        await app.refreshModelHealth(force: true)

        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        XCTAssertEqual(app.modelHealthState.line, body)
        XCTAssertEqual(app.modelHealthState.lastCheck?.result, "accepted")
        XCTAssertEqual(app.settings.broker.policy.localRoutes, original.localRoutes)
        XCTAssertEqual(app.settings.broker.policy.residencyRoles, original.residencyRoles)
        app.settings.broker.policy.localRoutes = []
        app.settings.broker.policy.residencyRoles = [:]
        await app.refreshModelHealth(force: true)
        XCTAssertTrue(app.settings.broker.policy.localRoutes.isEmpty)
        XCTAssertTrue(app.settings.broker.policy.residencyRoles.isEmpty)
    }

    func test_officialDocumentPersistsDemotesPickAndAppearsInStatus() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try HealthTestSupport.body("valid-two-demotions")
        let session = HealthTestSupport.session(body: body, headers: ["ETag": "v10"])
        defer { session.invalidateAndCancel() }
        let store = BrokerHealthStore(storeDirectory: directory)
        let broker = HealthTestSupport.broker(directory: directory)
        let app = HealthTestSupport.app(directory: directory, session: session, store: store, broker: broker, keys: try HealthTestSupport.keys())

        await app.refreshModelHealth(force: true)

        XCTAssertEqual(app.modelHealthState.line, body)
        XCTAssertEqual(app.modelHealthState.etag, "v10")
        let decision = try await broker.pick(role: "review", caller: nil)
        XCTAssertEqual(decision.model, "native/model-gamma")
        XCTAssertEqual(decision.pickBasis, .drift)
        let status = await broker.status()
        XCTAssertEqual(status.health?.present, true)
        XCTAssertEqual(status.health?.seq, 10)
        XCTAssertEqual(status.health?.sources.count, 2)
        let restarted = BrokerHealthStore(storeDirectory: directory)
        let loaded = await restarted.load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
        XCTAssertEqual(loaded, app.modelHealthState)
    }

    func test_emptyStoreSetsAbsentHealthAndKeepsPick() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = HealthTestSupport.broker(directory: directory)
        let initial = await broker.status()
        XCTAssertNil(initial.health)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(initial.jsonString().utf8)) as? [String: Any])
        XCTAssertNil(json["health"])
        let state = await BrokerHealthStore(storeDirectory: directory).load(now: HealthTestSupport.now)
        await broker.setModelHealth(state)
        let status = await broker.status()
        XCTAssertEqual(status.health?.present, false)
        let decision = try await broker.pick(role: "review", caller: nil)
        XCTAssertEqual(decision.model, "native/model-alpha")
        XCTAssertEqual(decision.pickBasis, .quality)
    }

    func test_304FailureRejectionStaleCopyAndEqualSequenceKeepLastGood() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try HealthTestSupport.body("valid-two-demotions")
        let session = HealthTestSupport.session(body: body, headers: ["ETag": "v10"])
        defer { session.invalidateAndCancel() }
        let store = BrokerHealthStore(storeDirectory: directory)
        let broker = HealthTestSupport.broker(directory: directory)
        let app = HealthTestSupport.app(directory: directory, session: session, store: store, broker: broker, keys: try HealthTestSupport.keys())
        await app.refreshModelHealth(force: true)
        let snapshot = app.modelHealthState.snapshot(now: HealthTestSupport.now)
        let cases: [(Int, Data, [String: String], String)] = [
            (304, Data(), [:], "unchanged"),
            (500, Data(), [:], "fetch_failed"),
            (200, Data(repeating: 32, count: 32769), [:], "too_large"),
            (200, Data(), ["Content-Length": "32769"], "too_large"),
            (200, try HealthTestSupport.body("tampered-signature"), ["ETag": "bad"], "signature"),
            (200, try HealthTestSupport.body("lower-seq"), ["ETag": "old"], "stale_copy"),
            (200, body, ["ETag": "v10"], "unchanged")
        ]
        for (status, responseBody, headers, result) in cases {
            HealthStubURLProtocol.configure { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "v10")
                return .init(status: status, body: responseBody, headers: headers)
            }
            await app.refreshModelHealth(force: true)
            XCTAssertEqual(app.modelHealthState.lastCheck?.result, result)
            XCTAssertEqual(app.modelHealthState.line, body)
            XCTAssertEqual(app.modelHealthState.etag, "v10")
            XCTAssertEqual(app.modelHealthState.snapshot(now: HealthTestSupport.now), snapshot)
            let status = await broker.status()
            XCTAssertEqual(status.health?.lastCheck?.result, result)
            let disk = await BrokerHealthStore(storeDirectory: directory).load(keys: try HealthTestSupport.keys(), now: HealthTestSupport.now)
            XCTAssertEqual(disk, app.modelHealthState)
        }
    }

    func test_forcedRefreshStillHonorsBrokerAndPolicySwitches() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = HealthTestSupport.session(body: try HealthTestSupport.body("valid-two-demotions"))
        defer { session.invalidateAndCancel() }
        let broker = HealthTestSupport.broker(directory: directory)
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory), broker: broker,
                                        keys: try HealthTestSupport.keys())
        app.settings.broker.isEnabled = false
        await app.refreshModelHealth(force: true)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 0)
        app.settings.broker.isEnabled = true
        app.settings.broker.policy.thresholds.useModelHealth = false
        await app.refreshModelHealth(force: true)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 0)
        app.settings.broker.policy.thresholds.useModelHealth = true
        app.settings.broker.presetManifest.isEnabled = false
        await app.refreshModelHealth(force: true)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        app.settings.broker.policy.thresholds.useModelHealth = false
        await broker.updatePolicy(app.settings.broker.policy)
        await app.refreshModelHealth(force: true)
        let status = await broker.status()
        XCTAssertEqual(status.health?.useModelHealth, false)
        XCTAssertEqual(status.health?.sources.count, 2)
        XCTAssertEqual(app.modelHealthState.payload?.seq, 10)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
    }

    func test_bootstrapAndSixHourClockFetchIndependentOfPresets() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = HealthTestSupport.session(body: try HealthTestSupport.body("valid-two-demotions"))
        defer { session.invalidateAndCancel() }
        let clock = HealthMutableDate(HealthTestSupport.now)
        let sleep = HealthTestSleep()
        let repository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.presetManifest.isEnabled = false
        try await repository.save(settings)
        let broker = HealthTestSupport.broker(directory: directory, now: { clock.now })
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory), broker: broker,
            keys: try HealthTestSupport.keys(), now: { clock.now }, settingsRepository: repository,
            sleep: { try await sleep.sleep($0) })

        await app.bootstrap()
        await sleep.waitForSleep(1)
        for _ in 0..<1000 {
            if app.modelHealthState.lastCheck != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(app.modelHealthState.lastCheck?.result, "accepted")
        await app.refreshModelHealth()
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        clock.advance(6 * 3600 - 1)
        await app.refreshModelHealth()
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        clock.advance(1)
        await sleep.wake()
        await sleep.waitForSleep(2)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 2)
        let intervals = await sleep.intervals
        XCTAssertEqual(intervals, [.seconds(21600), .seconds(21600)])
        app.settings.broker.isEnabled = false
        clock.advance(6 * 3600)
        await sleep.wake()
        await sleep.waitForSleep(3)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 2)
        app.settings.broker.isEnabled = true
        app.settings.broker.policy.thresholds.useModelHealth = false
        clock.advance(6 * 3600)
        await sleep.wake()
        await sleep.waitForSleep(4)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 2)
        await sleep.stop()
    }

    func test_bootstrapLoadsLastGoodBeforeFetchFailure() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerHealthStore(storeDirectory: directory)
        let keys = try HealthTestSupport.keys()
        _ = await store.load(keys: keys, now: HealthTestSupport.now)
        let acceptance = BrokerHealthDocument.accept(body: try HealthTestSupport.body("valid-two-demotions"), stored: nil, keys: keys, now: HealthTestSupport.now)
        _ = try await store.record(acceptance: acceptance, etag: "v10", checkedAt: HealthTestSupport.now)
        let session = HealthTestSupport.session(status: 500)
        defer { session.invalidateAndCancel() }
        let broker = HealthTestSupport.broker(directory: directory)
        let repository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        try await repository.save(settings)
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory), broker: broker,
                                        keys: keys, settingsRepository: repository)
        await app.bootstrap()
        let status = await broker.status()
        XCTAssertEqual(status.health?.seq, 10)
        await app.refreshModelHealth(force: true)
        XCTAssertEqual(app.modelHealthState.payload?.seq, 10)
        XCTAssertEqual(app.modelHealthState.lastCheck?.result, "fetch_failed")
    }

    func test_sixHourTickDoesNotSkipAfterSlowBootstrapFetch() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try HealthTestSupport.body("valid-two-demotions")
        let session = HealthTestSupport.session(body: body)
        defer { session.invalidateAndCancel() }
        let firstRequest = expectation(description: "bootstrap request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal() }
        HealthStubURLProtocol.configure { _ in
            if HealthStubURLProtocol.requests.count == 1 {
                firstRequest.fulfill()
                releaseResponse.wait()
            }
            return .init(body: body)
        }
        let clock = HealthMutableDate(HealthTestSupport.now)
        let sleep = HealthTestSleep()
        let repository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.presetManifest.isEnabled = false
        try await repository.save(settings)
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory),
            broker: HealthTestSupport.broker(directory: directory, now: { clock.now }), keys: try HealthTestSupport.keys(),
            now: { clock.now }, settingsRepository: repository, sleep: { try await sleep.sleep($0) })
        await app.bootstrap()
        await sleep.waitForSleep(1)
        await fulfillment(of: [firstRequest], timeout: 2)
        clock.advance(30)
        releaseResponse.signal()
        for _ in 0..<1000 {
            if app.modelHealthState.lastCheck != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(app.modelHealthState.lastCheck?.at, HealthTestSupport.now.addingTimeInterval(30))
        clock.advance(21600 - 30)
        await sleep.wake()
        await sleep.waitForSleep(2)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 2, "scheduled six-hour tick must not wait another six hours")
        await sleep.stop()
    }

    func test_overlappingRefreshesCoalesceWithoutLosingDocument() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try HealthTestSupport.body("valid-two-demotions")
        let session = HealthTestSupport.session(body: body)
        defer { session.invalidateAndCancel() }
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory),
            broker: HealthTestSupport.broker(directory: directory), keys: try HealthTestSupport.keys())
        async let first: Void = app.refreshModelHealth(force: true)
        async let second: Void = app.refreshModelHealth(force: true)
        _ = await (first, second)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        XCTAssertEqual(app.modelHealthState.line, body)
    }

    func test_customPresetManifestHealthChangesNeitherStoredHealthNorPick() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = HealthTestSupport.session(body: try HealthTestSupport.body("valid-two-demotions"))
        defer { session.invalidateAndCancel() }
        let broker = HealthTestSupport.broker(directory: directory)
        let app = HealthTestSupport.app(directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory),
            broker: broker, keys: try HealthTestSupport.keys(), presetService: PresetManifestService(session: session))
        await app.refreshModelHealth(force: true)
        let original = app.modelHealthState
        let before = try await broker.pick(role: "review", caller: nil)
        let customURL = "https://example.invalid/custom-presets.json"
        app.settings.broker.presetManifest.sources = [.init(urlString: customURL)]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Pinemeter/Resources/broker-presets.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        // Even a valid higher-sequence envelope belongs exclusively to the official health channel.
        manifest["health"] = ["document": String(decoding: try HealthTestSupport.body("higher-seq"), as: UTF8.self)]
        let body = try JSONSerialization.data(withJSONObject: manifest)
        HealthStubURLProtocol.configure { request in
            XCTAssertEqual(request.url?.absoluteString, customURL)
            return .init(body: body)
        }

        await app.refreshPresetManifest(force: true)

        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
        XCTAssertGreaterThan(app.settings.broker.presetManifest.sources[0].cachedPresets.count, 0)
        XCTAssertNil(app.settings.broker.presetManifest.sources[0].lastError)
        XCTAssertEqual(app.modelHealthState, original)
        let after = try await broker.pick(role: "review", caller: nil)
        XCTAssertEqual(after.model, before.model)
        XCTAssertEqual(after.pickBasis, before.pickBasis)
        XCTAssertEqual(after.reason, before.reason)
        XCTAssertEqual(after.backups, before.backups)
        let status = await broker.status()
        XCTAssertEqual(status.health?.seq, 10)
        XCTAssertEqual(status.health?.lastCheck?.result, "accepted")
    }
}

enum HealthTestSupport {
    static let now = BrokerHealthDocument.parseTime("2026-10-13T12:00:00Z")!
    static var corpus: URL { GoldenFixture.goldenDirectory.appendingPathComponent("health") }

    static func body(_ name: String) throws -> Data {
        try Data(contentsOf: corpus.appendingPathComponent(name + ".signed"))
    }

    static func keys() throws -> [String: Curve25519.Signing.PublicKey] {
        let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: corpus.appendingPathComponent("keys.json")))
        return try encoded.mapValues {
            try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: $0)))
        }
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ModelHealthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func session(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) -> URLSession {
        HealthStubURLProtocol.configure { request in
            .init(status: status, body: body, headers: headers)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func broker(directory: URL, now: @escaping @Sendable () -> Date = { HealthTestSupport.now }) -> BrokerService {
        BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: HealthTestLiveness(),
            now: now
        )
    }

    static var policy: BrokerPolicy {
        BrokerFixture.policy(roles: ["review": ["native/model-alpha", "native/model-beta", "native/model-gamma"]])
    }

    @MainActor
    static func app(
        directory: URL, session: URLSession, store: BrokerHealthStore, broker: BrokerService,
        keys: [String: Curve25519.Signing.PublicKey],
        now: @escaping @Sendable () -> Date = { HealthTestSupport.now },
        settingsRepository: any SettingsRepositoryProtocol = SettingsRepositoryFake(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        presetService: (any PresetManifestServiceProtocol)? = nil
    ) -> AppModel {
        let app = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(URLError(.notConnectedToInternet))),
            chatGPTSessionRepository: HealthTestSessions(),
            geminiAPIKeyRepository: HealthTestGemini(),
            notificationService: NotificationServiceSpy(),
            presetManifestService: presetService,
            presetManifestHistoryStore: BrokerManifestHistoryStore(storeDirectory: directory),
            healthDocumentService: HealthDocumentService(session: session),
            brokerHealthStore: store, modelHealthKeys: keys, modelHealthNow: now, modelHealthRefreshSleep: sleep,
            brokerService: broker, brokerServerFactory: { _, _, _ in HealthTestServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )
        app.settings.broker.isEnabled = true
        app.settings.broker.policy = policy
        return app
    }
}

/// Every test request terminates here, including unexpected hosts.
final class HealthStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var redirect: URL? = nil
    }
    private static let lock = NSLock()
    private static var handler: (@Sendable (URLRequest) throws -> Reply)?
    private static var received: [URLRequest] = []

    static func configure(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.withLock { self.handler = handler; received = [] }
    }
    static var requests: [URLRequest] { lock.withLock { received } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.received.append(request); return Self.handler }
            let reply = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            if let redirect = reply.redirect {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private actor HealthTestServer: BrokerLoopbackServerProtocol {
    func start() -> UInt16 { 0 }
    func stop() {}
}

private actor HealthTestLiveness: T3LivenessCheckerProtocol {
    func checkLiveness(instances: [T3InstanceConfig]) -> [String: T3Liveness] { [:] }
}

private actor HealthTestSessions: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus { .init(state: .missing, lastErrorCategory: .notFound) }
    func clear(account: String) {}
}

private actor HealthTestGemini: GeminiAPIKeyRepositoryProtocol {
    func save(_ key: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus { .init(state: .missing, lastErrorCategory: .notFound) }
    func clear(account: String) {}
}

final class HealthMutableDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor HealthTestSleep {
    private(set) var intervals: [Duration] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopped = false

    func sleep(_ duration: Duration) async throws {
        guard !stopped else { throw CancellationError() }
        intervals.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let ready = waiters.filter { $0.0 <= intervals.count }
            waiters.removeAll { $0.0 <= intervals.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForSleep(_ count: Int) async {
        guard intervals.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func wake() { continuation?.resume(); continuation = nil }
    func stop() { stopped = true; continuation?.resume(throwing: CancellationError()); continuation = nil }
}
