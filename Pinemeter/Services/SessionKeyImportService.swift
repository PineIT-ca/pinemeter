import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import os
import Security
import SQLite3
import SweetCookieKit

/// Imports Claude session keys from local browser cookies.
actor SessionKeyImportService: SessionKeyImportServiceProtocol {
    private static let logger = Logger(subsystem: "com.pinemeter", category: "SessionKeyImportService")

    private let cookieClient: BrowserCookieClient
    private let browserImportOrder: [Browser]
    private let keychainRepository: KeychainRepositoryProtocol

    init(
        cookieClient: BrowserCookieClient = BrowserCookieClient(),
        browserImportOrder: [Browser] = Browser.defaultImportOrder,
        keychainRepository: KeychainRepositoryProtocol = KeychainRepository()
    ) {
        self.cookieClient = cookieClient
        self.browserImportOrder = browserImportOrder
        self.keychainRepository = keychainRepository
    }

    func importSessionKey() async throws -> ImportedSessionKey {
        try await importSessionKey(from: .defaultBrowser)
    }

    func importSessionKey(from source: BrowserImportSource) async throws -> ImportedSessionKey {
        let query = BrowserCookieQuery(domains: ["claude.ai"], domainMatch: .suffix)
        var sawAccessDenied = false
        var sawSafariAccessDenied = false
        var deniedKeychainBrowserName: String?

        for browser in browsers(for: source) {
            do {
                let sources = try cookieClient.records(matching: query, in: browser)
                for source in sources {
                    if let imported = try importedSessionKey(from: source) {
                        return imported
                    }
                }
            } catch let error as BrowserCookieError {
                switch error {
                case .accessDenied:
                    sawAccessDenied = true
                    if browser == .safari {
                        sawSafariAccessDenied = true
                    } else if browser.usesKeychainForCookieDecryption {
                        deniedKeychainBrowserName = browser.displayName
                    }
                case .notFound, .loadFailed:
                    break
                }
            }
        }

        if sawSafariAccessDenied {
            throw SessionKeyImportError.safariAccessDenied
        }
        if let deniedKeychainBrowserName {
            throw SessionKeyImportError.browserKeychainAccessDenied(deniedKeychainBrowserName)
        }
        if sawAccessDenied {
            throw SessionKeyImportError.accessDenied
        }
        throw SessionKeyImportError.noSessionKeyFound
    }

    func importAllSessionKeys(from source: BrowserImportSource) async throws -> [ImportedSessionKey] {
        let query = BrowserCookieQuery(domains: ["claude.ai"], domainMatch: .suffix)
        var imported: [ImportedSessionKey] = []
        var seenValues = Set<String>()
        var sawAccessDenied = false
        var sawSafariAccessDenied = false
        var deniedKeychainBrowserName: String?

        for browser in browsers(for: source) {
            do {
                let sources = try cookieClient.records(matching: query, in: browser)
                Self.logger.info("importAllSessionKeys(\(browser.displayName, privacy: .public)): \(sources.count) cookie store(s): \(sources.map(\.label).joined(separator: ", "), privacy: .public)")
                for storeRecords in sources {
                    // Skip a malformed cookie in one profile rather than aborting
                    // discovery for the remaining profiles.
                    guard let one = try? importedSessionKey(from: storeRecords) else {
                        let hasCookie = storeRecords.records.contains { $0.name == "sessionKey" }
                        Self.logger.info("Store \(storeRecords.label, privacy: .public): \(hasCookie ? "sessionKey cookie present but malformed" : "no sessionKey cookie", privacy: .public)")
                        continue
                    }
                    if seenValues.insert(one.value).inserted {
                        Self.logger.info("Store \(storeRecords.label, privacy: .public): found session key")
                        imported.append(one)
                    } else {
                        Self.logger.info("Store \(storeRecords.label, privacy: .public): duplicate session key value, skipping")
                    }
                }
            } catch let error as BrowserCookieError {
                switch error {
                case .accessDenied:
                    sawAccessDenied = true
                    if browser == .safari {
                        sawSafariAccessDenied = true
                    } else if browser.usesKeychainForCookieDecryption {
                        deniedKeychainBrowserName = browser.displayName
                    }
                case .notFound, .loadFailed:
                    break
                }
            }
        }

        if !imported.isEmpty {
            return imported
        }

        if sawSafariAccessDenied {
            throw SessionKeyImportError.safariAccessDenied
        }
        if let deniedKeychainBrowserName {
            throw SessionKeyImportError.browserKeychainAccessDenied(deniedKeychainBrowserName)
        }
        if sawAccessDenied {
            throw SessionKeyImportError.accessDenied
        }
        throw SessionKeyImportError.noSessionKeyFound
    }

    func importChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        try await importChatGPTSessionCookie(from: .defaultBrowser)
    }

    func importChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        let query = BrowserCookieQuery(domains: ["chatgpt.com", "chat.openai.com"], domainMatch: .suffix)
        var sawAccessDenied = false
        var sawSafariAccessDenied = false
        var deniedKeychainBrowserName: String?

        for browser in browsers(for: source) {
            do {
                let sources = try cookieClient.records(matching: query, in: browser)
                for source in sources {
                    if let imported = importedChatGPTSessionCookie(from: source) {
                        return imported
                    }
                }
            } catch let error as BrowserCookieError {
                switch error {
                case .accessDenied:
                    sawAccessDenied = true
                    if browser == .safari {
                        sawSafariAccessDenied = true
                    } else if browser.usesKeychainForCookieDecryption {
                        deniedKeychainBrowserName = browser.displayName
                    }
                case .notFound, .loadFailed:
                    break
                }
            }
        }

        if sawSafariAccessDenied {
            throw SessionKeyImportError.safariAccessDenied
        }
        if let deniedKeychainBrowserName {
            throw SessionKeyImportError.browserKeychainAccessDenied(deniedKeychainBrowserName)
        }
        if let imported = ChatGPTChromiumCookieFallbackImporter.importSessionCookie(from: browsers(for: source)) {
            return imported
        }

        if sawAccessDenied {
            throw SessionKeyImportError.accessDenied
        }
        throw SessionKeyImportError.noChatGPTSessionCookieFound
    }

    func repairSavedSessionKey(account: String) async -> CredentialState {
        let identity = CredentialIdentity(provider: .claude, kind: .sessionKey)
        let checkedAt = Date()

        do {
            let existingValue = try await keychainRepository.retrieve(account: account)
            let sessionKey = try SessionKey(existingValue)

            _ = try await keychainRepository.repairClaudeSessionKey(sessionKey.value, account: account)

            return CredentialState(identity: identity, health: .valid, checkedAt: checkedAt)
        } catch is SessionKeyError {
            return CredentialState(
                identity: identity,
                health: .invalid,
                failureCategory: .invalidFormat,
                checkedAt: checkedAt
            )
        } catch KeychainError.notFound {
            return CredentialState(
                identity: identity,
                health: .missing,
                failureCategory: .missing,
                checkedAt: checkedAt
            )
        } catch is KeychainError {
            Self.logger.error("Claude session key repair failed with sanitized Keychain storage error")
            return CredentialState(
                identity: identity,
                health: .unavailable,
                failureCategory: .storageUnavailable,
                checkedAt: checkedAt
            )
        } catch {
            Self.logger.error("Claude session key repair failed with sanitized unknown error")
            return CredentialState(
                identity: identity,
                health: .unavailable,
                failureCategory: .unknown,
                checkedAt: checkedAt
            )
        }
    }

    private func browsers(for source: BrowserImportSource) -> [Browser] {
        switch source {
        case .defaultBrowser:
            if let defaultBrowser = defaultWebBrowser() {
                return [defaultBrowser] + browserImportOrder.filter { $0 != defaultBrowser }
            }
            return browserImportOrder
        case .chrome:
            return [.chrome]
        case .safari:
            return [.safari]
        case .brave:
            return [.brave]
        case .edge:
            return [.edge]
        case .arc:
            return [.arc]
        case .firefox:
            return [.firefox]
        }
    }

    private func defaultWebBrowser() -> Browser? {
        guard let url = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            return nil
        }

        switch bundleIdentifier {
        case "com.apple.Safari":
            return .safari
        case "com.google.Chrome":
            return .chrome
        case "com.brave.Browser":
            return .brave
        case "com.microsoft.edgemac":
            return .edge
        case "company.thebrowser.Browser":
            return .arc
        case "org.mozilla.firefox":
            return .firefox
        default:
            return nil
        }
    }

    private func importedSessionKey(from source: BrowserCookieStoreRecords) throws -> ImportedSessionKey? {
        guard let cookie = source.records.first(where: { $0.name == "sessionKey" }) else {
            return nil
        }

        let sessionKey = try SessionKey(cookie.value)
        return ImportedSessionKey(
            value: sessionKey.value,
            sourceDescription: source.label
        )
    }

    private func importedChatGPTSessionCookie(from source: BrowserCookieStoreRecords) -> ImportedChatGPTSessionCookie? {
        let cookieHeader = source.records
            .filter { record in
                isChatGPTSessionCookieName(record.name)
            }
            .sorted { lhs, rhs in
                chatGPTSessionCookieSortKey(lhs.name) < chatGPTSessionCookieSortKey(rhs.name)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        let normalizedHeader = ChatGPTUsageService.cookieHeader(from: cookieHeader)
        guard !normalizedHeader.isEmpty else { return nil }

        return ImportedChatGPTSessionCookie(
            cookieHeader: normalizedHeader,
            sourceDescription: source.label
        )
    }

    private func isChatGPTSessionCookieName(_ name: String) -> Bool {
        chatGPTSessionCookieNames.contains { cookieName in
            name == cookieName || name.hasPrefix("\(cookieName).")
        }
    }

    private func chatGPTSessionCookieSortKey(_ name: String) -> Int {
        for cookieName in chatGPTSessionCookieNames {
            let prefix = "\(cookieName)."
            if name == cookieName {
                return -1
            }
            if name.hasPrefix(prefix), let index = Int(name.dropFirst(prefix.count)) {
                return index
            }
        }
        return -1
    }

    private var chatGPTSessionCookieNames: [String] {
        [
            "__Secure-next-auth.session-token",
            "__Secure-authjs.session-token",
        ]
    }
}

