//  Persiste salt + verifier + iterations + token PBKDF2 en Keychain.
//  El token (passphrase generado por la app, base64 de 32 bytes random)
//  se guarda opcionalmente para auto-unlock al abrir la app y para poder
//  re-exportarlo a otro dispositivo. Sin token, el verifier sólo sirve
//  para validar la passphrase introducida vía importar archivo.

import CryptoKit
import Foundation
import Security

protocol EncryptionPasswordStore {
    func readSalt(forUsername username: String) throws -> Data?
    func writeSalt(_ salt: Data, forUsername username: String) throws
    func readVerifier(forUsername username: String) throws -> Data?
    func writeVerifier(_ verifier: Data, forUsername username: String) throws
    func readIterations(forUsername username: String) throws -> UInt32?
    func writeIterations(_ iterations: UInt32, forUsername username: String) throws
    func readToken(forUsername username: String) throws -> String?
    func writeToken(_ token: String, forUsername username: String) throws
    func deleteToken(forUsername username: String) throws
    func reset(forUsername username: String) throws
}

enum EncryptionPasswordStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encodingFailed
}

struct KeychainEncryptionPasswordStore: EncryptionPasswordStore {
    static let defaultService = "es.ual.NodeClient.encryption"

    init(
        service: String = Self.defaultService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func readSalt(forUsername username: String) throws -> Data? {
        try readData(account: "\(username):salt")
    }

    func writeSalt(_ salt: Data, forUsername username: String) throws {
        try writeData(salt, account: "\(username):salt")
    }

    func readVerifier(forUsername username: String) throws -> Data? {
        try readData(account: "\(username):verifier")
    }

    func writeVerifier(_ verifier: Data, forUsername username: String) throws {
        try writeData(verifier, account: "\(username):verifier")
    }

    func readIterations(forUsername username: String) throws -> UInt32? {
        guard let data = try readData(account: "\(username):iterations"),
              let str = String(data: data, encoding: .utf8),
              let value = UInt32(str) else {
            return nil
        }
        return value
    }

    func writeIterations(_ iterations: UInt32, forUsername username: String) throws {
        guard let data = "\(iterations)".data(using: .utf8) else {
            throw EncryptionPasswordStoreError.encodingFailed
        }
        try writeData(data, account: "\(username):iterations")
    }

    func readToken(forUsername username: String) throws -> String? {
        guard let data = try readData(account: "\(username):token"),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    func writeToken(_ token: String, forUsername username: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw EncryptionPasswordStoreError.encodingFailed
        }
        try writeData(data, account: "\(username):token")
    }

    func deleteToken(forUsername username: String) throws {
        try delete(account: "\(username):token")
    }

    func reset(forUsername username: String) throws {
        try delete(account: "\(username):salt")
        try delete(account: "\(username):verifier")
        try delete(account: "\(username):iterations")
        try delete(account: "\(username):token")
    }

    private func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data

        case errSecItemNotFound:
            return nil

        default:
            throw EncryptionPasswordStoreError.keychain(status)
        }
    }

    private func writeData(_ data: Data, account: String) throws {
        try delete(account: account)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionPasswordStoreError.keychain(status)
        }
    }

    private func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionPasswordStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
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

    private let service: String
    private let accessGroup: String?
}

// MARK: - Coordinator

/// Token de cifrado generado por la app: passphrase aleatoria con
/// 256 bits de entropía. Se codifica en base64 (~43 caracteres) y
/// se trata internamente como una "contraseña" de cara a PBKDF2.
struct GeneratedEncryptionToken: Equatable {
    let token: String
    let salt: Data
    let iterations: UInt32
}

/// Bundle exportable a un archivo para configurar el cifrado en otro
/// dispositivo. JSON serializable; el formato lleva un version tag para
/// permitir evoluciones futuras sin romper compatibilidad.
struct EncryptionTokenBundle: Codable, Equatable {
    static let currentVersion: Int = 1

    let version: Int
    let token: String
    let salt: String
    let iterations: UInt32

    init(token: GeneratedEncryptionToken) {
        self.version = Self.currentVersion
        self.token = token.token
        self.salt = token.salt.base64EncodedString()
        self.iterations = token.iterations
    }

