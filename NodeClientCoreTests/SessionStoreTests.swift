@testable import NodeClientCore
import XCTest

@MainActor
final class SessionStoreTests: XCTestCase {
    func test_init_migratesLegacyTokenFromUserDefaultsToTokenStore() {
        let defaults = testDefaults()
        defaults.set("legacy-token", forKey: SessionStore.sessionTokenKey)

        let tokenStore = MockSessionTokenStore()

        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(sessionStore.sessionToken, "legacy-token")
        XCTAssertEqual(tokenStore.writtenTokens, ["legacy-token"])
        XCTAssertNil(defaults.string(forKey: SessionStore.sessionTokenKey))
    }

    func test_updateSession_trimsAndPersistsSecurely() {
        let defaults = testDefaults()
        let tokenStore = MockSessionTokenStore()
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        sessionStore.updateSession(baseURL: "  http://localhost:8081  ", token: "  secure-token  ")

        XCTAssertEqual(sessionStore.baseURL, "http://localhost:8081")
        XCTAssertEqual(sessionStore.sessionToken, "secure-token")
        XCTAssertEqual(defaults.string(forKey: SessionStore.baseURLKey), "http://localhost:8081")
        XCTAssertEqual(tokenStore.storedToken, "secure-token")
        XCTAssertNil(defaults.string(forKey: SessionStore.sessionTokenKey))
    }

    func test_logout_clearsInMemoryAndTokenStore() {
        let defaults = testDefaults()
        let tokenStore = MockSessionTokenStore(storedToken: "secure-token")
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        sessionStore.logout()

        XCTAssertNil(sessionStore.sessionToken)
        XCTAssertEqual(tokenStore.deleteCallCount, 1)
        XCTAssertNil(defaults.string(forKey: SessionStore.sessionTokenKey))
    }

    func test_init_usesTokenStoreValueWhenAvailable() {
        let defaults = testDefaults()
        defaults.set("legacy-token", forKey: SessionStore.sessionTokenKey)

        let tokenStore = MockSessionTokenStore(storedToken: "secure-token")

        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(sessionStore.sessionToken, "secure-token")
        XCTAssertTrue(tokenStore.writtenTokens.isEmpty)
    }

    // Tras un build & run de Xcode (típico macOS) el Group Container puede
    // limpiarse mientras el Keychain --persistido por bundle ID + access
    // group-- sobrevive. Sin este fallback, sessionToken se restaura pero
    // username queda nil y el auto-unlock del EncryptionKeyVault aborta en
    // el guard, dejando el cifrado inactivo hasta que el usuario abre
    // Settings → Cifrado.
    func test_init_fallsBackToTokenStoreUsername_whenDefaultsEmpty() {
        let defaults = testDefaults()
        let tokenStore = MockSessionTokenStore(
            storedToken: "secure-token",
            storedUsername: "alice"
        )

        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(sessionStore.username, "alice")
        XCTAssertEqual(
            defaults.string(forKey: SessionStore.usernameKey),
            "alice",
            "El fallback debe repoblar UserDefaults para que la próxima ejecución no dependa del Keychain."
        )
    }

    func test_init_prefersDefaultsUsername_overTokenStoreFallback() {
        let defaults = testDefaults()
        defaults.set("from-defaults", forKey: SessionStore.usernameKey)
        let tokenStore = MockSessionTokenStore(
            storedToken: "secure-token",
            storedUsername: "from-keychain"
        )

        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(sessionStore.username, "from-defaults")
    }

    // MARK: quotaMb propagation

    func test_init_quotaMb_isNilWhenNotPersisted() {
        let sessionStore = SessionStore(userDefaults: testDefaults(), tokenStore: MockSessionTokenStore())
        XCTAssertNil(sessionStore.quotaMb)
    }

    func test_updateSession_persistsQuotaMb() {
        let defaults = testDefaults()
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: MockSessionTokenStore())

        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "t",
            username: "alice",
            quotaMb: 5_120
        )

        XCTAssertEqual(sessionStore.quotaMb, 5_120)
        XCTAssertEqual(defaults.integer(forKey: SessionStore.quotaMbKey), 5_120)
    }

    func test_init_readsQuotaMbFromDefaults_whenAvailable() {
        let defaults = testDefaults()
        defaults.set(2_048, forKey: SessionStore.quotaMbKey)

        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: MockSessionTokenStore())

        XCTAssertEqual(sessionStore.quotaMb, 2_048)
    }

    func test_logout_clearsQuotaMb() {
        let defaults = testDefaults()
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: MockSessionTokenStore())
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "t",
            username: "alice",
            quotaMb: 5_120
        )

        sessionStore.logout()

        XCTAssertNil(sessionStore.quotaMb)
        XCTAssertEqual(
            defaults.integer(forKey: SessionStore.quotaMbKey),
            0,
            "removeObject deja el integer key en 0; basta para considerarlo limpio"
        )
    }

    private func testDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "SessionStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
            return .standard
        }

        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class MockSessionTokenStore: SessionTokenStore {
    private(set) var storedToken: String?
    private(set) var storedUsername: String?
    private(set) var writtenTokens: [String] = []
    private(set) var writtenUsernames: [String] = []
    private(set) var deleteCallCount = 0

    init(storedToken: String? = nil, storedUsername: String? = nil) {
        self.storedToken = storedToken
        self.storedUsername = storedUsername
    }

    func readToken() throws -> String? {
        storedToken
    }

    func writeToken(_ token: String) throws {
        storedToken = token
        writtenTokens.append(token)
    }

    func deleteToken() throws {
        deleteCallCount += 1
        storedToken = nil
    }

    func readUsername() throws -> String? {
        storedUsername
    }

    func writeUsername(_ username: String) throws {
        storedUsername = username
        writtenUsernames.append(username)
    }

    func deleteUsername() throws {
        storedUsername = nil
    }
}
