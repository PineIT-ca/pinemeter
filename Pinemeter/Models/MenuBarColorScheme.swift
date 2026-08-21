//
//  MenuBarColorScheme.swift
//  Pinemeter
//

import Foundation

/// Apple system-color palettes for quota meters.
enum MenuBarColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case spectrum
    case ocean
    case forest
    case sunset
    case berry
    case citrus

    var id: Self { self }

    var title: String {
        switch self {
        case .spectrum: "Spectrum"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .sunset: "Sunset"
        case .berry: "Berry"
        case .citrus: "Citrus"
        }
    }
}
