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
        // Tall enough that the Broker tab's Routing pane — the longest content
        // in the window — opens showing the whole role/chain editor rather
        // than a scroll stub under the fixed header. Applies to a first open
        // only: after that macOS restores the frame the user left behind.
        .defaultSize(width: 680, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand(windowID: Self.settingsWindowID)
            }
        }
    }
}

/// Standard app-menu "Settings…" item wired to the resizable `Window` scene,
/// preserving the ⌘, shortcut that the `Settings` scene provided for free.
private struct SettingsMenuCommand: View {
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .openBrokerSettings)) { _ in
            SettingsView.selectBrokerTab()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: windowID)
        }
    }
}
