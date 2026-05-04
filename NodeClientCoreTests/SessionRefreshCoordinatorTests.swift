//  Tests del SessionRefreshCoordinator — congelan las invariantes:
//  - Token válido fuera del margen → no llama HTTP refresh.
//  - Token dentro del margen → llama refresh, persiste nuevo token+expiry.
//  - 401 en refresh → limpia sesión (devuelve `.expired`).
//  - Sin sesión activa → `.noActiveSession`.
//  - Concurrencia intra-proceso → single-flight via actor (1 sola HTTP).
//  - Network fail → `.stillValid` con token antiguo (caller decide retry).

@testable import NodeClientCore
import XCTest

@MainActor
final class SessionRefreshCoordinatorTests: XCTestCase {
    private let suiteName = "session-refresh-tests-\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var tokenStore: InMemorySessionTokenStore!
    private var apiClient: SpyRefreshAPIClient!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tokenStore = InMemorySessionTokenStore()
        apiClient = SpyRefreshAPIClient()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Cases

    func test_ensureFresh_whenTokenWellWithinTtl_returnsStillValidWithoutRefresh() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = now.addingTimeInterval(7 * 24 * 3_600) // 7d from now
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        let coordinator = makeCoordinator(now: now)
        let result = await coordinator.ensureFreshTokenIfNeeded()

        XCTAssertEqual(result, .stillValid(token: "old-token"))
        let refreshCount = await apiClient.refreshCallCount
        XCTAssertEqual(refreshCount, 0, "Refresh no debe dispararse fuera del margen")
    }

    func test_ensureFresh_whenInsideMargin_callsRefreshAndPersists() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 30 minutos para expirar — dentro del margen 1h.
        let expiresAt = now.addingTimeInterval(30 * 60)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        let newExpiresAt = now.addingTimeInterval(7 * 24 * 3_600)
        await apiClient.setRefreshResponse(.success(.init(
            token: "new-token",
            username: "alice",
            quotaMb: 2_048,
            expiresAt: newExpiresAt,
            role: "END_USER"
        )))

        let coordinator = makeCoordinator(now: now)
        let result = await coordinator.ensureFreshTokenIfNeeded()

        XCTAssertEqual(result, .refreshed(token: "new-token", expiresAt: newExpiresAt))

        let persistedToken = try tokenStore.readToken()
        XCTAssertEqual(persistedToken, "new-token")

        let persistedExpiry = defaults.object(forKey: NodeClientAppGroups.sessionExpiresAtKey) as? Double
        XCTAssertEqual(persistedExpiry, newExpiresAt.timeIntervalSince1970)
    }

    func test_ensureFresh_whenRefreshReturns401_returnsExpiredAndClearsSession() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = now.addingTimeInterval(30 * 60)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        await apiClient.setRefreshResponse(.failure(.api(
            statusCode: 401,
            errorCode: "INVALID_SESSION",
            message: "session expired"
        )))

        let coordinator = makeCoordinator(now: now)
        let result = await coordinator.ensureFreshTokenIfNeeded()

        XCTAssertEqual(result, .expired)
        XCTAssertNil(try tokenStore.readToken(), "Token debe limpiarse tras 401")
        XCTAssertNil(defaults.object(forKey: NodeClientAppGroups.sessionExpiresAtKey),
                     "expiresAt debe limpiarse tras 401")
    }

    func test_ensureFresh_whenNoSession_returnsNoActiveSession() async {
        let coordinator = makeCoordinator(now: Date())
        let result = await coordinator.ensureFreshTokenIfNeeded()

        XCTAssertEqual(result, .noActiveSession)
        let refreshCount = await apiClient.refreshCallCount
        XCTAssertEqual(refreshCount, 0)
    }

    func test_ensureFresh_whenNetworkFails_returnsStillValidWithCurrentToken() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = now.addingTimeInterval(30 * 60)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        await apiClient.setRefreshResponse(.failure(.transport("network error")))

        let coordinator = makeCoordinator(now: now)
        let result = await coordinator.ensureFreshTokenIfNeeded()

        XCTAssertEqual(result, .stillValid(token: "old-token"))
        XCTAssertEqual(try tokenStore.readToken(), "old-token", "Token original preservado en network fail")
    }

    func test_ensureFresh_concurrentCalls_serializeViaActorAndDoSingleHttpRefresh() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = now.addingTimeInterval(30 * 60)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        let newExpiresAt = now.addingTimeInterval(7 * 24 * 3_600)
        await apiClient.setRefreshResponse(.success(.init(
            token: "new-token",
            username: "alice",
            quotaMb: 2_048,
            expiresAt: newExpiresAt,
            role: "END_USER"
        )))

        let coordinator = makeCoordinator(now: now)

        async let r1 = coordinator.ensureFreshTokenIfNeeded()
        async let r2 = coordinator.ensureFreshTokenIfNeeded()
        async let r3 = coordinator.ensureFreshTokenIfNeeded()
        async let r4 = coordinator.ensureFreshTokenIfNeeded()
        async let r5 = coordinator.ensureFreshTokenIfNeeded()

        let results = await [r1, r2, r3, r4, r5]

        let refreshCount = await apiClient.refreshCallCount
        XCTAssertEqual(refreshCount, 1, "Single-flight: máximo 1 HTTP refresh para 5 calls concurrentes")
        // Single-flight: las 5 calls comparten el resultado de la única
        // task en vuelo (todas reciben `.refreshed`). Si el patrón fuera
        // "primera refresca, las demás re-leen y devuelven .stillValid",
        // los tests serían más estrictos pero el comportamiento actual
        // garantiza la invariante crítica (1 sola HTTP).
        let refreshedCount = results.filter { result in
            if case .refreshed = result {
                return true
            }
            return false
        }.count
        XCTAssertEqual(refreshedCount, 5, "Todas las calls comparten el resultado del single-flight")
    }

    func test_currentTokenIfActive_throwsExpiredOnExpiredSession() async throws {
        try tokenStore.writeToken("old-token")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = now.addingTimeInterval(30 * 60)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)

        await apiClient.setRefreshResponse(.failure(.api(
            statusCode: 401,
            errorCode: "INVALID_SESSION",
            message: nil
        )))

        let coordinator = makeCoordinator(now: now)
        do {
            _ = try await coordinator.currentTokenIfActive()
            XCTFail("Debe throw SessionUnavailableError.expired")
        } catch SessionUnavailableError.expired {
            // OK
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(now: Date) -> SessionRefreshCoordinator {
        SessionRefreshCoordinator(
            apiClient: apiClient,
            tokenStore: tokenStore,
            userDefaults: defaults,
            lock: nil,
            clock: { now },
            marginSeconds: 3_600
        )
    }
}

// MARK: - Mocks

private actor SpyRefreshAPIClient: SessionRefreshAPIClient {
    private(set) var refreshCallCount = 0
    private var refreshResult: Result<AuthLoginResponse, NodeAPIError>?

    func setRefreshResponse(_ result: Result<AuthLoginResponse, NodeAPIError>) {
        self.refreshResult = result
    }

    func refresh(token: String) async throws -> AuthLoginResponse {
        refreshCallCount += 1
        guard let result = refreshResult else {
            throw NodeAPIError.transport("not used")
        }
        switch result {
        case let .success(response):
            return response

        case let .failure(error):
            throw error
        }
    }
}

private final class InMemorySessionTokenStore: SessionTokenStore {
    private var token: String?
    func readToken() throws -> String? { token }
    func writeToken(_ token: String) throws { self.token = token }
    func deleteToken() throws { token = nil }
}
