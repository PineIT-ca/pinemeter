//
//  IconStyle.swift
//  Pinemeter
//
//  Created by Edd on 2025-12-28.
//

import Foundation

/// Menu bar icon display style. Legacy saved styles decode to the meter style.
enum IconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case dualBar

    var id: String { rawValue }

    var displayName: String { "Meters" }

    var description: String { "Compact quota meters for Claude and ChatGPT" }

    var systemImage: String { "chart.bar.fill" }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = IconStyle(rawValue: rawValue) ?? .dualBar
    }
}
