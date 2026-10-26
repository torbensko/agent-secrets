import Foundation
import Security

/// Thin wrapper over the Security framework for the app's generic password items.
///
/// Every item uses a service of `com.torbensko.secrets.<kind>` and a UUID account. In iCloud mode items
/// live in the data protection keychain and are synchronizable. When the binary isn't signed with the
/// keychain entitlement (e.g. an unsigned local build), it falls back to the login keychain on this Mac.
struct Keychain: Sendable {
    enum Mode: String, Sendable {
        case iCloud
        case local
    }

    enum Kind: String, Sendable {
        case project
        case service
        case credential
        case secret
        case probe
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        let operation: String

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "\(operation) failed: \(message) (\(status))"
        }
    }

    static let defaultServicePrefix = "com.torbensko.secrets"

    let mode: Mode
    let servicePrefix: String

    init(mode: Mode, servicePrefix: String = Keychain.defaultServicePrefix) {
        self.mode = mode
        self.servicePrefix = servicePrefix
    }

    static func detect(servicePrefix: String = Keychain.defaultServicePrefix) -> Keychain {
        // Reads can succeed without the entitlement, so probe with a write.
        let iCloud = Keychain(mode: .iCloud, servicePrefix: servicePrefix)
        let account = "probe-\(UUID().uuidString)"
        do {
            try iCloud.set(Data(), kind: .probe, account: account, label: "Agent Secrets keychain check")
            try? iCloud.delete(kind: .probe, account: account)
            return iCloud
        } catch let failure as Failure where failure.status == errSecMissingEntitlement {
            return Keychain(mode: .local, servicePrefix: servicePrefix)
        } catch {
            return iCloud
        }
    }

    func set(_ data: Data, kind: Kind, account: String, label: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]
        var status = SecItemUpdate(
            query(kind, account: account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = query(kind, account: account, synchronizable: kCFBooleanTrue!)
            add.merge(attributes) { $1 }
            if mode == .iCloud {
                // Readable while the screen is locked, so overnight agent runs aren't blocked.
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status, operation: "Saving to the Keychain") }
    }

    func data(kind: Kind, account: String) throws -> Data? {
        var query = query(kind, account: account, synchronizable: kSecAttrSynchronizableAny)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status, operation: "Reading from the Keychain") }
        return result as? Data
    }

    /// Accounts of every item of a kind, read from attributes only.
    func accounts(kind: Kind) throws -> [String] {
        var query = query(kind, synchronizable: kSecAttrSynchronizableAny)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure(status: status, operation: "Reading from the Keychain") }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func allData(kind: Kind) throws -> [String: Data] {
        var all: [String: Data] = [:]
        for account in try accounts(kind: kind) {
            all[account] = try data(kind: kind, account: account)
        }
        return all
    }

    func delete(kind: Kind, account: String) throws {
        let status = SecItemDelete(query(kind, account: account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status, operation: "Deleting from the Keychain")
        }
    }

    private func query(_ kind: Kind, account: String? = nil, synchronizable: CFTypeRef) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(kind.rawValue)",
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if mode == .iCloud {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = synchronizable
        }
        return query
    }
}
