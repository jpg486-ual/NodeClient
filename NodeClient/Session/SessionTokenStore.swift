import Foundation
import Security

protocol SessionTokenStore {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
    /// Username asociado a la sesión activa. Persistido junto al token
    /// para que procesos sandboxed puedan
    /// resolverlo sin depender del shared UserDefaults — éste falla
    /// silenciosamente en algunos setups de signing/sandbox macOS aunque
    /// el keychain con el mismo access group sí funcione.
    func readUsername() throws -> String?
    func writeUsername(_ username: String) throws
    func deleteUsername() throws
}

enum SessionTokenStoreError: Error, Equatable {
    case encodingFailed
    case keychain(OSStatus)
}

extension SessionTokenStore {
    /// Default no-op para mocks de tests que no necesitan tracking de
    /// username. La implementación real de `KeychainSessionTokenStore`
    /// override estos métodos para persistir el username junto al token.
    func readUsername() throws -> String? { nil }
    func writeUsername(_ username: String) throws {}
    func deleteUsername() throws {}
}

struct KeychainSessionTokenStore: SessionTokenStore {
    init(
        service: String = "es.ual.nodeclient",
        account: String = "sessionToken",
        usernameAccount: String = "sessionUsername",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.usernameAccount = usernameAccount
        self.accessGroup = accessGroup
    }

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)

        case errSecItemNotFound:
            return nil

        default:
            throw SessionTokenStoreError.keychain(status)
        }
    }

    func writeToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw SessionTokenStoreError.encodingFailed
        }

        try deleteToken()

        var attributes = baseQuery
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionTokenStoreError.keychain(status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionTokenStoreError.keychain(status)
        }
    }

    func readUsername() throws -> String? {
        var query = usernameBaseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)

        case errSecItemNotFound:
            return nil

        default:
            throw SessionTokenStoreError.keychain(status)
        }
    }

    func writeUsername(_ username: String) throws {
        guard let data = username.data(using: .utf8) else {
            throw SessionTokenStoreError.encodingFailed
        }
        try deleteUsername()
        var attributes = usernameBaseQuery
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionTokenStoreError.keychain(status)
        }
    }

    func deleteUsername() throws {
        let status = SecItemDelete(usernameBaseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionTokenStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        buildQuery(account: account)
    }

    private var usernameBaseQuery: [String: Any] {
        buildQuery(account: usernameAccount)
    }

    private func buildQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Hook expuesto al test target via `@testable import` para
    /// inspeccionar la query construida sin tocar Keychain real.
    var testHookBaseQuery: [String: Any] {
        baseQuery
    }

    /// Espejo del parámetro `accessGroup` configurado en init.
    var testHookAccessGroup: String? {
        accessGroup
    }

    private let service: String
    private let account: String
    private let usernameAccount: String
    private let accessGroup: String?
}