struct ChatGPTChromiumCookieFallbackImporter {
    struct BrowserCookie: Equatable {
        let hostKey: String
        let name: String
        let value: String
    }

    private struct CookieStore {
        let browser: Browser
        let profileName: String
        let label: String
        let databaseURL: URL
    }

    static func importSessionCookie(from browsers: [Browser]) -> ImportedChatGPTSessionCookie? {
        for browser in browsers where browser.usesChromiumProfileStore {
            guard let key = chromiumSafeStorageKey(for: browser) else { continue }
            for store in cookieStores(for: browser) {
                let cookies = readableCookies(in: store, key: key)
                guard let cookieHeader = normalizedCookieHeader(from: cookies) else { continue }
                return ImportedChatGPTSessionCookie(
                    cookieHeader: cookieHeader,
                    sourceDescription: store.label
                )
            }
        }
        return nil
    }

    static func normalizedCookieHeader(from cookies: [BrowserCookie]) -> String? {
        let matchingCookies = cookies
            .filter { isChatGPTCookieName($0.name) || $0.name == "oai-did" || $0.name == "oai-sc" || $0.name == "_puid" }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.hostKey < rhs.hostKey }
                return chatGPTCookieSortKey(lhs.name) < chatGPTCookieSortKey(rhs.name)
            }

        let rawHeader = matchingCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        let normalizedHeader = ChatGPTUsageService.cookieHeader(from: rawHeader)
        guard sessionCookieNames.contains(where: { cookieName in
            normalizedHeader.contains("\(cookieName)=")
        }) else {
            return nil
        }
        return normalizedHeader
    }

    static func decodedChromePlaintext(_ plaintext: Data, hostKey: String) -> String? {
        if plaintext.starts(with: hostDigest(for: hostKey)) {
            return String(data: plaintext.dropFirst(32), encoding: .utf8)
        }
        return String(data: plaintext, encoding: .utf8)
    }

    static func hostDigest(for hostKey: String) -> Data {
        Data(SHA256.hash(data: Data(hostKey.utf8)))
    }

    private static let sessionCookieNames = [
        "__Secure-next-auth.session-token",
        "__Secure-authjs.session-token",
    ]

    private static func isChatGPTCookieName(_ name: String) -> Bool {
        sessionCookieNames.contains { cookieName in
            name == cookieName || name.hasPrefix("\(cookieName).")
        }
    }

    private static func chatGPTCookieSortKey(_ name: String) -> Int {
        for (cookieIndex, cookieName) in sessionCookieNames.enumerated() {
            let prefix = "\(cookieName)."
            if name == cookieName { return cookieIndex * 1_000 }
            if name.hasPrefix(prefix), let chunkIndex = Int(name.dropFirst(prefix.count)) {
                return cookieIndex * 1_000 + chunkIndex + 1
            }
        }
        return 10_000
    }

    private static func cookieStores(for browser: Browser) -> [CookieStore] {
        guard let profileRoot = browser.chromiumProfileRelativePath else { return [] }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(profileRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                    return false
                }
                let name = url.lastPathComponent
                return isDirectory && (name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-"))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { profileDirectory -> [CookieStore] in
                let profileName = profileDirectory.lastPathComponent
                let labelBase = "\(browser.displayName) \(profileName)"
                return [
                    CookieStore(
                        browser: browser,
                        profileName: profileName,
                        label: "\(labelBase) (Network)",
                        databaseURL: profileDirectory.appendingPathComponent("Network").appendingPathComponent("Cookies")
                    ),
                    CookieStore(
                        browser: browser,
                        profileName: profileName,
                        label: labelBase,
                        databaseURL: profileDirectory.appendingPathComponent("Cookies")
                    ),
                ]
            }
            .filter { FileManager.default.fileExists(atPath: $0.databaseURL.path) }
    }

    private static func readableCookies(in store: CookieStore, key: Data) -> [BrowserCookie] {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinemeter-chatgpt-cookies-\(UUID().uuidString)", isDirectory: true)
        let copiedDatabase = tempDirectory.appendingPathComponent("Cookies")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: store.databaseURL, to: copiedDatabase)
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: store.databaseURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copiedDatabase.path + suffix))
            }
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            return readCookies(from: copiedDatabase, key: key)
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            return []
        }
    }

    private static func readCookies(from databaseURL: URL, key: Data) -> [BrowserCookie] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT host_key, name, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE '%chatgpt.com%' OR host_key LIKE '%openai.com%'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var cookies: [BrowserCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let hostKey = textColumn(statement, index: 0) ?? ""
            let name = textColumn(statement, index: 1) ?? ""
            let plaintextValue = textColumn(statement, index: 2)
            let encryptedValue = dataColumn(statement, index: 3)

            let value: String?
            if let plaintextValue, !plaintextValue.isEmpty {
                value = plaintextValue
            } else if let encryptedValue, !encryptedValue.isEmpty {
                value = decryptedChromiumValue(encryptedValue, hostKey: hostKey, key: key)
            } else {
                value = nil
            }

            guard let value, !value.isEmpty else { continue }
            cookies.append(BrowserCookie(hostKey: hostKey, name: name, value: value))
        }
        return cookies
    }

    private static func textColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func dataColumn(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    static func decryptedChromiumValue(_ encryptedValue: Data, hostKey: String, key: Data) -> String? {
        guard encryptedValue.count > 3,
              String(data: encryptedValue.prefix(3), encoding: .utf8) == "v10" else {
            return nil
        }
        let payload = encryptedValue.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCapacity = payload.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            payloadBytes.bindMemory(to: UInt8.self).baseAddress,
                            payload.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputLength..<output.count)
        return decodedChromePlaintext(output, hostKey: hostKey)
    }

    private static func chromiumSafeStorageKey(for browser: Browser) -> Data? {
        for label in browser.safeStorageLabels {
            guard let password = keychainPassword(service: label.service, account: label.account) else { continue }
            return deriveChromiumKey(from: password)
        }
        return nil
    }

    private static func keychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deriveChromiumKey(from password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        let keyLength = kCCKeySizeAES128
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return key
    }
}

private extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .yandex,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia,
             .comet:
            return true
        @unknown default:
            return true
        }
    }
}
