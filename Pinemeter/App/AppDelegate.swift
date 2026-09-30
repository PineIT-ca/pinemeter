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
    private var brokerAlertObserver: NSObjectProtocol?
    /// Collapses a burst of degraded picks into one modal per cause.
    private let brokerAlertCoalescer = BrokerDegradedAlertCoalescer()

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

        // Stamp the launch time before any other work, so usage telemetry can
        // group records by launch instead of guessing restarts from gaps.
        BuildInfo.stampLaunch()

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

        brokerAlertObserver = NotificationCenter.default.addObserver(
            forName: .brokerDegradedPick,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      self.appModel?.settings.hasNotificationsEnabled == true,
                      let decision = note.object as? BrokerDecision else { return }
                guard let presentation = self.brokerAlertCoalescer.record(decision, at: Date())
                else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The slot was reserved synchronously in `record`. Release
                    // it on every exit, or one early return here mutes the
                    // alert channel for the life of the process.
                    defer { self.brokerAlertCoalescer.abandonPresentingIfNeeded(at: Date()) }
                    guard let appModel = self.appModel else { return }

                    // Drain: causes that first appeared while a modal was up
                    // are shown now rather than dropped. Bounded by the number
                    // of distinct causes, never by the number of picks.
                    var next: BrokerDegradedAlertCoalescer.Presentation? = presentation
                    while let current = next {
                        let fault = appModel.brokerProviderFault(for: current.decision)
                        let action = BrokerDegradedAlertAction.forDecision(
                            fault: fault,
                            hasActiveCooldowns: await appModel.hasActiveBrokerCooldowns()
                        )
                        self.presentBrokerAlert(current, fault: fault, action: action)
                        next = self.brokerAlertCoalescer.didFinishPresenting(at: Date())
                    }
                }
            }
        }
    }

    private func presentBrokerAlert(
        _ presentation: BrokerDegradedAlertCoalescer.Presentation,
        fault: BrokerProviderFault?,
        action: BrokerDegradedAlertAction
    ) {
        let decision = presentation.decision
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = fault?.alertTitle ?? "Broker Route Degraded"
        alert.informativeText = [
            Self.affectedLine(presentation),
            presentation.candidate,
            decision.degradedReason ?? decision.reason,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: action.buttonTitle)
        alert.addButton(withTitle: "Dismiss")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch action {
        case .clearCooldowns:
            Task { [weak self] in
                _ = await self?.appModel?.resetBrokerDegradedPaths()
            }
        case .openBrokerSettings:
            NotificationCenter.default.post(name: .openBrokerSettings, object: nil)
        case .openAccountsSettings:
            NotificationCenter.default.post(name: .openAccountsSettings, object: nil)
        }
    }

    /// Who was affected, and how widely. A lone pick reads as it always did;
    /// a burst says so, because the count is the difference between "a route
    /// wobbled" and "everything has been failing since you left".
    private static func affectedLine(_ presentation: BrokerDegradedAlertCoalescer.Presentation) -> String {
        let who = "\(presentation.callers.joined(separator: ", ")) "
            + "requested \(presentation.roles.joined(separator: ", "))."
        guard presentation.count > 1 else { return who }
        let since = DateFormatter.localizedString(
            from: presentation.firstSeen,
            dateStyle: .none,
            timeStyle: .short
        )
        return who + " \(presentation.count) picks since \(since)."
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else { return .terminateNow }
        Task {
            await appModel.flushUsageTelemetry()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

        // Give SwiftUI a beat to lay out and the usage fetches a chance to
        // land before snapshotting.
        try? await Task.sleep(for: .milliseconds(3000))

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
