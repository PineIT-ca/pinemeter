//
//  MenuBarIconView.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import SwiftUI

/// SwiftUI view for the menu bar quota meters.
struct MenuBarIconView: View {
    let percentage: Double
    let status: UsageStatus
    let isLoading: Bool
    let isStale: Bool
    let iconStyle: IconStyle
    var weeklyPercentage: Double = 0
    var quotaBars: [MenuBarQuotaBar] = []

    var body: some View {
        DualBarIcon(
            percentage: percentage,
            status: status,
            isLoading: isLoading,
            isStale: isStale,
            quotaBars: quotaBars
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        MenuBarIconView(percentage: 30, status: .safe, isLoading: false, isStale: false, iconStyle: .dualBar)
        MenuBarIconView(percentage: 75, status: .warning, isLoading: false, isStale: false, iconStyle: .dualBar)
        MenuBarIconView(percentage: 95, status: .critical, isLoading: false, isStale: false, iconStyle: .dualBar)
        MenuBarIconView(percentage: 0, status: .safe, isLoading: true, isStale: false, iconStyle: .dualBar)
        MenuBarIconView(percentage: 50, status: .warning, isLoading: false, isStale: true, iconStyle: .dualBar)
    }
    .padding()
}
