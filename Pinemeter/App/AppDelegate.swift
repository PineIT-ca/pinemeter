import AppKit
import SwiftUI

/// App delegate to manage menu bar lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appModel: AppModel?
    private var menuBarManager: MenuBarManager?
    private var overlayWindow: NSWindow?
    private var resetObserver: NSObjectProtocol?
    private var alertObserver: NSObjectProtocol?

    #if DEBUG
    private var isDemoMode: Bool = false
    private var automationWindow: NSWindow?
    #endif

    func configure(appModel: AppModel) {
        self.appModel = appModel
    }

    #if DEBUG
    func configureDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app host; skip UI/permission side effects
        // so a reset posted by a test doesn't pop a real celebration window.
        if Self.isRunningUnitTests { return }

        SessionKeyImportPromptCoordinator.install()
        observeOverlayEvents()

        let model = appModel ?? {
            let fallbackModel = AppModel()
            self.appModel = fallbackModel
            return fallbackModel
        }()
        startMenuBar(with: model)

        // Prompt for notification permission on launch so alerts can be
        // delivered without the user first opening the Notifications settings.
        Task { await model.requestNotificationPermissionIfNeeded() }
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Center-screen overlays (reset celebration, usage alerts)

    private func observeOverlayEvents() {
        resetObserver = NotificationCenter.default.addObserver(
            forName: .usageDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentOverlay(ResetCelebrationView { [weak self] in
                    self?.dismissOverlay()
                })
            }
        }

        alertObserver = NotificationCenter.default.addObserver(
            forName: .usageAlert,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let payload = note.object as? UsageAlertPayload else { return }
                self.presentOverlay(UsageAlertView(payload: payload) { [weak self] in
                    self?.dismissOverlay()
                })
            }
        }
    }

    /// Shows a full-screen, click-through, transparent overlay hosting `content`.
    /// Any existing overlay is replaced.
    private func presentOverlay(_ content: some View) {
        guard let screen = NSScreen.main else { return }
        dismissOverlay()

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(rootView: content)
        // Fill the borderless window without letting the SwiftUI view impose an
        // intrinsic size (which loops AppKit's constraint solver).
        hostingView.sizingOptions = []
        hostingView.frame = screen.frame
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        overlayWindow = window
    }

    private func dismissOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func startMenuBar(with appModel: AppModel) {
        let manager = MenuBarManager(appModel: appModel)
        menuBarManager = manager

        #if DEBUG
        if isDemoMode {
            manager.startWithoutBootstrap()
        } else {
            manager.start()
        }

        if ProcessInfo.processInfo.arguments.contains("--open-popover-after-launch") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                showAutomationWindow(with: appModel)
            }
        }

        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "--render-screenshots"), flagIndex + 1 < args.count {
            let outputDir = args[flagIndex + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                await Self.renderScreenshots(to: outputDir, appModel: appModel)
                NSApp.terminate(nil)
            }
        }
        #else
        manager.start()
        #endif
    }

    #if DEBUG
    /// Renders the popover and menu bar icon to PNGs for README/App Store
    /// screenshots without needing Screen Recording permission. The popover is
    /// snapshotted from a real (offscreen) window because ImageRenderer cannot
    /// lay out its internal ScrollView.
    private static func renderScreenshots(to directory: String, appModel: AppModel) async {
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(appModel: appModel, onRequestClose: {})
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        // Give SwiftUI a beat to lay out before snapshotting.
        try? await Task.sleep(for: .milliseconds(700))

        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dirURL.appendingPathComponent("popover.png"))
            }
        }
        window.close()

        let icon = MenuBarIconView(
            percentage: appModel.usageData?.sessionUsage.percentage ?? 0,
            status: appModel.usageData?.primaryStatus ?? .safe,
            isLoading: false,
            isStale: false,
            iconStyle: appModel.settings.iconStyle,
            quotaBars: appModel.usageQuotaBars
        )
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 4
        if let nsImage = renderer.nsImage,
           let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dirURL.appendingPathComponent("menubar-icon.png"))
        }
    }

    private func showAutomationWindow(with appModel: AppModel) {
        let markerURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/pinemeter-vm-validation/debug-window-hook-ran.txt")
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "debug_window_hook_ran=true\n".write(to: markerURL, atomically: true, encoding: .utf8)

        NSApp.setActivationPolicy(.regular)

        if let automationWindow {
            automationWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pinemeter Automation"
        window.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(appModel: appModel) { [weak self] in
                self?.automationWindow?.close()
            }
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        automationWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}
