import Foundation
import Network
import XCTest
@testable import Pinemeter

final class LocalRouteEndToEndTests: XCTestCase {
    private var router: LocalRouteStubRouter?
    private var prober: LocalModelLoadService?
    private var server: LoopbackHTTPServer?
    private var directory: URL?
    private var port: UInt16 = 0

    override func tearDown() async throws {
        await prober?.stop()
        await server?.stop()
        await router?.stop()
        prober = nil
        server = nil
        router = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func test_idleRouter_controlledPickThroughDefaultTransportAndMCP() async throws {
        try await start(busyOtherModel: false)
        let result = try await pick()
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try contentText(result)
        let decision = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(decision["model"] as? String, "t3:pi/lab/qwen-27b")
        XCTAssertEqual(decision["residency"] as? String, "controlled")
        XCTAssertEqual(decision["route_class"] as? String, "controlled")
        XCTAssertEqual(decision["route"] as? String, "t3")
        let invocation = try XCTUnwrap(decision["invocation"] as? [String: Any])
        XCTAssertEqual(invocation["kind"] as? String, "t3-dispatch")
        XCTAssertEqual(invocation["instanceId"] as? String, "pi")
        XCTAssertEqual(invocation["model"] as? String, "lab/qwen-27b")
        let paths = await router?.paths
        XCTAssertEqual(paths, ["/models", "/slots?model=qwen-27b&autoload=false"])
    }

    func test_busyOtherModel_unloadedPresetNeverProbedAndPickFailsClosed() async throws {
        try await start(busyOtherModel: true)
        let result = try await pick()
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(try contentText(result),
                       "no controlled route available for role 'explore'; tried: t3:pi/lab/qwen-27b (local host 'gpu-a' busy with another model)")
        let paths = await router?.paths
        XCTAssertEqual(paths, ["/models", "/slots?model=other-model&autoload=false"])
        XCTAssertFalse(paths?.contains(where: { $0.contains("model=qwen-27b") }) ?? true)
    }

    private func start(busyOtherModel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalRouteEndToEndTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = LocalRouteStubRouter(busyOtherModel: busyOtherModel)
        self.router = router
        let routerPort = try await router.start()
        XCTAssertGreaterThan(routerPort, 0)
        var policy = BrokerLocalRouteTests.policy()
        policy.localRoutes[0].probeURL = "http://127.0.0.1:\(routerPort)"
        policy.localRoutes[0].residency = .controlled
        let broker = BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("cli-cooldowns.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            outcomeStore: BrokerOutcomeStore(storeDirectory: directory, now: { BrokerFixture.now }),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory),
            livenessChecker: LocalRouteReadyChecker(),
            now: { BrokerFixture.now }
        )
        await broker.updateOracleSnapshot(BrokerLocalRouteTests.oracle(gated: false))
        _ = await broker.refreshT3Liveness()
        let published = expectation(description: "real HTTP probe published host load")
        // start triggers one cycle; suspend the cadence until tearDown cancels it.
        // Deliberately omit transport injection to exercise URLSession and its bounds.
        let prober = LocalModelLoadService(clock: { BrokerFixture.now },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 0 }, log: { _ in })
        self.prober = prober
        await prober.configure(routes: policy.localRoutes)
        await prober.start { load in
            await broker.setLocalLoad(load)
            if !load.hosts.isEmpty { published.fulfill() }
        }
        await fulfillment(of: [published], timeout: 5)
        let status = await broker.status()
        XCTAssertEqual(status.local?.hosts.first?.state, "ok")
        let server = BrokerMCPServer.makeLoopbackServer(broker: broker, port: 0, version: "test")
        self.server = server
        port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        XCTAssertNotEqual(port, routerPort)
    }

    private func pick() async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "pick", "arguments": [
                "role": "explore", "caller": "codex", "residency": "controlled",
            ]],
        ])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(message["error"])
        return try XCTUnwrap(message["result"] as? [String: Any])
    }

    private func contentText(_ result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}

private struct LocalRouteReadyChecker: T3LivenessCheckerProtocol {
    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] {
        ["pi": .init(reachable: true, why: "fixture")]
    }
}

/// Canned router with no model-loading endpoint. All sockets bind IPv4 loopback.
private actor LocalRouteStubRouter {
    private let busyOtherModel: Bool
    private let queue = DispatchQueue(label: "LocalRouteEndToEndTests.router")
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private(set) var paths: [String] = []

    init(busyOtherModel: Bool) { self.busyOtherModel = busyOtherModel }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerState(state) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: queue)
        }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            ready?.resume(returning: port)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { await self?.received(id, accumulated: accumulated, data: data,
                                       complete: complete, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, accumulated: Data, data: Data?, complete: Bool, failed: Bool) {
        guard let connection = connections[id] else { return }
        let head = accumulated + (data ?? Data())
        guard !failed, head.count <= 8192 else { close(id); return }
        guard let text = String(data: head, encoding: .utf8), text.contains("\r\n\r\n") else {
            if complete { close(id) } else { receive(id, accumulated: head) }
            return
        }
        let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard request.count == 3 else { close(id); return }
        let path = String(request[1])
        paths.append(path)
        let body: String
        let status: String
        switch (request[0], path) {
        case ("GET", "/models"):
            body = busyOtherModel
                ? #"{"data":[{"id":"qwen-27b","status":{"value":"unloaded"}},{"id":"other-model","status":{"value":"loaded"}}]}"#
                : #"{"data":[{"id":"qwen-27b","status":{"value":"loaded"}}]}"#
            status = "200 OK"
        case ("GET", "/slots?model=qwen-27b&autoload=false") where !busyOtherModel:
            body = #"[{"id":0,"is_processing":false,"n_ctx":4096}]"#
            status = "200 OK"
        case ("GET", "/slots?model=other-model&autoload=false") where busyOtherModel:
            body = #"[{"id":0,"is_processing":true,"n_ctx":4096}]"#
            status = "200 OK"
        default:
            body = "{}"
            status = "404 Not Found"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    func stop() {
        listener?.cancel()
        listener = nil
        ready?.resume(throwing: CancellationError())
        ready = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }
}
