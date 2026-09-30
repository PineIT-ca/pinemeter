import Foundation
import Observation

struct T3DispatchStamps: Equatable, Sendable {
    var lastDispatchedAt: Date?
    var lastDispatchThreadID: String?
    var lastAutomaticDispatchAt: Date?
    var lastDispatchFailure: String?

    init(settings: BrokerInstructionDispatchSettings) {
        lastDispatchedAt = settings.lastDispatchedAt
        lastDispatchThreadID = settings.lastDispatchThreadID
        lastAutomaticDispatchAt = settings.lastAutomaticDispatchAt
        lastDispatchFailure = settings.lastDispatchFailure
    }
}

enum T3DispatchProjectListState: Equatable, Sendable {
    case notLoaded
    case loading
    case loadFailed
    case empty
    case available
}

enum T3DispatchModelSource: Equatable, Sendable {
    case broker
    case projectDefault
}

enum T3DispatchOutstandingRunState: Equatable, Sendable {
    case none
    case waiting
    case stalled
}

@MainActor
@Observable
final class T3DispatchController {
    static let stalledRunInterval: TimeInterval = 60 * 60
    /// The name T3 lists this connection under in Settings → Connections.
    static let clientLabel = "Pinemeter"

    private(set) var connection: T3DispatchConnection = .notConnected
    private(set) var isConnecting = false
    private(set) var projects: [T3Project] = []
    private(set) var hasLoadedProjects = false
    private(set) var isLoadingProjects = false
    private(set) var isDispatching = false
    private(set) var lastFailure: T3DispatchFailure?
    private(set) var lastModelSource: T3DispatchModelSource?
    private(set) var lastDispatchedAt: Date?
    private(set) var lastDispatchThreadID: String?
    private(set) var latestCheckAt: Date?

    var projectListState: T3DispatchProjectListState {
        if isLoadingProjects && !hasLoadedProjects { return .loading }
        guard hasLoadedProjects else { return lastFailure == nil ? .notLoaded : .loadFailed }
        return projects.isEmpty ? .empty : .available
    }

    var lastDispatchFailure: String? { lastFailure?.message }

    var hasOutstandingRun: Bool {
        outstandingRunState(at: now()) != .none
    }

    func connectionState(at date: Date) -> T3DispatchConnectionState? {
        connection.state(at: date)
    }

    func outstandingRunState(at date: Date) -> T3DispatchOutstandingRunState {
        guard let lastDispatchedAt,
              latestCheckAt.map({ $0 <= lastDispatchedAt }) ?? true else {
            return .none
        }
        return date.timeIntervalSince(lastDispatchedAt) >= Self.stalledRunInterval
            ? .stalled
            : .waiting
    }

    @ObservationIgnored private let client: T3DispatchClient
    @ObservationIgnored private let keychainRepository: any KeychainRepositoryProtocol
    @ObservationIgnored private let brokerService: any BrokerLifecycleProtocol
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pointerOrigin: @Sendable () async -> String?
    @ObservationIgnored private var credential: T3DispatchCredential?

    init(
        client: T3DispatchClient,
        keychainRepository: any KeychainRepositoryProtocol,
        brokerService: any BrokerLifecycleProtocol,
        now: @escaping @Sendable () -> Date = { Date() },
        pointerOrigin: (@Sendable () async -> String?)? = nil
    ) {
        self.client = client
        self.keychainRepository = keychainRepository
        self.brokerService = brokerService
        self.now = now
        self.pointerOrigin = pointerOrigin ?? { await client.pointerOrigin() }
    }

    func loadStoredConnection() async {
        do {
            let stored = try await keychainRepository.retrieve(account: T3DispatchCredential.keychainAccount)
            publish(try T3DispatchCredential.decode(stored))
        } catch {
            credential = nil
            connection = .notConnected
        }
    }

    func connect(pastedText: String) async {
        guard let credential = T3PairingInput.credential(from: pastedText) else {
            publish(.unusablePairingInput)
            return
        }
        guard let origin = await pointerOrigin() else {
            publish(.t3NotRunning)
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let exchanged = try await client.exchangePairingCredential(
                origin: origin,
                credential: credential,
                clientLabel: Self.clientLabel
            )
            let stored = try exchanged.encoded()
            try await keychainRepository.save(
                sessionKey: stored,
                account: T3DispatchCredential.keychainAccount
            )
            lastFailure = nil
            publish(try T3DispatchCredential.decode(stored))
        } catch T3DispatchClientError.unauthorized {
            publish(.credentialRejected)
        } catch {
            _ = await handle(error)
        }
    }

    func disconnect() async {
        try? await keychainRepository.delete(account: T3DispatchCredential.keychainAccount)
        credential = nil
        connection = .notConnected
        projects = []
        hasLoadedProjects = false
        lastFailure = nil
        lastModelSource = nil
    }

    func refreshProjects() async {
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        guard let credential = await credentialForRequest() else { return }
        guard let origin = await pointerOrigin() else {
            publish(.t3NotRunning)
            return
        }
        do {
            projects = try await client.listProjects(origin: origin, token: credential.accessToken)
            hasLoadedProjects = true
            lastFailure = nil
        } catch {
            _ = await handle(error)
        }
    }

