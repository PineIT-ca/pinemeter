import Foundation
import XCTest
@testable import Pinemeter

final class LocalModelLoadServiceTests: XCTestCase {
    static let loaded = Data(#"{"data":[{"id":"qwen-27b","aliases":[],"status":{"value":"loaded"}}]}"#.utf8)
    static let idle = Data(#"[{"id":0,"is_processing":false,"n_ctx":8192}]"#.utf8)

    func test_oneCyclePublishesLoadedIdleSnapshotInRequestOrder() async throws {
        let capture = LocalProbeCapture()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            return .init(status: 200, body: request.url?.path == "/models" ? Self.loaded : Self.idle)
        }, clock: { BrokerFixture.now }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 0 })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { await capture.publish($0) }
        let load = try await capture.waitForLoad()
        let requests = await capture.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/models", "/slots"])
        XCTAssertEqual(requests.last?.url?.query, "model=qwen-27b&autoload=false")
        XCTAssertEqual(load.hosts.first?.state, "ok")
        XCTAssertEqual(load.hosts.first?.presets["qwen-27b"]?.slotsTotal, 1)
        XCTAssertEqual(load.hosts.first?.presets["qwen-27b"]?.slotsBusy, 0)
        await service.stop()
    }

    func test_disabledHostIsNeverContactedAndReconfigurationClearsSnapshot() async throws {
        let capture = LocalProbeCapture()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            return .init(status: 200, body: Self.loaded)
        }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        var disabled = BrokerLocalRouteTests.route(); disabled.enabled = false
        await service.configure(routes: [disabled])
        await service.start { await capture.publish($0) }
        await service.requestCycle()
        try await Task.sleep(for: .milliseconds(10))
        let initialRequests = await capture.requests
        XCTAssertTrue(initialRequests.isEmpty)
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        _ = try await capture.waitForLoad(count: 2)
        await service.configure(routes: [disabled])
        let last = await capture.loads.last
        XCTAssertEqual(last?.hosts, [])
        let count = await capture.requests.count
        await service.requestCycle()
        try await Task.sleep(for: .milliseconds(10))
        let finalCount = await capture.requests.count
        XCTAssertEqual(finalCount, count)
        await service.stop()
    }

    func test_failureBackoffCapsAt300AndSuccessResetsWithJitter() async throws {
        let capture = LocalProbeCapture()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            if await capture.requests.count < 8 { throw URLError(.timedOut) }
            return .init(status: 200, body: Data(#"{"data":[]}"#.utf8))
        }, sleeper: { duration in
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let count = await capture.recordDelay(seconds)
            if count >= 8 { try await Task.sleep(for: .seconds(3600)) }
        }, jitter: { 3 })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { await capture.publish($0) }
        for _ in 0..<1000 {
            if await capture.delays.count >= 8 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let delays = await capture.delays
        XCTAssertEqual(delays, [30, 60, 120, 240, 300, 300, 300, 18])
        await service.stop()
    }

    func test_logSinkReceivesOnlyAllowedFields() async throws {
        let logs = ProbeLogCapture()
        let capture = LocalProbeCapture()
        let service = LocalModelLoadService(transport: { _ in
            .init(status: 503, body: Data("response-only".utf8))
        }, clock: { BrokerFixture.now }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
        log: { logs.append($0) })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { await capture.publish($0) }
        _ = try await capture.waitForLoad()
        XCTAssertEqual(logs.entries, [.init(host: "gpu-a", statusClass: 5, durationMilliseconds: 0, state: "error")])
        await service.stop()
    }

    func test_refreshCoalescesWhileCycleInFlightAndReturnsImmediately() async throws {
        let capture = LocalProbeCapture()
        let gate = ProbeResponseGate()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            await gate.wait()
            return .init(status: 200, body: Data(#"{"data":[]}"#.utf8))
        }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { await capture.publish($0) }
        for _ in 0..<1000 {
            if await capture.requests.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<20 { await service.requestCycle() }
        let calls = await capture.requests.count
        let completed = await capture.loads.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(completed, 0)
        await gate.release()
        _ = try await capture.waitForLoad()
        await service.stop()
    }

    func test_stopDuringReconfigurationCannotRestartNetworkReader() async throws {
        let capture = LocalProbeCapture()
        let gate = ProbeResponseGate()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            return .init(status: 200, body: Data(#"{"data":[]}"#.utf8))
        }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { load in
            if load.hosts.isEmpty, await capture.consumeHold() { await gate.wait() }
            await capture.publish(load)
        }
        _ = try await capture.waitForLoad()
        var changed = BrokerLocalRouteTests.route(); changed.host = "gpu-b"; changed.probeURL = "http://gpu-b.example:11434"
        let reconfigure = Task { await service.configure(routes: [changed]) }
        for _ in 0..<1000 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await service.stop()
        await gate.release()
        await reconfigure.value
        try await Task.sleep(for: .milliseconds(10))
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
    }

    private func cycle(models: Data, slots: Data = idle, status: Int = 200,
                       failure: URLError? = nil) async throws -> (BrokerLocalLoad, [URLRequest]) {
        let capture = LocalProbeCapture()
        let service = LocalModelLoadService(transport: { request in
            await capture.record(request)
            if let failure { throw failure }
            return .init(status: status, body: request.url?.path == "/models" ? models : slots)
        }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        await service.configure(routes: [BrokerLocalRouteTests.route()])
        await service.start { await capture.publish($0) }
        let load = try await capture.waitForLoad()
        let requests = await capture.requests
        await service.stop()
        return (load, requests)
    }

    func test_autoloadFalseOnlyForLoadedPresetNeverDeclaredUnloadedPreset() async throws {
        let models = Data(#"{"data":[{"id":"qwen-27b","status":{"value":"unloaded"}},{"id":"other-model","status":{"value":"loaded"}}]}"#.utf8)
        let (load, requests) = try await cycle(models: models)
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.status, "unloaded")
        XCTAssertEqual(requests.map { $0.url?.path }, ["/models", "/slots"])
        XCTAssertEqual(requests[1].url?.query, "model=other-model&autoload=false")
    }

    func test_nothingLoadedHasNoModelScopedRequest() async throws {
        let (load, requests) = try await cycle(models: Data(#"{"data":[{"id":"qwen-27b","status":{"value":"sleeping"}}]}"#.utf8))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.status, "sleeping")
    }

    func test_missingDeclaredPresetIsFailed() async throws {
        let (load, requests) = try await cycle(models: Data(#"{"data":[]}"#.utf8))
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.status, "failed")
        XCTAssertEqual(requests.count, 1)
    }

    func test_downloadingAndUnknownBecomeLoading() async throws {
        for status in ["downloading", "new-status"] {
            let (load, requests) = try await cycle(models: Data("{\"data\":[{\"id\":\"qwen-27b\",\"status\":{\"value\":\"\(status)\"}}]}".utf8))
            XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.status, "loading")
            XCTAssertEqual(requests.count, 1)
        }
    }

    func test_unloadedFailedBecomesFailed() async throws {
        let (load, _) = try await cycle(models: Data(#"{"data":[{"id":"qwen-27b","status":{"value":"unloaded","failed":true}}]}"#.utf8))
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.status, "failed")
    }

    func test_aliasResolvesDeclaredPresetWithoutFalseFailure() async throws {
        let (load, requests) = try await cycle(models: Data(#"{"data":[{"id":"other-model","aliases":["qwen-27b"],"status":{"value":"loaded"}}]}"#.utf8))
        XCTAssertNil(load.hosts[0].presets["qwen-27b"])
        XCTAssertEqual(load.hosts[0].presets["other-model"]?.aliases, ["qwen-27b"])
        XCTAssertEqual(requests[1].url?.query, "model=other-model&autoload=false")
    }

    func test_non2xxAndMalformedAndOverCapBecomeError() async throws {
        for status in [301, 404, 500] {
            let (load, _) = try await cycle(models: Self.loaded, status: status)
            XCTAssertEqual(load.hosts[0].state, "error")
        }
        for body in [Data("broken".utf8), Data(repeating: 32, count: LocalModelLoadService.modelsCap + 1)] {
            let (load, _) = try await cycle(models: body)
            XCTAssertEqual(load.hosts[0].state, "error")
        }
    }

    func test_failedSlotsDiscardsPartialSnapshot() async throws {
        for body in [Data("broken".utf8), Data(repeating: 32, count: LocalModelLoadService.slotsCap + 1)] {
            let (load, requests) = try await cycle(models: Self.loaded, slots: body)
            XCTAssertEqual(load.hosts[0].state, "error")
            XCTAssertTrue(load.hosts[0].presets.isEmpty)
            XCTAssertEqual(requests.count, 2)
        }
    }

    func test_connectionDNSAndTimeoutBecomeUnreachable() async throws {
        for code in [URLError.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut] {
            let (load, _) = try await cycle(models: Self.loaded, failure: URLError(code))
            XCTAssertEqual(load.hosts[0].state, "unreachable")
        }
    }

    func test_strictDTOAndBusySlotCount() async throws {
        let models = Data(#"{"data":[{"id":"qwen-27b","status":{"value":"loaded"},"params":{"secret":"response-only"},"args":"response-only","preset":"response-only"}]}"#.utf8)
        let slots = Data(#"[{"id":0,"is_processing":true,"n_ctx":8192,"next_token":"response-only","params":"response-only"},{"id":1,"is_processing":false,"n_ctx":4096}]"#.utf8)
        let (load, _) = try await cycle(models: models, slots: slots)
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.slotsBusy, 1)
        XCTAssertEqual(load.hosts[0].presets["qwen-27b"]?.slotsTotal, 2)
        let encoded = String(decoding: try JSONEncoder().encode(load), as: UTF8.self)
        for prohibited in ["params", "next_token", "args", "response-only", "n_ctx"] { XCTAssertFalse(encoded.contains(prohibited)) }
    }

    func test_modelAndAliasBoundsRefuseBeforeSlots() async throws {
        let object: (Int, String, [String]) -> Data = { count, id, aliases in
            try! JSONSerialization.data(withJSONObject: ["data": (0..<count).map { index in
                ["id": count > 1 ? "model-\(index)" : id, "aliases": aliases, "status": ["value": "loaded"]] as [String: Any]
            }])
        }
        for body in [object(65, "qwen-27b", []), object(5, "qwen-27b", []), object(1, "", []),
                     object(1, String(repeating: "x", count: 129), []), object(1, "qwen-27b", Array(repeating: "a", count: 9))] {
            let (load, requests) = try await cycle(models: body)
            XCTAssertEqual(load.hosts[0].state, "error")
            XCTAssertEqual(requests.count, 1)
        }
    }

    func test_slotBoundRefuses65Slots() async throws {
        let slots = try JSONSerialization.data(withJSONObject: (0..<65).map { ["id": $0, "is_processing": false, "n_ctx": 4096] as [String: Any] })
        let (load, _) = try await cycle(models: Self.loaded, slots: slots)
        XCTAssertEqual(load.hosts[0].state, "error")
    }

    func test_defaultTransportStreamedAndDeclaredCaps() async throws {
        for path in ["models", "slots"] {
            let cap = path == "models" ? LocalModelLoadService.modelsCap : LocalModelLoadService.slotsCap
            for declared in [false, true] {
                let session = HealthTestSupport.session(body: declared ? Data() : Data(repeating: 32, count: cap + 1),
                                                       headers: declared ? ["Content-Length": "\(cap + 1)"] : [:])
                defer { session.invalidateAndCancel() }
                do {
                    _ = try await LocalModelLoadService.boundedResponse(URLRequest(url: URL(string: "http://gpu-a.example:11434/\(path)")!), session: session)
                    XCTFail("expected cap refusal")
                } catch { XCTAssertTrue(error is LocalModelLoadService.ProbeError) }
            }
        }
    }

    func test_redirectRefusedWithoutSecondHost() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        HealthStubURLProtocol.configure { _ in .init(status: 302, redirect: URL(string: "http://gpu-b.example:11434/models")) }
        let response = try await LocalModelLoadService.boundedResponse(URLRequest(url: URL(string: "http://gpu-a.example:11434/models")!), session: session)
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(HealthStubURLProtocol.requests.map { $0.url?.host }, ["gpu-a.example"])
    }

    func test_defaultTransportHasNoPersistentNetworkStorage() {
        let configuration = LocalModelLoadService.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 2)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 2)
    }
}

actor LocalProbeCapture {
    var requests: [URLRequest] = []
    var loads: [BrokerLocalLoad] = []
    var logs: [LocalProbeLog] = []
    var delays: [Double] = []
    private var hold = true
    func consumeHold() -> Bool { defer { hold = false }; return hold }
    func recordDelay(_ seconds: Double) -> Int { delays.append(seconds); return delays.count }
    func record(_ request: URLRequest) { requests.append(request) }
    func publish(_ load: BrokerLocalLoad) { loads.append(load) }
    func waitForLoad(count: Int = 1) async throws -> BrokerLocalLoad {
        for _ in 0..<2000 {
            if loads.count >= count { return loads[count - 1] }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
}

private final class ProbeLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LocalProbeLog] = []
    var entries: [LocalProbeLog] { lock.withLock { values } }
    func append(_ entry: LocalProbeLog) { lock.withLock { values.append(entry) } }
}

actor ProbeResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