    func toGeneratedToken() throws -> GeneratedEncryptionToken {
        guard version == Self.currentVersion else {
            throw EncryptionPasswordCoordinator.ImportError.unsupportedVersion(version)
        }
        guard let saltData = Data(base64Encoded: salt), saltData.count == PasswordKeyDerivation.saltLength else {
            throw EncryptionPasswordCoordinator.ImportError.malformedBundle
        }
        return GeneratedEncryptionToken(token: token, salt: saltData, iterations: iterations)
    }
}

struct EncryptionPasswordCoordinator {
    let derivation: PasswordKeyDerivationProtocol
    let store: EncryptionPasswordStore

    /// Magic canary que se cifra con la key derivada como verifier.
    /// Permite validar el token sin tocar archivos del usuario.
    static let canaryPlaintext = Data("nodeclient-canary-v1".utf8)

    /// Bytes de entropía del token generado. 32 bytes = 256 bits.
    static let tokenEntropyBytes = 32

    enum SetupError: Error, Equatable {
        case alreadyConfigured
        case storeFailed
    }

    enum UnlockError: Error, Equatable {
        case notConfigured
        case tokenNotStored
        case incorrectToken
        case storeFailed
    }

    enum ImportError: Error, Equatable {
        case malformedBundle
        case unsupportedVersion(Int)
        case storeFailed
    }

    /// Genera un token nuevo, lo configura en el dispositivo y devuelve
    /// los parámetros (incluido el plain token) para que el caller pueda
    /// presentarlo y/o exportarlo. El token se persiste en Keychain solo
    /// si `persistToken` es true (default — auto-unlock futuro).
    func generateAndConfigureToken(
        forUsername username: String,
        persistToken: Bool,
        iterations: UInt32 = PasswordKeyDerivation.defaultIterations
    ) throws -> (key: SymmetricKey, generated: GeneratedEncryptionToken) {
        if case .some(.some) = try? store.readVerifier(forUsername: username) {
            throw SetupError.alreadyConfigured
        }
        let token = Self.generateRandomToken()
        let salt = PasswordKeyDerivation.generateSalt()
        let key = try persistSetup(
            token: token,
            salt: salt,
            iterations: iterations,
            persistToken: persistToken,
            forUsername: username
        )
        return (key, GeneratedEncryptionToken(token: token, salt: salt, iterations: iterations))
    }

    /// Importa un token desde otro dispositivo y configura el cifrado
    /// con sus parámetros exactos (mismo salt + iteraciones → misma key
    /// derivada → archivos ya cifrados quedan desencriptables aquí).
    func importToken(
        _ generated: GeneratedEncryptionToken,
        forUsername username: String,
        persistToken: Bool
    ) throws -> SymmetricKey {
        if case .some(.some) = try? store.readVerifier(forUsername: username) {
            throw SetupError.alreadyConfigured
        }
        return try persistSetup(
            token: generated.token,
            salt: generated.salt,
            iterations: generated.iterations,
            persistToken: persistToken,
            forUsername: username
        )
    }

    /// Auto-unlock leyendo el token persistido en Keychain y derivando
    /// la key con el salt+iterations almacenados. Falla si falta cualquier
    /// pieza o si el verifier no cuadra (improbable, indica corrupción).
    func unlockFromStoredToken(forUsername username: String) throws -> SymmetricKey {
        guard let salt = try store.readSalt(forUsername: username),
              let verifier = try store.readVerifier(forUsername: username),
              let iterations = try store.readIterations(forUsername: username) else {
            throw UnlockError.notConfigured
        }
        guard let token = try store.readToken(forUsername: username) else {
            throw UnlockError.tokenNotStored
        }
        let key = try derivation.deriveKey(password: token, salt: salt, iterations: iterations)
        // Verifier check: descifra el canary in-line con AES-GCM. El
        // formato persistido es el `combined` de `AES.GCM.SealedBox`
        // (nonce || ciphertext || tag). Si la key derivada no coincide,
        // `AES.GCM.open` lanza y se traduce a `incorrectToken`.
        do {
            let sealed = try AES.GCM.SealedBox(combined: verifier)
            let recovered = try AES.GCM.open(sealed, using: key)
            guard recovered == Self.canaryPlaintext else {
                throw UnlockError.incorrectToken
            }
            return key
        } catch {
            throw UnlockError.incorrectToken
        }
    }

