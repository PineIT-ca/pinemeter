//
//  ChatGPTCredits.swift
//  Pinemeter
//

import Foundation

/// The `credits` object of `wham/usage`. Decoding throws for a value that is
/// not an object or has none of the known keys; decode it through
/// `LenientChatGPTCredits` (or `try?`) so an odd shape never breaks the usage
/// decode around it.
struct ChatGPTCredits: Codable, Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    /// Remaining balance; the server has served it as a number and as a string.
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(hasCredits: Bool, unlimited: Bool = false, balance: Double? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    init(from decoder: Decoder) throws {
        // A non-object or key-less value is not credits: throw so the lenient
        // wrapper (or `try?`) turns it into nil.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.isEmpty == false else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no credits keys"))
        }
        let unlimited = (try? container.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? false
        var balance = (try? container.decodeIfPresent(Double.self, forKey: .balance)) ?? nil
        if balance == nil, let text = (try? container.decodeIfPresent(String.self, forKey: .balance)) ?? nil {
            balance = Double(text.trimmingCharacters(in: .whitespaces))
        }
        if let value = balance, !value.isFinite || value < 0 { balance = nil }
        let hasCredits = (try? container.decodeIfPresent(Bool.self, forKey: .hasCredits)) ?? false
        self.init(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
    }
}

/// Decodes `credits` without ever throwing; anything that is not a credits
/// object becomes nil.
struct LenientChatGPTCredits: Codable, Equatable, Sendable {
    let value: ChatGPTCredits?

    init(_ value: ChatGPTCredits?) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try? ChatGPTCredits(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}

/// Credits as the broker sees them: the balance plus what successive
/// observations say about burn. Burn and exhaustion are nil when unknown.
struct BrokerCreditsStatus: Codable, Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?
    let burnPerHour: Double?
    let exhaustsAt: Date?
}

/// Successive balance observations for one account. Pure and clock-free.
struct ChatGPTCreditTracker: Sendable {
    static let maxObservations = 48
    static let minSpanSeconds: TimeInterval = 600

    private(set) var observations: [(at: Date, balance: Double)] = []

    /// A rising balance is a top-up and starts a new series; an observation
    /// not newer than the last one is ignored.
    mutating func record(balance: Double, at: Date) {
        guard balance.isFinite, balance >= 0 else { return }
        if let last = observations.last {
            guard at > last.at else { return }
            if balance > last.balance { observations.removeAll() }
        }
        observations.append((at, balance))
        if observations.count > Self.maxObservations {
            observations.removeFirst(observations.count - Self.maxObservations)
        }
    }

    /// Never negative. Nil until two observations at least `minSpanSeconds`
    /// apart exist.
    var burnPerHour: Double? {
        guard let first = observations.first, let last = observations.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minSpanSeconds else { return nil }
        return max(0, first.balance - last.balance) / (span / 3600)
    }

    /// Folds one poll into the series. Unlimited credits drop the series; a
    /// missing balance adds nothing.
    mutating func observe(_ credits: ChatGPTCredits, at: Date) {
        if credits.unlimited {
            observations.removeAll()
        } else if let balance = credits.balance {
            record(balance: balance, at: at)
        }
    }

    func status(for credits: ChatGPTCredits) -> BrokerCreditsStatus {
        guard !credits.unlimited, credits.balance != nil else {
            return BrokerCreditsStatus(hasCredits: credits.hasCredits, unlimited: credits.unlimited,
                                       balance: credits.balance, burnPerHour: nil, exhaustsAt: nil)
        }
        let burn = burnPerHour
        var exhausts: Date?
        if let burn, burn > 0, let last = observations.last {
            exhausts = last.at.addingTimeInterval(last.balance / burn * 3600)
        }
        return BrokerCreditsStatus(hasCredits: credits.hasCredits, unlimited: false,
                                   balance: credits.balance, burnPerHour: burn, exhaustsAt: exhausts)
    }
}
