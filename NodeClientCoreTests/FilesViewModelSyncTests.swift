@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelSyncTests: XCTestCase {
    func test_loadFiles_usesStoredCursorAndMergesIncrementalChanges() async {
        let syncStore = InMemoryFilesSyncStateStore(
            snapshot: FilesSyncSnapshot(
                cursor: 10,
                entries: [
                    FilesSyncEntry(
                        entryId: "dir-1",
                        path: "/docs",
                        entryType: .directory,
                        sizeBytes: 0,
                        checksum: nil,
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 100),
                        deleted: false
                    ),
                    FilesSyncEntry(
                        entryId: "file-1",
                        path: "/docs/old.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "abc",
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 101),
                        deleted: false
                    )
                ]
            )
        )

        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 12,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "file-1", path: "/docs/old.txt", entryType: .file, sizeBytes: 10, checksum: "abc", version: 2, updatedAt: Date(), deleted: true),
                    FsEntryResponse(entryId: "file-2", path: "/docs/new.txt", entryType: .file, sizeBytes: 15, checksum: "def", version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(apiClient.lastSinceCursor, 9)
        XCTAssertEqual(viewModel.files.map(\.id), ["dir-1", "file-2"])
        XCTAssertEqual(syncStore.lastWrittenNamespace, "jose")
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.cursor, 12)
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.entries.map(\.entryId).sorted(), ["dir-1", "file-2"])
    }

    func test_loadFiles_whenNetworkFails_keepsCachedFilesAndSetsError() async {
        let syncStore = InMemoryFilesSyncStateStore(
            snapshot: FilesSyncSnapshot(
                cursor: 20,
                entries: [
                    FilesSyncEntry(
                        entryId: "file-1",
                        path: "/cached.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "abc",
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 200),
                        deleted: false
                    )
                ]
            )
        )

        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeResult = .failure(.transport("offline"))

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.files.map(\.id), ["file-1"])
        XCTAssertEqual(viewModel.errorMessage, "Network error: offline")
    }

    func test_loadFiles_recordsTelemetry_forIncrementalAndFallback() async {
        let syncStore = InMemoryFilesSyncStateStore(
            snapshot: FilesSyncSnapshot(
                cursor: 50,
                entries: [
                    FilesSyncEntry(
                        entryId: "file-legacy",
                        path: "/legacy.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "old",
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 300),
                        deleted: false
                    )
                ]
            )
        )

        let telemetry = InMemorySyncTelemetryStore()
        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeQueue = [
            .failure(.server(400)),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 60,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "file-fresh", path: "/fresh.txt", entryType: .file, sizeBytes: 20, checksum: "new", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore,
            syncNamespaceProvider: { "jose" },
            telemetryStore: telemetry
        )

        await viewModel.loadFiles()

        XCTAssertEqual(telemetry.value(for: .syncIncrementalAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncFallbackFullResync), 1)
        XCTAssertEqual(telemetry.value(for: .syncFullAttempt), 1)
    }

    func test_loadFiles_recordsNetworkErrorTelemetry() async {
        let syncStore = InMemoryFilesSyncStateStore(snapshot: nil)
        let telemetry = InMemorySyncTelemetryStore()
        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeResult = .failure(.transport("offline"))

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore,
            syncNamespaceProvider: { "jose" },
            telemetryStore: telemetry
        )

        await viewModel.loadFiles()

        XCTAssertEqual(telemetry.value(for: .syncFullAttempt), 1)
        XCTAssertEqual(telemetry.value(for: .syncNetworkError), 1)
        XCTAssertEqual(telemetry.value(for: .syncApiError), 0)
    }

    func test_loadFiles_whenTransientNetworkError_retriesWithBackoffAndSucceeds() async {
        let syncStore = InMemoryFilesSyncStateStore(snapshot: nil)
        let telemetry = InMemorySyncTelemetryStore()
        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeQueue = [
            .failure(.transport("temporary offline")),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 90,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "file-ok", path: "/ok.txt", entryType: .file, sizeBytes: 10, checksum: "c1", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        var recordedSleeps: [UInt64] = []

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore,
            syncNamespaceProvider: { "jose" },
            telemetryStore: telemetry,
            syncRetryPolicy: SyncRetryPolicy(maxAttempts: 2, initialDelayNanoseconds: 10_000_000, multiplier: 2)
        )            { delay in
                recordedSleeps.append(delay)
        }

        await viewModel.loadFiles()

        XCTAssertEqual(apiClient.sinceCursorCalls, [nil, nil])
        XCTAssertEqual(recordedSleeps, [10_000_000])
        XCTAssertEqual(viewModel.files.map(\.id), ["file-ok"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func test_loadFiles_whenTransientNetworkErrorExceedsRetries_setsError() async {
        let syncStore = InMemoryFilesSyncStateStore(snapshot: nil)
        let telemetry = InMemorySyncTelemetryStore()
        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeQueue = [
            .failure(.transport("offline-1")),
            .failure(.transport("offline-2"))
        ]

        var recordedSleeps: [UInt64] = []

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore,
            syncNamespaceProvider: { "jose" },
            telemetryStore: telemetry,
            syncRetryPolicy: SyncRetryPolicy(maxAttempts: 2, initialDelayNanoseconds: 5_000_000, multiplier: 2)
        )            { delay in
                recordedSleeps.append(delay)
        }

        await viewModel.loadFiles()

        XCTAssertEqual(apiClient.sinceCursorCalls, [nil, nil])
        XCTAssertEqual(recordedSleeps, [5_000_000])
        XCTAssertEqual(viewModel.errorMessage, "Network error: offline-2")
    }

    func test_loadFiles_whenIncrementalCursorRejected_performsFullResync() async {
        let syncStore = InMemoryFilesSyncStateStore(
            snapshot: FilesSyncSnapshot(
                cursor: 50,
                entries: [
                    FilesSyncEntry(
                        entryId: "file-legacy",
                        path: "/legacy.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "old",
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 300),
                        deleted: false
                    )
                ]
            )
        )

        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeQueue = [
            .failure(.server(400)),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 60,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "file-fresh", path: "/fresh.txt", entryType: .file, sizeBytes: 20, checksum: "new", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(apiClient.sinceCursorCalls, [49, nil])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.files.map(\.id), ["file-fresh"])
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.cursor, 60)
    }

    func test_loadFiles_whenIncrementalCursorRejectedWithApiErrorCode_performsFullResync() async {
        let syncStore = InMemoryFilesSyncStateStore(
            snapshot: FilesSyncSnapshot(
                cursor: 70,
                entries: [
                    FilesSyncEntry(
                        entryId: "file-old",
                        path: "/old.txt",
                        entryType: .file,
                        sizeBytes: 10,
                        checksum: "old",
                        version: 1,
                        updatedAt: Date(timeIntervalSince1970: 350),
                        deleted: false
                    )
                ]
            )
        )

        let apiClient = MockSyncNodeAPIClient()
        apiClient.treeQueue = [
            .failure(.api(statusCode: 400, errorCode: "FS_TREE_INVALID_REQUEST", message: "cursor invalid")),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 80,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "file-new", path: "/new.txt", entryType: .file, sizeBytes: 20, checksum: "new", version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: syncStore
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(apiClient.sinceCursorCalls, [69, nil])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.files.map(\.id), ["file-new"])
        XCTAssertEqual(syncStore.lastWrittenSnapshot?.cursor, 80)
    }
}

private final class MockSyncNodeAPIClient: NodeAPIClientProtocol {
    var treeResult: Result<FsTreeResponse, NodeAPIError> = .success(
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    )
    var treeQueue: [Result<FsTreeResponse, NodeAPIError>] = []
    var lastSinceCursor: Int64?
    var sinceCursorCalls: [Int64?] = []

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        lastSinceCursor = sinceCursor
        sinceCursorCalls.append(sinceCursor)
        if !treeQueue.isEmpty {
            return try treeQueue.removeFirst().get()
        }
        return try treeResult.get()
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}

private final class InMemoryFilesSyncStateStore: FilesSyncStateStore {
    private(set) var snapshot: FilesSyncSnapshot?
    private(set) var lastWrittenSnapshot: FilesSyncSnapshot?
    private(set) var lastWrittenNamespace: String?

    init(snapshot: FilesSyncSnapshot?) {
        self.snapshot = snapshot
    }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        snapshot
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {
        self.snapshot = snapshot
        self.lastWrittenSnapshot = snapshot
        self.lastWrittenNamespace = namespace
    }

    func clearSnapshot(namespace: String) {
        snapshot = nil
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
