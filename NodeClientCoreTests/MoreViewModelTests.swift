@testable import NodeClientCore
import XCTest

@MainActor
final class MoreViewModelTests: XCTestCase {
    func test_logout_withoutToken_skipsRemoteCallAndClearsLocalSession() async {
        let apiClient = MockLogoutNodeAPIClient()
        let viewModel = MoreViewModel { _ in apiClient }
        let sessionStore = SessionStore(userDefaults: testDefaults(), tokenStore: MockSessionTokenStore())

        await viewModel.logout(sessionStore: sessionStore)

        XCTAssertEqual(apiClient.logoutCallCount, 0)
        XCTAssertFalse(sessionStore.isAuthenticated)
        XCTAssertNil(viewModel.logoutMessage)
    }

    func test_logout_success_callsRemoteLogoutAndClearsLocalSession() async {
        let apiClient = MockLogoutNodeAPIClient()
        let viewModel = MoreViewModel { _ in apiClient }
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "token-123")

        await viewModel.logout(sessionStore: sessionStore)

        XCTAssertEqual(apiClient.logoutCallCount, 1)
        XCTAssertEqual(apiClient.lastLogoutToken, "token-123")
        XCTAssertFalse(sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.logoutMessage, "Sesión cerrada en el nodo y en el dispositivo.")
    }

    func test_logout_unauthorized_stillClearsLocalSession() async {
        let apiClient = MockLogoutNodeAPIClient()
        apiClient.logoutResult = .failure(.unauthorized)

        let syncStore = InMemoryLogoutSyncStateStore()
        let viewModel = MoreViewModel(apiClientFactory: { _ in apiClient }, syncStateStore: syncStore)
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "expired-token")

        await viewModel.logout(sessionStore: sessionStore)

        XCTAssertEqual(apiClient.logoutCallCount, 1)
        XCTAssertFalse(sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.logoutMessage, "La sesión ya no era válida. Sesión local cerrada.")
        XCTAssertEqual(syncStore.clearedNamespace, "anonymous")
    }

    func test_logout_invalidSessionErrorCode_stillClearsLocalSession() async {
        let apiClient = MockLogoutNodeAPIClient()
        apiClient.logoutResult = .failure(.api(statusCode: 401, errorCode: "INVALID_SESSION", message: "session expired"))

        let syncStore = InMemoryLogoutSyncStateStore()
        let viewModel = MoreViewModel(apiClientFactory: { _ in apiClient }, syncStateStore: syncStore)
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "expired-token")

        await viewModel.logout(sessionStore: sessionStore)

        XCTAssertEqual(apiClient.logoutCallCount, 1)
        XCTAssertFalse(sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.logoutMessage, "La sesión ya no era válida. Sesión local cerrada.")
        XCTAssertEqual(syncStore.clearedNamespace, "anonymous")
    }

    func test_logout_genericApiError_usesServerMessageAndClearsLocalSession() async {
        let apiClient = MockLogoutNodeAPIClient()
        apiClient.logoutResult = .failure(.api(statusCode: 409, errorCode: "FILE_CONTENT_CONFLICT", message: "conflict while closing session"))

        let syncStore = InMemoryLogoutSyncStateStore()
        let viewModel = MoreViewModel(apiClientFactory: { _ in apiClient }, syncStateStore: syncStore)
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "token-123")

        await viewModel.logout(sessionStore: sessionStore)

        XCTAssertEqual(apiClient.logoutCallCount, 1)
        XCTAssertFalse(sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.logoutMessage, "conflict while closing session Sesión local cerrada.")
        XCTAssertEqual(syncStore.clearedNamespace, "anonymous")
    }

#if DEBUG
    func test_debugTelemetryRows_refreshFromStore() {
        let telemetry = InMemoryTelemetryStoreForMoreTests()
        telemetry.increment(.syncIncrementalAttempt)
        telemetry.increment(.syncIncrementalAttempt)
        telemetry.increment(.migrationLegacySnapshotSuccess)

        let viewModel = MoreViewModel(telemetryStore: telemetry)

        viewModel.refreshDebugTelemetry()

        XCTAssertEqual(viewModel.debugTelemetryRows.first { $0.eventName == "sync.incremental.attempt" }?.value, 2)
        XCTAssertEqual(viewModel.debugTelemetryRows.first { $0.eventName == "migration.legacy.success" }?.value, 1)
    }

    func test_debugTelemetryRows_resetMetrics() {
        let telemetry = InMemoryTelemetryStoreForMoreTests()
        telemetry.increment(.syncFullAttempt)

        let viewModel = MoreViewModel(telemetryStore: telemetry)
        viewModel.resetDebugTelemetry()

        XCTAssertEqual(viewModel.debugTelemetryRows.first { $0.eventName == "sync.full.attempt" }?.value, 0)
    }
#endif

    private func makeSessionStore(baseURL: String, token: String) -> SessionStore {
        let defaults = testDefaults()
        let tokenStore = MockSessionTokenStore()
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: tokenStore)
        sessionStore.updateSession(baseURL: baseURL, token: token)
        return sessionStore
    }

    private func testDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "MoreViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class MockLogoutNodeAPIClient: NodeAPIClientProtocol {
    private(set) var logoutCallCount = 0
    private(set) var lastLogoutToken: String?
    var logoutResult: Result<Void, NodeAPIError> = .success(())

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {
        logoutCallCount += 1
        lastLogoutToken = token
        switch logoutResult {
        case .success:
            return

        case .failure(let error):
            throw error
        }
    }
}

private final class MockSessionTokenStore: SessionTokenStore {
    private(set) var storedToken: String?

    func readToken() throws -> String? {
        storedToken
    }

    func writeToken(_ token: String) throws {
        storedToken = token
    }

    func deleteToken() throws {
        storedToken = nil
    }
}

private final class InMemoryLogoutSyncStateStore: FilesSyncStateStore {
    private(set) var clearedNamespace: String?

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        nil
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}

    func clearSnapshot(namespace: String) {
        clearedNamespace = namespace
    }
}

#if DEBUG
private final class InMemoryTelemetryStoreForMoreTests: SyncTelemetryStore {
    private var counters: [SyncTelemetryEvent: Int] = [:]

    func increment(_ event: SyncTelemetryEvent) {
        counters[event, default: 0] += 1
    }

    func value(for event: SyncTelemetryEvent) -> Int {
        counters[event, default: 0]
    }

    func snapshot() -> [SyncTelemetryEvent: Int] {
        counters
    }

    func resetAll() {
        counters.removeAll()
    }
}
#endif
