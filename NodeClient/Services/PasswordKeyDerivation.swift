//  PasswordKeyDerivation.
//
//  Deriva una SymmetricKey de 256 bits a partir de una contraseña usuario
//  + salt + iteraciones, usando PBKDF2 SHA-256 vía CommonCrypto.

import CommonCrypto
import CryptoKit
import Foundation

enum PasswordKeyDerivationError: Error, Equatable {
    case derivationFailed
    case invalidParameters
}

protocol PasswordKeyDerivationProtocol {
    func deriveKey(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey
}

struct PasswordKeyDerivation: PasswordKeyDerivationProtocol {
    /// Iteraciones por defecto. OWASP 2023 recomienda 600k para SHA-256
    /// en uso interactivo (login, unlock).
    static let defaultIterations: UInt32 = 600_000
    static let saltLength = 16
    static let keyLength = 32 // 256 bits para AES-GCM 256

    /// Deriva una SymmetricKey de 256 bits.
    func deriveKey(
        password: String,
        salt: Data,
        iterations: UInt32 = defaultIterations
    ) throws -> SymmetricKey {
        guard !password.isEmpty,
              salt.count == Self.saltLength,
              iterations > 0 else {
            throw PasswordKeyDerivationError.invalidParameters
        }

        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordKeyDerivationError.invalidParameters
        }

        var derivedBytes = [UInt8](repeating: 0, count: Self.keyLength)

        let status = passwordData.withUnsafeBytes { passwordPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                guard let pwdAddr = passwordPtr.bindMemory(to: Int8.self).baseAddress,
                      let saltAddr = saltPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdAddr,
                    passwordData.count,
                    saltAddr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derivedBytes,
                    Self.keyLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw PasswordKeyDerivationError.derivationFailed
        }

        return SymmetricKey(data: Data(derivedBytes))
    }

    /// Genera salt random de 16 bytes.
    static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}
