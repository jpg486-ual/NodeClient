//  Tests del store + coordinator basados en token (post-migración).
//  Usa double in-memory para no tocar Keychain real en suite tests.

import CryptoKit
@testable import NodeClientCore
import XCTest

final class EncryptionPasswordStoreTests: XCTestCase {
    private var store: InMemoryEncryptionPasswordStore!
    private var coordinator: EncryptionPasswordCoordinator!

    override func setUp() {
        super.setUp()
        store = InMemoryEncryptionPasswordStore()
        coordinator = EncryptionPasswordCoordinator(
            derivation: PasswordKeyDerivation(),
            store: store
        )
    }

    // MARK: - Store basics

    func test_writeAndReadSalt_roundtrip() throws {
        let salt = PasswordKeyDerivation.generateSalt()
        try store.writeSalt(salt, forUsername: "alice")

        XCTAssertEqual(try store.readSalt(forUsername: "alice"), salt)
    }

    func test_readSalt_unknownUser_returnsNil() throws {
        XCTAssertNil(try store.readSalt(forUsername: "ghost"))
    }

    func test_writeIterations_isReadableAsInt() throws {
        try store.writeIterations(1_234, forUsername: "alice")
        XCTAssertEqual(try store.readIterations(forUsername: "alice"), 1_234)
    }

    func test_writeAndReadToken_roundtrip() throws {
        try store.writeToken("tok-base64-xyz", forUsername: "alice")
        XCTAssertEqual(try store.readToken(forUsername: "alice"), "tok-base64-xyz")
    }

    func test_deleteToken_removesIt() throws {
        try store.writeToken("tok", forUsername: "alice")
        try store.deleteToken(forUsername: "alice")
        XCTAssertNil(try store.readToken(forUsername: "alice"))
    }

    func test_reset_clearsTokenToo() throws {
        try store.writeToken("tok", forUsername: "alice")
        try store.writeSalt(PasswordKeyDerivation.generateSalt(), forUsername: "alice")
        try store.reset(forUsername: "alice")
        XCTAssertNil(try store.readToken(forUsername: "alice"))
        XCTAssertNil(try store.readSalt(forUsername: "alice"))
    }

    // MARK: - generateAndConfigureToken

    func test_generateAndConfigureToken_persistsAllArtifactsWhenPersistTrue() throws {
        let result = try coordinator.generateAndConfigureToken(
            forUsername: "alice",
            persistToken: true,
            iterations: 1_000
        )

        XCTAssertEqual(result.key.bitCount, 256)
        XCTAssertEqual(result.generated.iterations, 1_000)
        XCTAssertEqual(result.generated.salt.count, PasswordKeyDerivation.saltLength)
        XCTAssertFalse(result.generated.token.isEmpty)
        XCTAssertNotNil(try store.readSalt(forUsername: "alice"))
        XCTAssertNotNil(try store.readVerifier(forUsername: "alice"))
        XCTAssertEqual(try store.readToken(forUsername: "alice"), result.generated.token)
    }

    func test_generateAndConfigureToken_persistFalse_doesNotStoreToken() throws {
        let result = try coordinator.generateAndConfigureToken(
            forUsername: "alice",
            persistToken: false,
            iterations: 1_000
        )

        XCTAssertNotNil(try store.readVerifier(forUsername: "alice"))
        XCTAssertNil(try store.readToken(forUsername: "alice"))
        XCTAssertEqual(result.key.bitCount, 256)
    }

