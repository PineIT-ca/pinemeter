//
//  Constants.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-17.
//

import Foundation

/// Application-wide constants
enum Constants {
    /// Cache configuration
    enum Cache {
        /// Memory cache time-to-live (slightly less than minimum refresh interval)
        static let ttl: TimeInterval = 55

        /// Maximum number of cached icons
        static let maxIconCacheSize = 100
    }

    /// Network configuration
    enum Network {
        /// Maximum number of retry attempts for failed requests
        static let maxRetries = 3

        /// Base delay multiplier for exponential backoff (network errors)
        static let backoffBase: Double = 2.0

        /// Base delay multiplier for rate limit backoff (more aggressive)
        static let rateLimitBackoffBase: Double = 3.0
    }

    /// Refresh intervals (in seconds)
    enum Refresh {
        /// Minimum refresh interval
        static let minimum: TimeInterval = 60

        /// Maximum refresh interval
        static let maximum: TimeInterval = 600

        /// Staleness threshold (2x max refresh interval to account for retries/delays)
        static let stalenessThreshold: TimeInterval = 1200
    }

    /// Pacing/risk calculation configuration
    enum Pacing {
        /// 5-hour session window duration
        static let sessionWindow: TimeInterval = 5 * 60 * 60

        /// 7-day weekly window duration
        static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60

        /// 30-day monthly window duration (ChatGPT meters free-plan Codex
        /// usage over a rolling 30 days rather than a week)
        static let monthlyWindow: TimeInterval = 30 * 24 * 60 * 60

        /// Ratio threshold for "at risk" status (using faster than sustainable)
        static let riskThreshold: Double = 1.2

        /// Floor on the elapsed-time divisor of the pacing ratio.
        ///
        /// The ratio divides usage by the fraction of the window that has
        /// elapsed, so near the start of a window the divisor approaches zero
        /// and any non-trivial reading exceeds `riskThreshold`. Six hours into
        /// a 7-day weekly window, 5% usage already scores 1.27. That is noise,
        /// not a burn rate, and it gated every Claude lane each morning.
        ///
        /// Clamping the divisor to a tenth of the window (16.8 hours weekly,
        /// 30 minutes for a session) removes that noise without going blind:
        /// early usage is judged against the pace the window could sustain at
        /// the floor rather than against a divisor that is still rounding
        /// toward zero. A genuine runaway burn — 30% of a week gone in the
        /// first three hours — still scores 3.0 and still trips the gate.
        static let minimumElapsedFraction: Double = 0.10

        /// Shortest window still treated as durable quota when ranking on
        /// expiry. The 5-hour session window recycles several times a day, so
        /// it never holds inventory that expires unspent.
        static let durableWindowFloor: TimeInterval = 24 * 60 * 60

        /// Floor for the hours-until-reset divisor used when ranking on
        /// expiry. Without it a window seconds from resetting would divide by
        /// nearly zero and outrank everything on a reading that is about to
        /// be replaced.
        static let minimumExpiryHours: Double = 1
    }

    /// Usage threshold configuration
    enum Thresholds {
        /// Visual status boundaries (fixed, for icon colors)
        /// These determine when the icon color changes from green → orange → red
        enum Status {
            /// Percentage where warning status begins (orange) - safe is 0..<warningStart
            static let warningStart: Double = 50
            /// Percentage where critical status begins (red) - warning is warningStart..<criticalStart
            static let criticalStart: Double = 80
        }

        /// Notification threshold configuration (user-configurable)
        enum Notification {
            /// Default warning notification threshold
            static let warningDefault: Double = 75
            /// Default critical notification threshold
            static let criticalDefault: Double = 90

            /// Slider bounds for warning threshold setting
            static let warningMin: Double = 50
            static let warningMax: Double = 90

            /// Slider bounds for critical threshold setting
            static let criticalMin: Double = 75
            static let criticalMax: Double = 100

            /// Slider step increment
            static let step: Double = 5
        }
    }
}
