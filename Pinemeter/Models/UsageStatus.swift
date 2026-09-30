//
//  UsageStatus.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import SwiftUI

/// Usage status level for visual indication
enum UsageStatus: String, Codable, Sendable {
    case safe      // 0-49%
    case warning   // 50-79%
    case critical  // 80-100%

    /// SwiftUI color for this status
    var color: Color {
        switch self {
        case .safe: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// SF Symbol for status indicator
    var iconName: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    /// VoiceOver description (Principle V - Accessibility)
    var accessibilityDescription: String {
        switch self {
        case .safe: return "Safe usage level"
        case .warning: return "Warning: approaching limit"
        case .critical: return "Critical: near or at limit"
        }
    }
}
