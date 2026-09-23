//
//  PinemeterApp.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import AppKit
import SwiftUI

/// Main app entry point
@main
struct PinemeterApp: App {
    static let settingsWindowID = "settings"
    static let brokerWindowID = "broker"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        let model = AppModel(
            releaseCheckService: ReleaseCheckService(),
            presetManifestService: PresetManifestService(),
            appUpdater: AppUpdater()
        )
        _appModel = State(initialValue: model)
        appDelegate.configure(appModel: model)

        #if DEBUG
        if let demoMode = DemoMode.fromArguments() {
            appDelegate.configureDemoMode(true)
            DemoDataFactory.configure(model, for: demoMode)
        }
        #endif
    }

    var body: some Scene {
        // A `Window` scene (not `Settings`) so the preferences window is
        // user-resizable and fits its content; `Settings` renders fixed-size.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(appModel: appModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 580)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand(settingsWindowID: Self.settingsWindowID)
            }
        }

        Window("Broker", id: Self.brokerWindowID) {
            BrokerWindowView(appModel: appModel)
                // Routing's role and chain editor needs this width; its fixed
                // header and pane picker need this height to leave room to scroll.
                .frame(minWidth: 620, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .windowResizability(.contentMinSize)
        // Show the full role and chain editor on first open. macOS restores
        // the user's window size on later opens.
        .defaultSize(width: 680, height: 760)
    }
}

/// Standard app-menu "Settings…" item wired to the resizable `Window` scene,
/// preserving the ⌘, shortcut that the `Settings` scene provided for free.
private struct SettingsMenuCommand: View {
    let settingsWindowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: settingsWindowID)
        }
        .keyboardShortcut(",", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .openBrokerSettings)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: PinemeterApp.brokerWindowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAccountsSettings)) { _ in
            SettingsView.selectTab(.accounts)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: settingsWindowID)
        }

        Button("Broker…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: PinemeterApp.brokerWindowID)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}
