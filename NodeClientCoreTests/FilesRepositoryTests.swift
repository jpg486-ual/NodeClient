@testable import NodeClientCore
import XCTest

final class FilesRepositoryTests: XCTestCase {
    func test_synchronizeFiles_mergesDeltaAndPersistsCursor() async throws {
        let apiClient = MockRepositoryAPIClient()
        let syncStore = InMemoryRepositorySyncStore(
            snapshot: FilesSyncSnapshot(
                cursor: 10,
                entries: [
                    FilesSyncEntry(
                        entryId: "f-old",
                        path: "/docs/old.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "x",
                        version: 1,
                        updatedAt: Date(),
                        deleted: false
                    )
                ]
            )
        )
        let telemetry = InMemoryRepositoryTelemetry()

        apiClient.treeQueue = [
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 12,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "f-old", path: "/docs/old.txt", entryType: .file, sizeBytes: 10, checksum: "x", version: 2, updatedAt: Date(), deleted: true),
                        FsEntryResponse(entryId: "f-new", path: "/docs/new.txt", entryType: .file, sizeBytes: 20, checksum: "y", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let repository = DefaultFilesRepository(apiClient: apiClient, syncStateStore: syncStore, telemetryStore: telemetry)

        let files = try await repository.synchronizeFiles(token: "token", namespace: "jose")

        // Overlap de 1 ms vs cursor previo: el cliente envía `cursor - 1`
        // para no perder cambios cuando dos eventos caen en el mismo
        // millisegundo del último sync.
        XCTAssertEqual(apiClient.sinceCalls, [9])
        XCTAssertEqual(files.map(\.id), ["f-new"])
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.cursor, 12)
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.entries.map(\.entryId), ["f-new"])
    }

    func test_synchronizeFiles_whenCursorRejected_fallsBackToFullResync() async throws {
        let apiClient = MockRepositoryAPIClient()
        let syncStore = InMemoryRepositorySyncStore(
            snapshot: FilesSyncSnapshot(
                cursor: 99,
                entries: [
                    FilesSyncEntry(
                        entryId: "f-cache",
                        path: "/cached.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "x",
                        version: 1,
                        updatedAt: Date(),
                        deleted: false
                    )
                ]
            )
        )
        let telemetry = InMemoryRepositoryTelemetry()

        apiClient.treeQueue = [
            .failure(.api(statusCode: 400, errorCode: "FS_TREE_INVALID_REQUEST", message: "invalid")),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 120,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "f-final", path: "/final.txt", entryType: .file, sizeBytes: 30, checksum: "z", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let repository = DefaultFilesRepository(apiClient: apiClient, syncStateStore: syncStore, telemetryStore: telemetry)

        let files = try await repository.synchronizeFiles(token: "token", namespace: "jose")

        XCTAssertEqual(apiClient.sinceCalls, [98, nil])
        XCTAssertEqual(files.map(\.id), ["f-final"])
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.cursor, 120)
        XCTAssertEqual(telemetry.value(for: .syncFallbackFullResync), 1)
    }

    func test_synchronizeFiles_whenTransientServerError_retriesAndThenSucceeds() async throws {
        let apiClient = MockRepositoryAPIClient()
        let syncStore = InMemoryRepositorySyncStore(snapshot: nil)
        let telemetry = InMemoryRepositoryTelemetry()
        var delays: [UInt64] = []

        apiClient.treeQueue = [
            .failure(.server(503)),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 5,
                    snapshotAt: Date(),
                    entries: []
                )
            )
        ]

        let repository = DefaultFilesRepository(
            apiClient: apiClient,
            syncStateStore: syncStore,
            telemetryStore: telemetry,
            retryPolicy: SyncRetryPolicy(maxAttempts: 2, initialDelayNanoseconds: 7_000_000, multiplier: 2)
        )            { delays.append($0) }

        _ = try await repository.synchronizeFiles(token: "token", namespace: "jose")

        XCTAssertEqual(apiClient.sinceCalls, [nil, nil])
        XCTAssertEqual(delays, [7_000_000])
    }
}

private final class MockRepositoryAPIClient: NodeAPIClientProtocol {
    var treeQueue: [Result<FsTreeResponse, NodeAPIError>] = []
    var sinceCalls: [Int64?] = []

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        sinceCalls.append(sinceCursor)
        return try treeQueue.removeFirst().get()
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}

private final class InMemoryRepositorySyncStore: FilesSyncStateStore {
    var snapshot: FilesSyncSnapshot?
    var lastWrittenSnapshot: FilesSyncSnapshot?

    init(snapshot: FilesSyncSnapshot?) {
        self.snapshot = snapshot
    }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        snapshot
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {
        self.snapshot = snapshot
        self.lastWrittenSnapshot = snapshot
    }

    func clearSnapshot(namespace: String) {
        snapshot = nil
    }
}

private final class InMemoryRepositoryTelemetry: SyncTelemetryStore {
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
