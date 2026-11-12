//
//  MenuBarIconRenderer.swift
//  Pinemeter
//
//  Created by Edd on 2026-01-09.
//

import AppKit
import SwiftUI

/// Renders SwiftUI MenuBarIconView to NSImage using ImageRenderer.
@MainActor
struct MenuBarIconRenderer {
    func render(
        percentage: Double,
        status: UsageStatus,
        isLoading: Bool,
        isStale: Bool,
        iconStyle: IconStyle,
        weeklyPercentage: Double = 0,
        isColored: Bool = true,
        quotaBars: [MenuBarQuotaBar] = []
    ) -> NSImage {
        let iconView = MenuBarIconView(
            percentage: percentage,
            status: status,
            isLoading: isLoading,
            isStale: isStale,
            iconStyle: iconStyle,
            weeklyPercentage: weeklyPercentage,
            quotaBars: quotaBars
        )

        let renderer = ImageRenderer(content: iconView)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let nsImage = renderer.nsImage else {
            return NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Error"
            ) ?? NSImage()
        }

        nsImage.isTemplate = !isColored
        return nsImage
    }
}
