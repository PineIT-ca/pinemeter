import Foundation
import Observation

/// The lifecycle and intake seams the app needs from the broker beyond the
/// MCP tool surface (`BrokerServiceProtocol`).
protocol BrokerLifecycleProtocol: BrokerServiceProtocol {
    func updatePolicy(_ policy: BrokerPolicy) async
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async
    func updateT3Liveness(_ liveness: [String: T3Liveness]) async
    func refreshT3Liveness() async -> [String: T3Liveness]
    func t3LivenessSnapshot() async -> [String: T3Liveness]
    func updateServerState(_ state: BrokerUIState.ServerState) async
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) async
    func uiStateUpdates() async -> AsyncStream<BrokerUIState>
    func recentPicks() async -> [RecentPick]
    func latestInstructionCheck() async -> InstructionCheck?
}

extension BrokerLifecycleProtocol {
    func recentPicks() async -> [RecentPick] { [] }
    func latestInstructionCheck() async -> InstructionCheck? { nil }
    func refreshT3Liveness() async -> [String: T3Liveness] { [:] }
    func t3LivenessSnapshot() async -> [String: T3Liveness] { [:] }
}

extension BrokerService: BrokerLifecycleProtocol {
    func recentPicks() async -> [RecentPick] { recentPicksSnapshot }
}

protocol BrokerLoopbackServerProtocol: Sendable {
    @discardableResult
    func start() async throws -> UInt16
    func stop() async
}

extension LoopbackHTTPServer: BrokerLoopbackServerProtocol {}

@MainActor
@Observable
final class BrokerLifecycleController {
    private(set) var uiState: BrokerUIState?

    @ObservationIgnored private let brokerService: any BrokerLifecycleProtocol
    @ObservationIgnored private let keychainRepository: any KeychainRepositoryProtocol
    @ObservationIgnored private let serverFactory: @Sendable (
        _ broker: any BrokerServiceProtocol, _ port: UInt16, _ accessPolicy: BrokerAccessPolicy
    ) -> any BrokerLoopbackServerProtocol
    @ObservationIgnored private var server: (any BrokerLoopbackServerProtocol)?
    @ObservationIgnored private var boundPort: UInt16?
    @ObservationIgnored private var activeAccessPolicy: BrokerAccessPolicy?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var uiStateTask: Task<Void, Never>?

    init(
        brokerService: any BrokerLifecycleProtocol,
        keychainRepository: any KeychainRepositoryProtocol,
        serverFactory: @escaping @Sendable (
            _ broker: any BrokerServiceProtocol, _ port: UInt16, _ accessPolicy: BrokerAccessPolicy
        ) -> any BrokerLoopbackServerProtocol
    ) {
        self.brokerService = brokerService
        self.keychainRepository = keychainRepository
        self.serverFactory = serverFactory
    }

    deinit {
        uiStateTask?.cancel()
    }

    /// Applies one broker-settings snapshot. Returns false when a newer call
    /// superseded this one while it was suspended.
    @discardableResult
    func apply(_ settings: BrokerSettings) async -> Bool {
        generation += 1
        let generation = generation

        await brokerService.updatePolicy(settings.policy)
        guard generation == self.generation else { return false }

        guard settings.isEnabled else {
            await stopServer(generation: generation)
            return generation == self.generation
        }

        let desiredPort = UInt16(clamping: settings.port)
        let desiredAccessPolicy = await accessPolicy(for: settings)
        guard generation == self.generation else { return false }

        if server == nil {
            await brokerService.updateT3Liveness([:])
            _ = await brokerService.refreshT3Liveness()
            guard generation == self.generation else { return false }
            await startServer(
                port: desiredPort,
                accessPolicy: desiredAccessPolicy,
                generation: generation
            )
            return generation == self.generation
        }

        if boundPort != desiredPort || activeAccessPolicy != desiredAccessPolicy {
            await stopServer(generation: generation)
            guard generation == self.generation else { return false }
            await startServer(
                port: desiredPort,
                accessPolicy: desiredAccessPolicy,
                generation: generation
            )
        }
        return generation == self.generation
    }

    func startUIStateObserver(_ publish: @escaping @MainActor (BrokerUIState) -> Void) {
        uiStateTask?.cancel()
        let brokerService = brokerService
        uiStateTask = Task { [weak self] in
            for await state in await brokerService.uiStateUpdates() {
                guard let self else { return }
                uiState = state
                publish(state)
            }
        }
    }

    private func accessPolicy(for settings: BrokerSettings) async -> BrokerAccessPolicy {
        let key: String?
        if settings.apiKeyMode == .none {
            key = nil
        } else {
            key = try? await keychainRepository.retrieve(account: BrokerAccessPolicy.keychainAccount)
        }
        return BrokerAccessPolicy(
            networkAccess: settings.networkAccess,
            apiKeyMode: settings.apiKeyMode,
            apiKey: key
        )
    }

    private func startServer(
        port: UInt16,
        accessPolicy: BrokerAccessPolicy,
        generation: Int
    ) async {
        let server = serverFactory(brokerService, port, accessPolicy)
        self.server = server
        boundPort = nil
        activeAccessPolicy = accessPolicy
        await brokerService.updateServerState(.starting)
        guard generation == self.generation else { return }
        do {
            let boundPort = try await server.start()
            guard generation == self.generation else {
                await server.stop()
                return
            }
            self.boundPort = boundPort
            activeAccessPolicy = accessPolicy
            await brokerService.updateServerState(.running(port: boundPort))
        } catch {
            guard generation == self.generation else { return }
            self.server = nil
            boundPort = nil
            activeAccessPolicy = nil
            if let loopbackError = error as? LoopbackHTTPServerError,
               case .addressInUse(let usedPort) = loopbackError {
                await brokerService.updateServerState(
                    .failed(message: "Port \(usedPort) is already in use.")
                )
            } else {
                await brokerService.updateServerState(
                    .failed(message: error.localizedDescription)
                )
            }
        }
    }

    private func stopServer(generation: Int? = nil) async {
        if let server {
            await server.stop()
        }
        if let generation, generation != self.generation { return }
        server = nil
        boundPort = nil
        activeAccessPolicy = nil
        await brokerService.updateServerState(.stopped)
    }
}
