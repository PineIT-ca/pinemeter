import Sparkle

@MainActor
protocol AppUpdaterProtocol {
    func installAvailableUpdate()
}

@MainActor
final class AppUpdater: AppUpdaterProtocol {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var hasStarted = false

    func installAvailableUpdate() {
        if !hasStarted {
            controller.startUpdater()
            hasStarted = true
        }
        controller.updater.checkForUpdates()
    }
}