    func dispatchInstructionRecheck(
        brokerEnabled: Bool,
        port: Int,
        settings: BrokerInstructionDispatchSettings,
        trigger: InstructionDispatchTrigger,
        now: Date,
        latestCheck: InstructionCheck?,
        fullAccess: Bool = false,
        isAutomaticDispatchEnabled: () -> Bool,
        isFullAccessForAllRunsEnabled: () -> Bool = { false }
    ) async -> T3DispatchStamps {
        var updated = T3DispatchStamps(settings: settings)
        guard brokerEnabled,
              !isDispatching,
              let projectID = settings.t3ProjectID,
              !projectID.isEmpty else {
            return updated
        }
        isDispatching = true
        defer { isDispatching = false }
        lastModelSource = nil

        guard let credential = await credentialForRequest() else {
            publish(.notConnected, storingIn: &updated)
            return updated
        }
        guard let origin = await pointerOrigin() else {
            publish(.t3NotRunning, storingIn: &updated)
            return updated
        }

        do {
            projects = try await client.listProjects(origin: origin, token: credential.accessToken)
            hasLoadedProjects = true
            guard let project = projects.first(where: { $0.id == projectID }) else {
                publish(.projectGone, storingIn: &updated)
                return updated
            }
            // The broker pick is audited, so an automatic attempt that reaches
            // it consumes the throttle whether or not it ends in a dispatch.
            // Earlier returns record nothing and may retry on the next tick.
            if trigger == .automatic {
                guard isAutomaticDispatchEnabled() else { return updated }
                updated.lastAutomaticDispatchAt = now
            }
            let decision = try? await brokerService.pick(role: "review", caller: nil)
            let selection: T3ModelSelection
            let source: T3DispatchModelSource
            switch T3DispatchModelResolution.resolve(
                decision: decision,
                projectDefault: project.defaultModelSelection
            ) {
            case .broker(let resolved):
                selection = resolved
                source = .broker
            case .projectDefault(let resolved):
                selection = resolved
                source = .projectDefault
            case .unresolved:
                publish(.noModelResolvable, storingIn: &updated)
                return updated
            }
            let command = T3DispatchCommand.instructionCheck(
                projectID: projectID,
                modelSelection: selection,
                port: port,
                now: now,
                fullAccess: (trigger == .manual && fullAccess)
                    || (settings.fullAccessForAllRuns && isFullAccessForAllRunsEnabled())
            )
            if trigger == .automatic, !isAutomaticDispatchEnabled() {
                updated.lastAutomaticDispatchAt = settings.lastAutomaticDispatchAt
                return updated
            }
            _ = try await client.dispatch(
                origin: origin,
                token: credential.accessToken,
                command: command
            )
            updated.lastDispatchedAt = now
            updated.lastDispatchThreadID = command.threadId
            updated.lastDispatchFailure = nil
            lastFailure = nil
            lastModelSource = source
            lastDispatchedAt = updated.lastDispatchedAt
            lastDispatchThreadID = updated.lastDispatchThreadID
            latestCheckAt = latestCheck?.checkedAt
        } catch {
            let failure = await handle(error)
            updated.lastDispatchFailure = BrokerLifecycleText.sanitizedFailureReason(failure.message)
        }
        return updated
    }

    func updateOutstandingRun(
        settings: BrokerInstructionDispatchSettings,
        latestCheck: InstructionCheck?
    ) {
        lastDispatchedAt = settings.lastDispatchedAt
        lastDispatchThreadID = settings.lastDispatchThreadID
        latestCheckAt = latestCheck?.checkedAt
    }

    private func publish(_ credential: T3DispatchCredential) {
        self.credential = credential
        switch credential.state(now: now()) {
        case .expired:
            connection = .expired(expiredAt: credential.expiresAt)
        case .connected, .expiringSoon:
            connection = .connected(expiresAt: credential.expiresAt, scope: credential.scope)
        }
    }

    @discardableResult
    private func handle(_ error: Error) async -> T3DispatchFailure {
        let clientError = error as? T3DispatchClientError
        if clientError == .unauthorized {
            try? await keychainRepository.delete(account: T3DispatchCredential.keychainAccount)
            credential = nil
            connection = .notConnected
        }
        let failure = T3DispatchFailure.classify(error)
        publish(failure)
        return failure
    }

    private func credentialForRequest() async -> T3DispatchCredential? {
        if credential == nil { await loadStoredConnection() }
        guard let credential else {
            publish(.notConnected)
            return nil
        }
        guard credential.state(now: now()) != .expired else {
            try? await keychainRepository.delete(account: T3DispatchCredential.keychainAccount)
            self.credential = nil
            connection = .expired(expiredAt: credential.expiresAt)
            publish(.credentialLapsed)
            return nil
        }
        return credential
    }

    private func publish(_ failure: T3DispatchFailure) {
        lastFailure = failure
    }

    private func publish(_ failure: T3DispatchFailure, storingIn stamps: inout T3DispatchStamps) {
        publish(failure)
        stamps.lastDispatchFailure = BrokerLifecycleText.sanitizedFailureReason(failure.message)
    }
}
