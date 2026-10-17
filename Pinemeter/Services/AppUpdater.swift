import Sparkle

@MainActor
protocol AppUpdaterProtocol {
    func start()
    func installAvailableUpdate()
    func setBetaUpdatesEnabled(_ enabled: Bool)
}

@MainActor
final class AppUpdater: NSObject, AppUpdaterProtocol, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private let startUpdaterOverride: (() -> Void)?
    private let resetUpdateCycleOverride: (() -> Void)?
    private var hasStarted = false
    private var betaUpdatesEnabled = false

    init(
        startUpdater: (() -> Void)? = nil,
        resetUpdateCycle: (() -> Void)? = nil
    ) {
        startUpdaterOverride = startUpdater
        resetUpdateCycleOverride = resetUpdateCycle
        super.init()
    }

    static func allowedChannels(betaUpdatesEnabled: Bool) -> Set<String> {
        betaUpdatesEnabled ? ["beta"] : []
    }

    var allowedChannels: Set<String> {
        Self.allowedChannels(betaUpdatesEnabled: betaUpdatesEnabled)
    }

    func setBetaUpdatesEnabled(_ enabled: Bool) {
        guard betaUpdatesEnabled != enabled else { return }
        betaUpdatesEnabled = enabled
        if enabled {
            startUpdaterIfNeeded()
        }
        if hasStarted {
            resetUpdateCycle()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }

    func start() {
        startUpdaterIfNeeded()
    }

    func installAvailableUpdate() {
        startUpdaterIfNeeded()
        controller.updater.checkForUpdates()
    }

    private func startUpdaterIfNeeded() {
        guard !hasStarted else { return }
        if let startUpdaterOverride {
            startUpdaterOverride()
        } else {
            controller.startUpdater()
        }
        hasStarted = true
    }

    private func resetUpdateCycle() {
        if let resetUpdateCycleOverride {
            resetUpdateCycleOverride()
        } else {
            controller.updater.resetUpdateCycle()
        }
    }
}
