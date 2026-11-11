import Foundation
import Security

/// Where the private key lives.
protocol IdentityKeyStore: Sendable {
    /// `nil` when no key has been stored yet. Throws when the store exists but cannot be read.
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
}

enum KeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case file(String)
}

/// The login keychain. Used for the default profile.
struct KeychainKeyStore: IdentityKeyStore {
    var service = "com.kadaliao.notchfax.fax-identity"
    var account: String
    var label = "Notchfax 传真身份"

    func loadKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeyStoreError.keychain(status)
        }
    }

    func saveKey(_ key: Data) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: "Notchfax 匿名传真用的设备密钥",
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }
}

/// A file readable only by this user. Used for named `--fax-profile` debug profiles,
/// so that several instances can run unattended without keychain prompts.
struct FileKeyStore: IdentityKeyStore {
    var url: URL

    func loadKey() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw KeyStoreError.file(error.localizedDescription)
        }
    }

    func saveKey(_ key: Data) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw KeyStoreError.file(error.localizedDescription)
        }
        // Created with owner-only permissions from the start, never world-readable.
        guard FileManager.default.createFile(atPath: url.path, contents: key, attributes: [.posixPermissions: 0o600]) else {
            throw KeyStoreError.file("could not write \(url.lastPathComponent)")
        }
    }
}

extension DeviceIdentity {
    /// Reads the key, or creates and stores one on first use. A store that exists but
    /// cannot be read is an error: silently minting a new identity would orphan every line.
    static func loadOrCreate(from store: any IdentityKeyStore) throws -> DeviceIdentity {
        if let raw = try store.loadKey() {
            return try DeviceIdentity(privateKeyRaw: raw)
        }
        let identity = DeviceIdentity.generate()
        try store.saveKey(identity.privateKeyRaw)
        return identity
    }
}
