//
//  RemotePushBundle.swift
//  Pinemeter
//

import Foundation

enum RemotePushProvider: String, Sendable {
    case claude
    case chatGPT
    case gemini
}

enum RemotePushBundleError: LocalizedError, Equatable, Sendable {
    case invalidGeneration
    case invalidInventory(RemotePushProvider)
    case inventoryChanged
    case credentialUnavailable(RemotePushProvider)
    case invalidTimeZone
    case sectionTooLarge
    case bundleTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidGeneration:
            return "The remote push generation must be positive."
        case .invalidInventory(let provider):
            return "Remote push account inventory is invalid for \(provider.rawValue)."
        case .inventoryChanged:
            return "Connected accounts changed while preparing the remote push."
        case .credentialUnavailable(let provider):
            return "A connected \(provider.rawValue) credential could not be read."
        case .invalidTimeZone:
            return "The local time zone identifier is invalid."
        case .sectionTooLarge:
            return "A remote push bundle section exceeds the size limit."
        case .bundleTooLarge:
            return "The remote push bundle exceeds the size limit."
        }
    }
}

/// An immutable copy of the connected account metadata that AppModel hands to
/// the push builder. It contains Keychain references, never credential values.
struct RemotePushAccountInventory: Sendable, Equatable {
    struct Account: Sendable, Equatable {
        let id: String
        let label: String
        let isPrimary: Bool
        let keychainAccount: String
    }

    let claude: [Account]
    let chatGPT: [Account]
    let gemini: [Account]

    init(claude: [Account], chatGPT: [Account], gemini: [Account]) {
        self.claude = claude
        self.chatGPT = chatGPT
        self.gemini = gemini
    }

    /// Copies the complete AppModel-visible inventory. Legacy primary slots
    /// are added only when no registered account already claims that slot.
    init(
        settings: AppSettings,
        legacyClaudeConnected: Bool,
        legacyChatGPTConnected: Bool,
        legacyGeminiConnected: Bool
    ) {
        var claude = settings.claudeAccounts.map {
            Account(
                id: $0.id,
                label: $0.displayLabel,
                isPrimary: $0.isPrimary,
                keychainAccount: $0.keychainAccount
            )
        }
        if legacyClaudeConnected, !claude.contains(where: \.isPrimary) {
            claude.append(Account(
                id: settings.cachedOrganizationId?.uuidString ?? "claude.default",
                label: "Claude",
                isPrimary: true,
                keychainAccount: ClaudeAccount.primaryKeychainAccount
            ))
        }

        var chatGPT = settings.chatGPTAccounts.map {
            Account(
                id: $0.id,
                label: $0.brokerLabel,
                isPrimary: $0.isPrimary,
                keychainAccount: $0.keychainAccount
            )
        }
        if legacyChatGPTConnected, !chatGPT.contains(where: \.isPrimary) {
            let legacy = ChatGPTAccount.legacyPrimary(customLabel: settings.chatGPTCustomLabel)
            chatGPT.append(Account(
                id: legacy.id,
                label: legacy.brokerLabel,
                isPrimary: true,
                keychainAccount: legacy.keychainAccount
            ))
        }

        var gemini = settings.geminiAccounts.map {
            Account(
                id: $0.id,
                label: $0.displayLabel,
                isPrimary: $0.isPrimary,
                keychainAccount: $0.keychainAccount
            )
        }
        if legacyGeminiConnected, !gemini.contains(where: \.isPrimary) {
            let legacy = GeminiAccount.legacyPrimary(customLabel: settings.geminiCustomLabel)
            gemini.append(Account(
                id: legacy.id,
                label: legacy.displayLabel,
                isPrimary: true,
                keychainAccount: legacy.keychainAccount
            ))
        }

        self.init(claude: claude, chatGPT: chatGPT, gemini: gemini)
    }
}

