import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Where admin keys live. The database stores only a `KeychainRef`.
public protocol Secrets: Sendable {
    func read(_ ref: KeychainRef) throws -> String?
    func write(_ secret: String, for ref: KeychainRef) throws
    func delete(_ ref: KeychainRef) throws
}

/// Test double. Never touches the real Keychain.
public final class InMemorySecrets: Secrets {
    private let store = Mutex<[KeychainRef: String]>([:])

    public init(_ initial: [KeychainRef: String] = [:]) { store.withLock { $0 = initial } }

    public func read(_ ref: KeychainRef) throws -> String? { store.withLock { $0[ref] } }
    public func write(_ secret: String, for ref: KeychainRef) throws { store.withLock { $0[ref] = secret } }
    public func delete(_ ref: KeychainRef) throws { store.withLock { $0[ref] = nil } }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: Int32
    public var description: String { "Keychain error \(status)" }
}

#if canImport(Security)
/// The real file-based (login) keychain: generic password, service `dev.meter.app`, account = org id.
/// No access group and no `kSecAttrAccessible`, as RESEARCH.md section 11 recommends for an ad-hoc or
/// self-signed app. Not exercised by tests.
public struct KeychainSecrets: Secrets {
    public init() {}

    private func base(_ ref: KeychainRef) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: ref.service, kSecAttrAccount: ref.account]
    }

    public func read(_ ref: KeychainRef) throws -> String? {
        var q = base(ref)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, for ref: KeychainRef) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(base(ref) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = base(ref)
        add[kSecValueData] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ ref: KeychainRef) throws {
        let status = SecItemDelete(base(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
