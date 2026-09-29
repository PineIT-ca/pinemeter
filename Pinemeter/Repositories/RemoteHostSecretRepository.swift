import Foundation
import Security

struct RemoteHostSecret: Equatable, Sendable {
    let identity: Data
    let pinnedHostKey: String
}

protocol RemoteHostKeychainOperations: Sendable {
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func copy(service: String, account: String) -> (OSStatus, Data?)
    func delete(service: String, account: String) -> OSStatus
}

struct SystemRemoteHostKeychainOperations: RemoteHostKeychainOperations {
    func update(service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

enum RemoteHostSecretRepositoryError: LocalizedError, Equatable {
    case secureStorageFailure
    case secretNotFound
    case invalidStoredSecret

    var errorDescription: String? {
        switch self {
        case .secureStorageFailure: "Could not store the remote host credentials."
        case .secretNotFound: "Remote host credentials were not found."
        case .invalidStoredSecret: "Remote host credentials are invalid."
        }
    }
}

actor RemoteHostSecretRepository {
    private static let identityService = "ca.pineit.pinemeter.remote-host.identity"
    private static let pinService = "ca.pineit.pinemeter.remote-host.pin"
    private let operations: any RemoteHostKeychainOperations

    init(operations: any RemoteHostKeychainOperations = SystemRemoteHostKeychainOperations()) {
        self.operations = operations
    }

    func configureHost(
        host: String,
        sshUser: String,
        keyPath: String,
        pinnedHostKey: String,
        settingsRepository: any SettingsRepositoryProtocol,
        id: UUID = UUID()
    ) async throws -> RemoteHost {
        let normalizedHost = try RemoteHostValidator.normalizedHost(host)
        let normalizedUser = try RemoteHostValidator.normalizedSSHUser(sshUser)
        let settings = await settingsRepository.load()
        guard try !RemoteHostValidator.isDuplicate(
            host: normalizedHost,
            sshUser: normalizedUser,
            among: settings.broker.remoteHosts
        ) else { throw RemoteHostValidationError.duplicateHost }
        let identity = try RemoteHostValidator.readPrivateKey(at: keyPath)
        let pin = try RemoteHostValidator.parsePinnedHostKey(pinnedHostKey)
        let reference = id.uuidString.lowercased()

        try save(identity, service: Self.identityService, account: reference)
        do {
            try save(Data(pin.record.utf8), service: Self.pinService, account: reference)
            var updated = settings
            let row = RemoteHost(
                id: id,
                host: normalizedHost,
                sshUser: normalizedUser,
                keyPath: keyPath,
                secretReference: reference,
                pinnedHostKeyFingerprint: pin.fingerprint
            )
            updated.broker.remoteHosts.append(row)
            try await settingsRepository.save(updated)
            return row
        } catch {
            deleteIgnoringMissing(reference: reference)
            throw error
        }
    }

    func load(reference: String) throws -> RemoteHostSecret {
        let (identityStatus, identity) = operations.copy(
            service: Self.identityService, account: reference
        )
        let (pinStatus, pin) = operations.copy(service: Self.pinService, account: reference)
        guard identityStatus == errSecSuccess, pinStatus == errSecSuccess,
              let identity, let pin, let pinnedHostKey = String(data: pin, encoding: .utf8)
        else {
            if identityStatus == errSecItemNotFound || pinStatus == errSecItemNotFound {
                throw RemoteHostSecretRepositoryError.secretNotFound
            }
            throw RemoteHostSecretRepositoryError.invalidStoredSecret
        }
        return RemoteHostSecret(identity: identity, pinnedHostKey: pinnedHostKey)
    }

    func delete(reference: String) throws {
        for service in [Self.identityService, Self.pinService] {
            let status = operations.delete(service: service, account: reference)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw RemoteHostSecretRepositoryError.secureStorageFailure
            }
        }
    }

    private func save(_ data: Data, service: String, account: String) throws {
        let updateStatus = operations.update(service: service, account: account, data: data)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteHostSecretRepositoryError.secureStorageFailure
        }
        let addStatus = operations.add(service: service, account: account, data: data)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem,
           operations.update(service: service, account: account, data: data) == errSecSuccess {
            return
        }
        throw RemoteHostSecretRepositoryError.secureStorageFailure
    }

    private func deleteIgnoringMissing(reference: String) {
        _ = operations.delete(service: Self.identityService, account: reference)
        _ = operations.delete(service: Self.pinService, account: reference)
    }
}