actor RemotePushBundleBuilder {
    static let maxBundleBytes = 4 * 1_024 * 1_024
    static let maxSectionBytes = 1 * 1_024 * 1_024
    static let maxAccountsPerProvider = 64

    private let keychainRepository: any KeychainRepositoryProtocol
    private let chatGPTRepository: any ChatGPTSessionRepositoryProtocol
    private let geminiRepository: any GeminiAPIKeyRepositoryProtocol
    private let timeZoneIdentifier: @Sendable () -> String

    init(
        keychainRepository: any KeychainRepositoryProtocol,
        chatGPTRepository: any ChatGPTSessionRepositoryProtocol,
        geminiRepository: any GeminiAPIKeyRepositoryProtocol,
        timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
    ) {
        self.keychainRepository = keychainRepository
        self.chatGPTRepository = chatGPTRepository
        self.geminiRepository = geminiRepository
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    func build(
        generation: UInt64,
        pushedAt: Date,
        inventory: RemotePushAccountInventory,
        policy: BrokerPolicy,
        cooldowns: [String: Date],
        oracleSnapshot: OracleSnapshot?
    ) async throws -> Data {
        guard generation > 0 else {
            throw RemotePushBundleError.invalidGeneration
        }
        try Self.validate(inventory.claude, provider: .claude)
        try Self.validate(inventory.chatGPT, provider: .chatGPT)
        try Self.validate(inventory.gemini, provider: .gemini)

        let timeZone = timeZoneIdentifier()
        guard !timeZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeZone.utf8.count <= 128 else {
            throw RemotePushBundleError.invalidTimeZone
        }

        let credentials = try await credentials(for: inventory)
        let snapshot = oracleSnapshot.map {
            SnapshotWire(pushedAt: pushedAt, timeZone: timeZone, oracle: OracleWire($0))
        }
        let bundle = BundleWire(
            generation: generation,
            pushedAt: pushedAt,
            credentials: credentials,
            policy: policy,
            cooldowns: cooldowns,
            timeZone: timeZone,
            oracleSnapshot: snapshot
        )

        for section in [
            try Self.encoder().encode(credentials),
            try Self.encoder().encode(policy),
            try Self.encoder().encode(cooldowns),
            try snapshot.map { try Self.encoder().encode($0) },
        ].compactMap({ $0 }) where section.count > Self.maxSectionBytes {
            throw RemotePushBundleError.sectionTooLarge
        }

        let data = try Self.encoder().encode(bundle)
        guard data.count <= Self.maxBundleBytes else {
            throw RemotePushBundleError.bundleTooLarge
        }
        return data
    }

    private func credentials(for inventory: RemotePushAccountInventory) async throws -> CredentialsWire {
        var claude: [ClaudeWire] = []
        for account in inventory.claude {
            let value: String
            do {
                value = try await keychainRepository.retrieve(account: account.keychainAccount)
            } catch {
                throw RemotePushBundleError.credentialUnavailable(.claude)
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemotePushBundleError.credentialUnavailable(.claude)
            }
            claude.append(ClaudeWire(account: account, sessionKey: SecretWire(value)))
        }

        var chatGPT: [ChatGPTWire] = []
        for account in inventory.chatGPT {
            let session: ChatGPTSession
            do {
                session = try await chatGPTRepository.load(account: account.keychainAccount)
            } catch {
                throw RemotePushBundleError.credentialUnavailable(.chatGPT)
            }
            guard !session.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemotePushBundleError.credentialUnavailable(.chatGPT)
            }
            chatGPT.append(ChatGPTWire(account: account, cookie: SecretWire(session.sessionCookie)))
        }

        var gemini: [GeminiWire] = []
        for account in inventory.gemini {
            let key: GeminiAPIKey
            do {
                key = try await geminiRepository.load(account: account.keychainAccount)
            } catch {
                throw RemotePushBundleError.credentialUnavailable(.gemini)
            }
            gemini.append(GeminiWire(account: account, apiKey: SecretWire(key.value)))
        }
        return CredentialsWire(claude: claude, chatGPT: chatGPT, gemini: gemini)
    }

    private static func validate(_ accounts: [RemotePushAccountInventory.Account], provider: RemotePushProvider) throws {
        guard accounts.count <= maxAccountsPerProvider else {
            throw RemotePushBundleError.invalidInventory(provider)
        }
        var ids = Set<String>()
        var primaryCount = 0
        for account in accounts {
            guard !account.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(account.id).inserted else {
                throw RemotePushBundleError.invalidInventory(provider)
            }
            if account.isPrimary { primaryCount += 1 }
        }
        guard accounts.isEmpty || primaryCount == 1 else {
            throw RemotePushBundleError.invalidInventory(provider)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct BundleWire: Encodable, Sendable {
    let schemaVersion = SchemaVersionWire(major: 1, minor: 0)
    let generation: UInt64
    let pushedAt: Date
    let credentials: CredentialsWire
    let policy: BrokerPolicy
    let cooldowns: [String: Date]
    let timeZone: String
    let oracleSnapshot: SnapshotWire?
}

private struct SchemaVersionWire: Encodable, Sendable {
    let major: Int
    let minor: Int
}

private struct CredentialsWire: Encodable, Sendable {
    let schemaVersion = 2
    let claude: [ClaudeWire]
    let chatGPT: [ChatGPTWire]
    let gemini: [GeminiWire]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case claude
        case chatGPT = "chatgpt"
        case gemini
    }
}

private struct ClaudeWire: Encodable, Sendable {
    let id: String
    let label: String
    let isPrimary: Bool
    let sessionKey: SecretWire

    init(account: RemotePushAccountInventory.Account, sessionKey: SecretWire) {
        id = account.id
        label = account.label
        isPrimary = account.isPrimary
        self.sessionKey = sessionKey
    }
}

private struct ChatGPTWire: Encodable, Sendable {
    let id: String
    let label: String
    let isPrimary: Bool
    let cookie: SecretWire

    init(account: RemotePushAccountInventory.Account, cookie: SecretWire) {
        id = account.id
        label = account.label
        isPrimary = account.isPrimary
        self.cookie = cookie
    }
}

private struct GeminiWire: Encodable, Sendable {
    let id: String
    let label: String
    let isPrimary: Bool
    let apiKey: SecretWire

    init(account: RemotePushAccountInventory.Account, apiKey: SecretWire) {
        id = account.id
        label = account.label
        isPrimary = account.isPrimary
        self.apiKey = apiKey
    }
}

private struct SecretWire: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "SecretWire(<redacted>)" }
}