    func test_generateAndConfigureToken_twice_throwsAlreadyConfigured() throws {
        _ = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        XCTAssertThrowsError(try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)) { error in
            XCTAssertEqual(error as? EncryptionPasswordCoordinator.SetupError, .alreadyConfigured)
        }
    }

    // MARK: - unlockFromStoredToken

    func test_unlockFromStoredToken_persistedToken_returnsSameKey() throws {
        let setup = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        let unlocked = try coordinator.unlockFromStoredToken(forUsername: "alice")

        XCTAssertEqual(keyData(setup.key), keyData(unlocked))
    }

    func test_unlockFromStoredToken_tokenNotStored_throws() throws {
        _ = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: false, iterations: 1_000)

        XCTAssertThrowsError(try coordinator.unlockFromStoredToken(forUsername: "alice")) { error in
            XCTAssertEqual(error as? EncryptionPasswordCoordinator.UnlockError, .tokenNotStored)
        }
    }

    func test_unlockFromStoredToken_notConfigured_throws() {
        XCTAssertThrowsError(try coordinator.unlockFromStoredToken(forUsername: "ghost")) { error in
            XCTAssertEqual(error as? EncryptionPasswordCoordinator.UnlockError, .notConfigured)
        }
    }

    // MARK: - Bundle import / export

    func test_exportableBundle_returnsEqualParamsToSetup() throws {
        let setup = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        let bundle = try XCTUnwrap(try coordinator.exportableBundle(forUsername: "alice"))

        XCTAssertEqual(bundle.token, setup.generated.token)
        XCTAssertEqual(bundle.iterations, setup.generated.iterations)
        XCTAssertEqual(Data(base64Encoded: bundle.salt), setup.generated.salt)
    }

    func test_exportableBundle_returnsNil_whenTokenNotPersisted() throws {
        _ = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: false, iterations: 1_000)
        XCTAssertNil(try coordinator.exportableBundle(forUsername: "alice"))
    }

    func test_importToken_intoFreshDevice_yieldsSameKey() throws {
        // Device A
        let a = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        let bundle = try XCTUnwrap(try coordinator.exportableBundle(forUsername: "alice"))
        let exported = try JSONEncoder().encode(bundle)

        // Device B
        let storeB = InMemoryEncryptionPasswordStore()
        let coordinatorB = EncryptionPasswordCoordinator(derivation: PasswordKeyDerivation(), store: storeB)
        let decoded = try JSONDecoder().decode(EncryptionTokenBundle.self, from: exported)
        let generatedB = try decoded.toGeneratedToken()
        let keyB = try coordinatorB.importToken(generatedB, forUsername: "alice", persistToken: true)

        XCTAssertEqual(keyData(a.key), keyData(keyB))
        XCTAssertEqual(try storeB.readToken(forUsername: "alice"), bundle.token)
    }

    func test_importToken_alreadyConfigured_throws() throws {
        let setup = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        XCTAssertThrowsError(try coordinator.importToken(setup.generated, forUsername: "alice", persistToken: true)) { error in
            XCTAssertEqual(error as? EncryptionPasswordCoordinator.SetupError, .alreadyConfigured)
        }
    }

    func test_bundle_unsupportedVersion_throws() throws {
        // Construir JSON con version distinta a la actual.
        let payload: [String: Any] = [
            "version": 99,
            "token": "abc",
            "salt": Data(repeating: 0, count: PasswordKeyDerivation.saltLength).base64EncodedString(),
            "iterations": 1_000
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let bundle = try JSONDecoder().decode(EncryptionTokenBundle.self, from: data)

        XCTAssertThrowsError(try bundle.toGeneratedToken()) { error in
            if case EncryptionPasswordCoordinator.ImportError.unsupportedVersion(let v) = error {
                XCTAssertEqual(v, 99)
            } else {
                XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func test_bundle_malformedSalt_throws() throws {
        let payload: [String: Any] = [
            "version": EncryptionTokenBundle.currentVersion,
            "token": "abc",
            "salt": "not-base64-correct-length",
            "iterations": 1_000
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let bundle = try JSONDecoder().decode(EncryptionTokenBundle.self, from: data)

        XCTAssertThrowsError(try bundle.toGeneratedToken()) { error in
            XCTAssertEqual(error as? EncryptionPasswordCoordinator.ImportError, .malformedBundle)
        }
    }

    // MARK: - Reset

    func test_reset_thenGenerateAgain_works() throws {
        _ = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        try coordinator.reset(forUsername: "alice")

        let result = try coordinator.generateAndConfigureToken(forUsername: "alice", persistToken: true, iterations: 1_000)
        XCTAssertEqual(result.key.bitCount, 256)
    }

    // MARK: - Helpers

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - In-memory double

final class InMemoryEncryptionPasswordStore: EncryptionPasswordStore {
    private var storage: [String: Data] = [:]

    func readSalt(forUsername username: String) throws -> Data? {
        storage["\(username):salt"]
    }

    func writeSalt(_ salt: Data, forUsername username: String) throws {
        storage["\(username):salt"] = salt
    }

    func readVerifier(forUsername username: String) throws -> Data? {
        storage["\(username):verifier"]
    }

    func writeVerifier(_ verifier: Data, forUsername username: String) throws {
        storage["\(username):verifier"] = verifier
    }

    func readIterations(forUsername username: String) throws -> UInt32? {
        guard let data = storage["\(username):iterations"],
              let str = String(data: data, encoding: .utf8),
              let v = UInt32(str) else { return nil }
        return v
    }

    func writeIterations(_ iterations: UInt32, forUsername username: String) throws {
        storage["\(username):iterations"] = "\(iterations)".data(using: .utf8)
    }

    func readToken(forUsername username: String) throws -> String? {
        guard let data = storage["\(username):token"] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeToken(_ token: String, forUsername username: String) throws {
        storage["\(username):token"] = token.data(using: .utf8)
    }

    func deleteToken(forUsername username: String) throws {
        storage["\(username):token"] = nil
    }

    func reset(forUsername username: String) throws {
        storage["\(username):salt"] = nil
        storage["\(username):verifier"] = nil
        storage["\(username):iterations"] = nil
        storage["\(username):token"] = nil
    }
}
