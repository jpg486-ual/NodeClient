@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelErrorHandlingTests: XCTestCase {
    func test_downloadFile_whenApiErrorCodeNotFound_showsFunctionalMessage() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.downloadResult = .failure(.api(statusCode: 404, errorCode: "FILE_ENTRY_NOT_FOUND", message: "entry missing"))

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        let file = FileItem(
            id: "missing-file",
            name: "missing.txt",
            detail: "",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )

        await viewModel.downloadFile(file)

        XCTAssertEqual(viewModel.downloadStatusMessage, "File entry not found on node.")
        XCTAssertNil(viewModel.downloadedFileURL)
    }

    func test_loadFiles_whenApiErrorCodeNotHandled_usesServerMessage() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .failure(.api(statusCode: 409, errorCode: "FS_PATH_CONFLICT", message: "path already exists"))

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.errorMessage, "A file or folder with the same path already exists.")
        XCTAssertEqual(viewModel.uiState, .error("A file or folder with the same path already exists."))
    }

    func test_uiState_whenLoadSucceedsWithNoFiles_isEmpty() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(username: "jose", cursor: 1, snapshotAt: Date(), entries: [])
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.uiState, .empty)
    }

    func test_uiState_whenLoadSucceedsWithEntries_isContent() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 2,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "f1", path: "/docs/a.txt", entryType: .file, sizeBytes: 12, checksum: "x", version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.uiState, .content)
    }

    func test_uiState_whenNoSession_isError() async {
        let apiClient = MockErrorHandlingNodeAPIClient()

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { nil },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.uiState, .error("No active session. Please login first."))
    }

    func test_loadFiles_failure_recordsDiagnosticTrace() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .failure(.transport("offline"))

        let defaultsName = "FilesViewModelErrorHandlingTests.Observability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let observability = UserDefaultsObservabilityStore(userDefaults: defaults)

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors(),
            syncNamespaceProvider: { "jose" },
            observabilityStore: observability
        )

        await viewModel.loadFiles()

        let traces = observability.recentTraces(limit: 20, minimumLevel: .error)
        XCTAssertTrue(traces.contains { $0.category == "sync" && $0.event == "sync.failed" })
    }

    func test_visibleFiles_whenSearchQueryMatches_filtersCaseInsensitive() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 3,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "d1", path: "/docs", entryType: .directory, sizeBytes: 0, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "f1", path: "/docs/Annual.pdf", entryType: .file, sizeBytes: 12, checksum: "x", version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "f2", path: "/docs/notes.txt", entryType: .file, sizeBytes: 12, checksum: "y", version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()
        viewModel.updateSearchQuery("ANNUAL")

        XCTAssertEqual(viewModel.visibleFiles.map(\.name), ["Annual.pdf"])
    }

    func test_visibleFiles_whenSortDescending_isDeterministic() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 4,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "d-a", path: "/a-folder", entryType: .directory, sizeBytes: 0, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "d-z", path: "/z-folder", entryType: .directory, sizeBytes: 0, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "f-a", path: "/a.txt", entryType: .file, sizeBytes: 12, checksum: "x", version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "f-z", path: "/z.txt", entryType: .file, sizeBytes: 12, checksum: "y", version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()
        viewModel.updateSortMode(.nameDescending)

        XCTAssertEqual(viewModel.visibleFiles.map(\.id), ["d-z", "d-a", "f-z", "f-a"])
    }

    func test_projection_whenSameQueryRepeated_doesNotRecompute() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 5,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "f1", path: "/docs/a.txt", entryType: .file, sizeBytes: 10, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "f2", path: "/docs/b.txt", entryType: .file, sizeBytes: 10, checksum: nil, version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()
        let before = viewModel.projectionComputationCount

        viewModel.updateSearchQuery("docs")
        let afterFirst = viewModel.projectionComputationCount
        viewModel.updateSearchQuery("docs")
        let afterSecond = viewModel.projectionComputationCount

        XCTAssertEqual(afterFirst, before + 1)
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func test_projection_whenSameSortRepeated_doesNotRecompute() async {
        let apiClient = MockErrorHandlingNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 6,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "f1", path: "/docs/c.txt", entryType: .file, sizeBytes: 10, checksum: nil, version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForErrors()
        )            { "jose" }

        await viewModel.loadFiles()
        let before = viewModel.projectionComputationCount

        viewModel.updateSortMode(.nameDescending)
        let afterFirst = viewModel.projectionComputationCount
        viewModel.updateSortMode(.nameDescending)
        let afterSecond = viewModel.projectionComputationCount

        XCTAssertEqual(afterFirst, before + 1)
        XCTAssertEqual(afterSecond, afterFirst)
    }
}

private final class MockErrorHandlingNodeAPIClient: NodeAPIClientProtocol {
    var treeResult: Result<FsTreeResponse, NodeAPIError> = .success(
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    )
    var downloadResult: Result<Data, NodeAPIError> = .success(Data())

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        try treeResult.get()
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try downloadResult.get()
    }

    func logout(token: String) async throws {}
}

private final class InMemoryFilesSyncStateStoreForErrors: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        nil
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}

    func clearSnapshot(namespace: String) {}
}
