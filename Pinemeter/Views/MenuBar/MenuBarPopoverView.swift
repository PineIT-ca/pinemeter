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

            if appModel.hasConfiguredUsageProvider {
                UsagePopoverView(appModel: appModel, onRequestClose: onRequestClose)
            } else {
                SetupWizardView(appModel: appModel)
            }
        }
    }
}
