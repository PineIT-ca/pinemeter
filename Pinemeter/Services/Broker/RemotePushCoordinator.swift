import Foundation

struct ProviderCredentialMutation: Sendable, Equatable {
    let provider: RemotePushProvider
    let account: String
}

struct RemotePushSourceSnapshot: Sendable {
    let hosts: [RemoteHost]
    let inventory: RemotePushAccountInventory
    let policy: BrokerPolicy
    let cooldowns: [String: Date]
    let oracleSnapshot: OracleSnapshot?

    static let empty = RemotePushSourceSnapshot(
        hosts: [],
        inventory: RemotePushAccountInventory(claude: [], chatGPT: [], gemini: []),
        policy: .default,
        cooldowns: [:],
        oracleSnapshot: nil
    )
}

enum RemotePushAttemptUpdate: Sendable, Equatable {
    case started(hostID: UUID)
    case finished(
        hostID: UUID,
        completedAt: Date,
        result: RemotePushResult,
        sanitizedError: String?
    )
    case status(hostID: UUID, observation: RemoteHostCredentialObservation)
}

struct RemoteHostCredentialObservation: Sendable, Equatable {
    let status: RemoteCredentialStatus
    let observedAt: Date?
    let observedGeneration: UInt64?
}

actor RemotePushCoordinator {
    typealias SourceLoader = @Sendable () async -> RemotePushSourceSnapshot
    typealias GenerationReserver = @Sendable () async throws -> UInt64
    typealias BundleBuilder = @Sendable (
        _ generation: UInt64,
        _ pushedAt: Date,
        _ source: RemotePushSourceSnapshot
    ) async throws -> Data
    typealias Sender = @Sendable (_ bundle: Data, _ host: RemoteHost) async throws -> Void
    typealias StatusFetcher = @Sendable (_ host: RemoteHost) async throws -> HostStatusDTO
    typealias UpdateRecorder = @Sendable (RemotePushAttemptUpdate) async -> Void
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static let debounceDelay: Duration = .milliseconds(500)
    static let retryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

    private let loadSource: SourceLoader
    private let reserveGeneration: GenerationReserver
    private let buildBundle: BundleBuilder
    private let send: Sender
    private let fetchStatus: StatusFetcher?
    private let recordUpdate: UpdateRecorder
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    private var scheduled: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var active: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var dirtyHosts = Set<UUID>()
    private var pendingFailures = Set<UUID>()
    private var acceptedGenerations: [UUID: UInt64] = [:]
    private var activeStatus: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var pendingStatus: [UUID: StatusRequest] = [:]

    init(
        loadSource: @escaping SourceLoader,
        reserveGeneration: @escaping GenerationReserver,
        buildBundle: @escaping BundleBuilder,
        send: @escaping Sender,
        fetchStatus: StatusFetcher? = nil,
        recordUpdate: @escaping UpdateRecorder,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadSource = loadSource
        self.reserveGeneration = reserveGeneration
        self.buildBundle = buildBundle
        self.send = send
        self.fetchStatus = fetchStatus
        self.recordUpdate = recordUpdate
        self.sleep = sleep
        self.now = now
    }

    func scheduleAutomaticPush() async {
        let source = await loadSource()
        for host in source.hosts {
            schedule(hostID: host.id, after: Self.debounceDelay, retryIndex: 0)
        }
    }

    func manualPush(hostID: UUID) {
        cancelScheduled(hostID: hostID)
        pendingFailures.remove(hostID)
        startAttempt(hostID: hostID, retryIndex: 0)
    }

    func retryPending() {
        let hostIDs = pendingFailures
        pendingFailures.removeAll()
        for hostID in hostIDs {
            startAttempt(hostID: hostID, retryIndex: 0)
        }
    }

    func refreshStatus() async {
        guard fetchStatus != nil else { return }
        let source = await loadSource()
        for host in source.hosts {
            requestStatus(StatusRequest(
                host: host,
                inventory: source.inventory,
                expectedGeneration: acceptedGenerations[host.id],
                freshnessThreshold: source.policy.thresholds.stalenessSeconds
            ))
        }
    }

    func hostRemoved(_ hostID: UUID) {
        cancelScheduled(hostID: hostID)
        if let running = active.removeValue(forKey: hostID) {
            running.task.cancel()
        }
        dirtyHosts.remove(hostID)
        pendingFailures.remove(hostID)
        acceptedGenerations.removeValue(forKey: hostID)
        pendingStatus.removeValue(forKey: hostID)
        activeStatus.removeValue(forKey: hostID)?.task.cancel()
    }

    private func schedule(hostID: UUID, after delay: Duration, retryIndex: Int) {
        if active[hostID] != nil {
            dirtyHosts.insert(hostID)
            return
        }
        cancelScheduled(hostID: hostID)
        let token = UUID()
        let task = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scheduledDelayFinished(hostID: hostID, token: token, retryIndex: retryIndex)
        }
        scheduled[hostID] = (token, task)
    }

    private func scheduledDelayFinished(hostID: UUID, token: UUID, retryIndex: Int) {
        guard scheduled[hostID]?.token == token else { return }
        scheduled[hostID] = nil
        startAttempt(hostID: hostID, retryIndex: retryIndex)
    }

    private func startAttempt(hostID: UUID, retryIndex: Int) {
        guard active[hostID] == nil else {
            dirtyHosts.insert(hostID)
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.recordUpdate(.started(hostID: hostID))
            let outcome = await self.performAttempt(hostID: hostID)
            await self.attemptFinished(
                hostID: hostID,
                token: token,
                retryIndex: retryIndex,
                outcome: outcome
            )
        }
        active[hostID] = (token, task)
    }

    private func performAttempt(hostID: UUID) async -> AttemptOutcome {
        do {
            try Task.checkCancellation()
            let source = await loadSource()
            guard let host = source.hosts.first(where: { $0.id == hostID }) else {
                return .removed
            }
            let generation = try await reserveGeneration()
            let pushedAt = now()
            let bundle = try await buildBundle(generation, pushedAt, source)
            try Task.checkCancellation()
            try await send(bundle, host)
            return .completed(
                at: now(),
                result: .succeeded,
                sanitizedError: nil,
                acceptedGeneration: generation,
                source: source,
                host: host
            )
        } catch is CancellationError {
            return .removed
        } catch {
            return .completed(
                at: now(),
                result: .failed,
                sanitizedError: Self.sanitizedMessage(for: error),
                acceptedGeneration: nil,
                source: nil,
                host: nil
            )
        }
    }

    private func attemptFinished(
        hostID: UUID,
        token: UUID,
        retryIndex: Int,
        outcome: AttemptOutcome
    ) async {
        guard active[hostID]?.token == token else { return }
        active[hostID] = nil

        switch outcome {
        case .removed:
            dirtyHosts.remove(hostID)
            pendingFailures.remove(hostID)
        case .completed(
            let completedAt,
            let result,
            let sanitizedError,
            let acceptedGeneration,
            let source,
            let host
        ):
            await recordUpdate(.finished(
                hostID: hostID,
                completedAt: completedAt,
                result: result,
                sanitizedError: sanitizedError
            ))

            if result == .succeeded,
               let acceptedGeneration,
               let source,
               let host {
                acceptedGenerations[hostID] = acceptedGeneration
                requestStatus(StatusRequest(
                    host: host,
                    inventory: source.inventory,
                    expectedGeneration: acceptedGeneration,
                    freshnessThreshold: source.policy.thresholds.stalenessSeconds
                ))
            }

            if dirtyHosts.remove(hostID) != nil {
                pendingFailures.remove(hostID)
                startAttempt(hostID: hostID, retryIndex: 0)
            } else if result == .failed, retryIndex < Self.retryDelays.count {
                schedule(
                    hostID: hostID,
                    after: Self.retryDelays[retryIndex],
                    retryIndex: retryIndex + 1
                )
            } else if result == .failed {
                pendingFailures.insert(hostID)
            } else {
                pendingFailures.remove(hostID)
            }
        }
    }

    private func cancelScheduled(hostID: UUID) {
        scheduled.removeValue(forKey: hostID)?.task.cancel()
    }

    private func requestStatus(_ request: StatusRequest) {
        guard let fetchStatus else { return }
        let hostID = request.host.id
        if activeStatus[hostID] != nil {
            pendingStatus[hostID] = request
            return
        }
        let token = UUID()
        let task = Task { [weak self, now] in
            let result: StatusFetchResult
            do {
                let status = try await fetchStatus(request.host)
                result = .success(Self.aggregateStatus(
                    status,
                    inventory: request.inventory,
                    expectedGeneration: request.expectedGeneration,
                    now: now(),
                    freshnessThreshold: request.freshnessThreshold
                ))
            } catch {
                result = .failure
            }
            await self?.statusFinished(
                hostID: hostID,
                token: token,
                expectedGeneration: request.expectedGeneration,
                result: result
            )
        }
        activeStatus[hostID] = (token, task)
    }

    private func statusFinished(
        hostID: UUID,
        token: UUID,
        expectedGeneration: UInt64?,
        result: StatusFetchResult
    ) async {
        guard activeStatus[hostID]?.token == token else { return }
        activeStatus[hostID] = nil

        let source = await loadSource()
        let hostStillExists = source.hosts.contains { $0.id == hostID }
        let currentGeneration = acceptedGenerations[hostID]
        let generationStillCurrent = expectedGeneration == nil
            || currentGeneration == nil
            || currentGeneration == expectedGeneration
        if hostStillExists, generationStillCurrent {
            let observation = switch result {
            case .success(let observation): observation
            case .failure:
                RemoteHostCredentialObservation(
                    status: .unknown,
                    observedAt: nil,
                    observedGeneration: nil
                )
            }
            await recordUpdate(.status(hostID: hostID, observation: observation))
        }

        if let pending = pendingStatus.removeValue(forKey: hostID), hostStillExists {
            requestStatus(pending)
        }
    }

    static func aggregateStatus(
        _ status: HostStatusDTO,
        inventory: RemotePushAccountInventory,
        expectedGeneration: UInt64?,
        now: Date,
        freshnessThreshold: TimeInterval = Constants.Refresh.stalenessThreshold
    ) -> RemoteHostCredentialObservation {
        let configured = Set(
            inventory.claude.map { AccountKey(provider: HostStatusProvider.claude.rawValue, id: $0.id) }
                + inventory.chatGPT.map { AccountKey(provider: HostStatusProvider.chatgpt.rawValue, id: $0.id) }
                + inventory.gemini.map { AccountKey(provider: HostStatusProvider.gemini.rawValue, id: $0.id) }
        )
        let relevant = status.accounts.filter {
            configured.contains(AccountKey(provider: $0.provider.rawValue, id: $0.id))
        }
        let historicalAt = relevant.compactMap(\.observedAt)
            .filter { $0 <= now }
            .min() ?? status.observedAt.flatMap { $0 <= now ? $0 : nil }
        let historical = RemoteHostCredentialObservation(
            status: .unknown,
            observedAt: historicalAt,
            observedGeneration: status.observedGeneration == 0 ? nil : status.observedGeneration
        )
        guard !configured.isEmpty,
              let expectedGeneration,
              status.acceptedGeneration == expectedGeneration,
              status.observedGeneration == expectedGeneration
        else { return historical }

        var rows: [AccountKey: HostAccountStatusDTO] = [:]
        for row in relevant {
            let key = AccountKey(provider: row.provider.rawValue, id: row.id)
            guard rows.updateValue(row, forKey: key) == nil else { return historical }
        }

        var hasChallenged = false
        var hasExpired = false
        var hasUnknown = false
        var observed: [Date] = []
        for key in configured {
            guard let row = rows[key],
                  let observedAt = row.observedAt,
                  observedAt <= now,
                  now.timeIntervalSince(observedAt) <= freshnessThreshold
            else {
                hasUnknown = true
                continue
            }
            observed.append(observedAt)
            switch row.verdict {
            case .challenged: hasChallenged = true
            case .sessionKeyInvalid: hasExpired = true
            case .unpolled, .rateLimited, .error: hasUnknown = true
            case .ok: break
            }
        }

        let aggregate: RemoteCredentialStatus
        if hasChallenged {
            aggregate = .challenged
        } else if hasExpired {
            aggregate = .expired
        } else if hasUnknown {
            aggregate = .unknown
        } else {
            aggregate = .fresh
        }
        return RemoteHostCredentialObservation(
            status: aggregate,
            observedAt: historicalAt ?? observed.min(),
            observedGeneration: status.observedGeneration
        )
    }

    private static func sanitizedMessage(for error: Error) -> String {
        switch error {
        case let error as RemoteSSHTransportError:
            return error.localizedDescription
        case let error as RemotePushBundleError:
            return "Push failed: \(error.localizedDescription)"
        case let error as RemoteHostSecretRepositoryError:
            return "Push failed: \(error.localizedDescription)"
        case SettingsRepositoryError.pushGenerationExhausted:
            return "Push failed: the remote push generation is exhausted."
        default:
            return "Push failed. Try again."
        }
    }
}

private enum AttemptOutcome: Sendable {
    case removed
    case completed(
        at: Date,
        result: RemotePushResult,
        sanitizedError: String?,
        acceptedGeneration: UInt64?,
        source: RemotePushSourceSnapshot?,
        host: RemoteHost?
    )
}

private struct StatusRequest: Sendable {
    let host: RemoteHost
    let inventory: RemotePushAccountInventory
    let expectedGeneration: UInt64?
    let freshnessThreshold: TimeInterval
}

private struct AccountKey: Hashable, Sendable {
    let provider: String
    let id: String
}

private enum StatusFetchResult: Sendable {
    case success(RemoteHostCredentialObservation)
    case failure
}
