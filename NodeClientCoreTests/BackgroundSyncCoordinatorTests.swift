//  Tests TDD BackgroundSyncCoordinator.
//
//  Cubre los 4 caminos del coordinator: sin sesión, offline, success,
//  api error, unexpected error. Usa mocks de FilesRepository,
//  SyncTelemetryStore y un SessionStore aislado con UserDefaults
//  in-memory + InMemorySessionTokenStore reusado de los tests
//  previos.

@testable import NodeClientCore
import XCTest

@MainActor
final class BackgroundSyncCoordinatorTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var repository: MockFilesRepository!
    private var telemetry: InMemorySyncTelemetryStore!
    private var coordinator: BackgroundSyncCoordinator!

    override func setUp() {
        super.setUp()
        let suiteName = "bg-sync-coordinator-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        sessionStore = SessionStore(
            userDefaults: defaults,
            tokenStore: InMemorySessionTokenStore()
        )
        repository = MockFilesRepository()
        telemetry = InMemorySyncTelemetryStore()
        coordinator = BackgroundSyncCoordinator(
            sessionStore: sessionStore,
            repository: repository,
            telemetry: telemetry
        )            { Date(timeIntervalSince1970: 1_750_000_000) }
    }

    // MARK: - Path: no session

    func test_performBackgroundSync_withoutSession_skipsAndRecordsTelemetry() async {
        let success = await coordinator.performBackgroundSync()

        XCTAssertFalse(success)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSkippedNoSession), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSuccess), 0)
        XCTAssertFalse(repository.synchronizeWasCalled)
    }

    // MARK: - Path: offline

    func test_performBackgroundSync_offline_skipsAndRecordsTelemetry() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )
        repository.errorToThrow = NodeAPIError.transport("connection refused")

        let success = await coordinator.performBackgroundSync()

        XCTAssertFalse(success)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSkippedOffline), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSuccess), 0)
        XCTAssertTrue(repository.synchronizeWasCalled)
    }

    // MARK: - Path: success

    func test_performBackgroundSync_success_invokesRepositorySync() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )
        repository.filesToReturn = [
            FileItem(
                id: "1",
                name: "doc.pdf",
                detail: "100 B",
                systemImage: "doc",
                isFolder: false,
                isShared: false,
                isOffline: false
            )
        ]

        let success = await coordinator.performBackgroundSync()

        XCTAssertTrue(success)
        XCTAssertTrue(repository.synchronizeWasCalled)
        XCTAssertEqual(repository.lastNamespace, "alice")
        XCTAssertEqual(repository.lastToken, "valid-token")
    }

    func test_performBackgroundSync_success_recordsSuccessTelemetry() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )

        _ = await coordinator.performBackgroundSync()

        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSuccess), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSkippedOffline), 0)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundErrorApi), 0)
    }

    // MARK: - Path: API error

    func test_performBackgroundSync_apiError_recordsErrorTelemetry() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )
        repository.errorToThrow = NodeAPIError.unauthorized

        let success = await coordinator.performBackgroundSync()

        XCTAssertFalse(success)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundErrorApi), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSuccess), 0)
    }

    // MARK: - Path: unexpected error

    func test_performBackgroundSync_unexpectedError_recordsErrorTelemetry() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )
        repository.errorToThrow = SomeUnexpectedError.boom

        let success = await coordinator.performBackgroundSync()

        XCTAssertFalse(success)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundErrorUnexpected), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundErrorApi), 0)
    }

    // MARK: - Telemetry isolation

    func test_telemetryStore_backgroundCounters_areIsolatedFromForeground() async {
        sessionStore.updateSession(
            baseURL: "http://localhost:8081",
            token: "valid-token",
            username: "alice"
        )
        telemetry.increment(.syncIncrementalAttempt)
        telemetry.increment(.syncFullAttempt)

        _ = await coordinator.performBackgroundSync()

        XCTAssertEqual(telemetry.value(for: .syncIncrementalAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncFullAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncBackgroundSuccess), 1)
    }

    // MARK: - Return value contract

    func test_performBackgroundSync_returnsTrueOnSuccess_falseOnFailure() async {
        // Caso 1: sin sesión → false
        let case1 = await coordinator.performBackgroundSync()
        XCTAssertFalse(case1)

        // Caso 2: con sesión + sync OK → true
        sessionStore.updateSession(baseURL: "http://localhost:8081", token: "t", username: "u")
        let case2 = await coordinator.performBackgroundSync()
        XCTAssertTrue(case2)

        // Caso 3: con sesión + sync error → false
        repository.errorToThrow = NodeAPIError.unauthorized
        let case3 = await coordinator.performBackgroundSync()
        XCTAssertFalse(case3)
    }
}

// MARK: - Test doubles

private final class MockFilesRepository: FilesRepositoryProtocol {
    var synchronizeWasCalled: Bool = false
    var lastToken: String?
    var lastNamespace: String?
    var filesToReturn: [FileItem] = []
    var errorToThrow: Error?

    func readCachedFiles(namespace: String) -> [FileItem] {
        filesToReturn
    }

    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] {
        synchronizeWasCalled = true
        lastToken = token
        lastNamespace = namespace
        if let errorToThrow {
            throw errorToThrow
        }
        return filesToReturn
    }
}

private final class InMemorySyncTelemetryStore: SyncTelemetryStore {
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

private final class InMemorySessionTokenStore: SessionTokenStore {
    private var token: String?
    func readToken() throws -> String? { token }
    func writeToken(_ t: String) throws { token = t }
    func deleteToken() throws { token = nil }
}

private enum SomeUnexpectedError: Error {
    case boom
}
