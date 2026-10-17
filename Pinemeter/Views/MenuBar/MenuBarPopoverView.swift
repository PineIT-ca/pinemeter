//
//  MenuBarPopoverView.swift
//  Pinemeter
//
//  Created by Edd on 2026-01-14.
//

import SwiftUI

/// Root view for the menu bar popover, switching between setup and usage.
struct MenuBarPopoverView: View {
    @Bindable var appModel: AppModel
    let onRequestClose: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var keepsSetupVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if let version = appModel.availableUpdateVersion {
                Button("Upgrade to version \(version) now") {
                    onRequestClose()
                    appModel.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding()

                Divider()
            }

            if !appModel.isReady {
                VStack {
                    ProgressView("Opening Pinemeter…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                    Divider()
                    HStack {
                        Button("Settings…") {
                            onRequestClose()
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: PinemeterApp.settingsWindowID)
                        }
                        .keyboardShortcut(",", modifiers: .command)
                        Spacer()
                        Button("Quit Pinemeter") { NSApp.terminate(nil) }
                            .keyboardShortcut("q", modifiers: .command)
                    }
                    .buttonStyle(.borderless)
                    .padding()
                }
                .frame(width: 360)
            } else if !keepsSetupVisible && (appModel.hasConfiguredUsageProvider || appModel.settings.broker.isEnabled) {
                UsagePopoverView(appModel: appModel, onRequestClose: onRequestClose)
            } else {
                SetupWizardView(
                    appModel: appModel,
                    onRequestClose: { keepsSetupVisible = false; onRequestClose() },
                    onScanStarted: { keepsSetupVisible = true },
                    onContinue: { keepsSetupVisible = false }
                )
            }
        }
    }
}