private struct SnapshotWire: Encodable, Sendable {
    let schemaVersion = 1
    let pushedAt: Date
    let timeZone: String
    let oracle: OracleWire
}

private struct OracleWire: Encodable, Sendable {
    struct AccountWire: Encodable, Sendable {
        let id: String
        let label: String
        let isPrimary: Bool
        let lastUpdated: Date?
        let state: String
        let session: Double?
        let weekly: Double?
        let sonnet: Double?
        let fable: Double?
        let sessionResetAt: Date?
        let weeklyResetAt: Date?
        let sonnetResetAt: Date?
        let fableResetAt: Date?

        init(_ row: OracleSnapshot.AccountRow) {
            id = row.id
            label = row.label
            isPrimary = row.isPrimary
            lastUpdated = row.lastUpdated
            state = row.state.rawValue
            session = row.session
            weekly = row.weekly
            sonnet = row.sonnet
            fable = row.fable
            sessionResetAt = row.sessionResetAt
            weeklyResetAt = row.weeklyResetAt
            sonnetResetAt = row.sonnetResetAt
            fableResetAt = row.fableResetAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, isPrimary, lastUpdated, state
            case session, weekly, sonnet, fable
            case sessionResetAt, weeklyResetAt, sonnetResetAt, fableResetAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(isPrimary, forKey: .isPrimary)
            try container.encode(lastUpdated, forKey: .lastUpdated)
            try container.encode(state, forKey: .state)
            try container.encode(session, forKey: .session)
            try container.encode(weekly, forKey: .weekly)
            try container.encode(sonnet, forKey: .sonnet)
            try container.encode(fable, forKey: .fable)
            try container.encode(sessionResetAt, forKey: .sessionResetAt)
            try container.encode(weeklyResetAt, forKey: .weeklyResetAt)
            try container.encode(sonnetResetAt, forKey: .sonnetResetAt)
            try container.encode(fableResetAt, forKey: .fableResetAt)
        }
    }

    let generatedAt: Date
    let accounts: [AccountWire]
    let chatGPTState: String
    let chatGPTRows: [OracleSnapshot.ChatGPTRow]
    let chatGPTLastUpdated: Date?
    let chatGPTConfigured: Bool

    init(_ snapshot: OracleSnapshot) {
        generatedAt = snapshot.generatedAt
        accounts = snapshot.accounts.map(AccountWire.init)
        chatGPTState = snapshot.chatGPTState.rawValue
        chatGPTRows = snapshot.chatGPTRows
        chatGPTLastUpdated = snapshot.chatGPTLastUpdated
        chatGPTConfigured = snapshot.chatGPTConfigured
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, accounts, chatGPTState, chatGPTRows
        case chatGPTLastUpdated, chatGPTConfigured
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(chatGPTState, forKey: .chatGPTState)
        try container.encode(chatGPTRows, forKey: .chatGPTRows)
        try container.encode(chatGPTLastUpdated, forKey: .chatGPTLastUpdated)
        try container.encode(chatGPTConfigured, forKey: .chatGPTConfigured)
    }
}
