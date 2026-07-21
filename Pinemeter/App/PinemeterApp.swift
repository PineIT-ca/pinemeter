//
//  PinemeterApp.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import SwiftUI

/// Main app entry point
@main
struct PinemeterApp: App {
    static let settingsWindowID = "settings"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        let model = AppModel()
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
        .defaultSize(width: 520, height: 600)
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
    }
}
