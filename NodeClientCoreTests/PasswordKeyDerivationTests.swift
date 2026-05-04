//  Tests TDD PasswordKeyDerivation (PBKDF2 SHA-256).

import CryptoKit
@testable import NodeClientCore
import XCTest

final class PasswordKeyDerivationTests: XCTestCase {
    private let derivation = PasswordKeyDerivation()
    /// Iteraciones reducidas para que los tests no tarden segundos.
    /// El default productivo (600k) se valida en un único test dedicado.
    private let testIterations: UInt32 = 1_000

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    func test_pbkdf2_derivation_isDeterministic() throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let key1 = try derivation.deriveKey(password: "correct horse", salt: salt, iterations: testIterations)
        let key2 = try derivation.deriveKey(password: "correct horse", salt: salt, iterations: testIterations)

        XCTAssertEqual(keyData(key1), keyData(key2))
    }

    func test_pbkdf2_differentSalts_produceDifferentKeys() throws {
        let salt1 = PasswordKeyDerivation.generateSalt()
        let salt2 = PasswordKeyDerivation.generateSalt()

        let key1 = try derivation.deriveKey(password: "same password", salt: salt1, iterations: testIterations)
        let key2 = try derivation.deriveKey(password: "same password", salt: salt2, iterations: testIterations)

        XCTAssertNotEqual(salt1, salt2)
        XCTAssertNotEqual(keyData(key1), keyData(key2))
    }

    func test_pbkdf2_differentPasswords_produceDifferentKeys() throws {
        let salt = PasswordKeyDerivation.generateSalt()

        let key1 = try derivation.deriveKey(password: "password-A", salt: salt, iterations: testIterations)
        let key2 = try derivation.deriveKey(password: "password-B", salt: salt, iterations: testIterations)

        XCTAssertNotEqual(keyData(key1), keyData(key2))
    }

    func test_pbkdf2_emptyPassword_throws() {
        let salt = PasswordKeyDerivation.generateSalt()

        XCTAssertThrowsError(try derivation.deriveKey(password: "", salt: salt, iterations: testIterations)) { error in
            XCTAssertEqual(error as? PasswordKeyDerivationError, .invalidParameters)
        }
    }

    func test_pbkdf2_invalidSaltLength_throws() {
        let badSalt = Data([0x00, 0x01]) // solo 2 bytes
        XCTAssertThrowsError(try derivation.deriveKey(password: "x", salt: badSalt, iterations: testIterations)) { error in
            XCTAssertEqual(error as? PasswordKeyDerivationError, .invalidParameters)
        }
    }

    func test_generateSalt_isCorrectLength() {
        let salt = PasswordKeyDerivation.generateSalt()
        XCTAssertEqual(salt.count, PasswordKeyDerivation.saltLength)
    }

    func test_generateSalt_isRandom() {
        let s1 = PasswordKeyDerivation.generateSalt()
        let s2 = PasswordKeyDerivation.generateSalt()
        XCTAssertNotEqual(s1, s2)
    }
}