    /// Devuelve el bundle exportable si el token está persistido en este
    /// dispositivo. Si no está, el caller no puede re-exportar — debería
    /// haber exportado el archivo en el momento de la generación.
    func exportableBundle(forUsername username: String) throws -> EncryptionTokenBundle? {
        guard let token = try store.readToken(forUsername: username),
              let salt = try store.readSalt(forUsername: username),
              let iterations = try store.readIterations(forUsername: username) else {
            return nil
        }
        return EncryptionTokenBundle(token: GeneratedEncryptionToken(
            token: token,
            salt: salt,
            iterations: iterations
        ))
    }

    func reset(forUsername username: String) throws {
        do {
            try store.reset(forUsername: username)
        } catch {
            throw UnlockError.storeFailed
        }
    }

    // MARK: - Internals

    private func persistSetup(
        token: String,
        salt: Data,
        iterations: UInt32,
        persistToken: Bool,
        forUsername username: String
    ) throws -> SymmetricKey {
        let key = try derivation.deriveKey(password: token, salt: salt, iterations: iterations)
        // Encripta el canary in-line con AES-GCM. El `combined` formato
        // (nonce || ciphertext || tag) es lo que persistimos como
        // verifier; al unlock se reconstruye con `SealedBox(combined:)`.
        let canaryEncrypted: Data
        do {
            let sealed = try AES.GCM.seal(Self.canaryPlaintext, using: key)
            guard let combined = sealed.combined else {
                throw SetupError.storeFailed
            }
            canaryEncrypted = combined
        } catch {
            throw SetupError.storeFailed
        }
        do {
            try store.writeSalt(salt, forUsername: username)
            try store.writeIterations(iterations, forUsername: username)
            try store.writeVerifier(canaryEncrypted, forUsername: username)
            if persistToken {
                try store.writeToken(token, forUsername: username)
            } else {
                try store.deleteToken(forUsername: username)
            }
        } catch {
            try? store.reset(forUsername: username)
            throw SetupError.storeFailed
        }
        return key
    }

    static func generateRandomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenEntropyBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, tokenEntropyBytes, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Migración legacy → shared keychain

    /// One-shot best-effort: si el `legacyStore` (sin access group)
    /// tiene config y el `sharedStore` no la tiene, copia los 4 items
    /// (salt, verifier, iterations, token) al shared. Sin errores —
    /// si algo falla, el usuario re-importa el archivo de token.
    /// Idempotente: si el shared ya tiene verifier, no toca nada.
    static func migrateLegacyToShared(
        username: String,
        legacy: KeychainEncryptionPasswordStore,
        shared: KeychainEncryptionPasswordStore
    ) {
        // Si el shared ya tiene verifier, asumimos migración hecha.
        if (try? shared.readVerifier(forUsername: username)) != nil {
            return
        }
        guard let legacySalt = try? legacy.readSalt(forUsername: username),
              let legacyVerifier = try? legacy.readVerifier(forUsername: username),
              let legacyIterations = try? legacy.readIterations(forUsername: username) else {
            return
        }
        try? shared.writeSalt(legacySalt, forUsername: username)
        try? shared.writeVerifier(legacyVerifier, forUsername: username)
        try? shared.writeIterations(legacyIterations, forUsername: username)
        if let legacyToken = try? legacy.readToken(forUsername: username) {
            try? shared.writeToken(legacyToken, forUsername: username)
        }
    }

    // MARK: - Background-friendly resolver

    /// Variante no-throw de `unlockFromStoredToken` pensada para callers
    /// background que no pueden interrogar al
    /// usuario por una contraseña. Devuelve `nil` si:
    ///   - No hay configuración de cifrado para el username.
    ///   - El token no está persistido (usuario optó por NO guardarlo).
    ///   - Cualquier error de Keychain (acceso denegado, item corrupto).
    /// La extensión usa esto para decidir si cifrar (key != nil) o subir
    /// plaintext (key == nil) en upload, y si descifrar en download.
    func resolveCurrentKey(forUsername username: String) -> SymmetricKey? {
        try? unlockFromStoredToken(forUsername: username)
    }
}
