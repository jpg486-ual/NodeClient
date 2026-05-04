@testable import NodeClientCore
import XCTest

@MainActor
final class BusinessFlowSmokeTests: XCTestCase {
    func test_smoke_loginSuccessThenListAndDownload() async {
        let (sessionStore, defaultsName) = makeSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        let loginClient = MockSmokeLoginClient()
        loginClient.loginResult = .success(
            AuthLoginResponse(token: "jwt-smoke", username: "jose", quotaMb: 2_048, expiresAt: Date())
        )

        let loginViewModel = LoginViewModel(baseURL: "http://localhost:8081") { _ in loginClient }
        loginViewModel.username = "jose"
        loginViewModel.password = "secret"

        await loginViewModel.login(sessionStore: sessionStore)

        XCTAssertTrue(sessionStore.isAuthenticated)

        let filesClient = MockSmokeFilesClient()
        filesClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 1,
                snapshotAt: Date(),
                entries: [
                    // Path en raíz ("/a.txt") para que
                    // el filtro por carpeta actual lo muestre. Antes
                    // mostrábamos lista plana; ahora se filtra por
                    // `parentPath == currentFolderPath` (default `/`).
                    FsEntryResponse(entryId: "f1", path: "/a.txt", entryType: .file, sizeBytes: 12, checksum: "x", version: 1, updatedAt: Date(), deleted: false)
                ]
            )
        )
        filesClient.downloadData = Data("hello".utf8)

        let filesViewModel = FilesViewModel(
            apiClient: filesClient,
            sessionTokenProvider: { sessionStore.sessionToken },
            syncStateStore: InMemoryFilesSyncStateStoreSmoke(),
            syncNamespaceProvider: { sessionStore.syncNamespace },
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/smoke.txt") }
        )

        await filesViewModel.loadFiles()
        filesViewModel.startDownload(filesViewModel.visibleFiles[0])
        await waitUntilDownloadCompletes(filesViewModel)

        XCTAssertEqual(filesViewModel.visibleFiles.count, 1)
        XCTAssertEqual(filesViewModel.downloadedFileURL?.path, "/tmp/smoke.txt")
        XCTAssertEqual(filesViewModel.downloadStatusMessage?.contains("Descargado"), true)
    }

    func test_smoke_loginInvalidCredentials_showsError() async {
        let (sessionStore, defaultsName) = makeSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        let loginClient = MockSmokeLoginClient()
        loginClient.loginResult = .failure(.unauthorized)

        let loginViewModel = LoginViewModel(baseURL: "http://localhost:8081") { _ in loginClient }
        loginViewModel.username = "jose"
        loginViewModel.password = "bad"

        await loginViewModel.login(sessionStore: sessionStore)

        XCTAssertEqual(loginViewModel.errorMessage, "Invalid credentials.")
        XCTAssertFalse(sessionStore.isAuthenticated)
    }

    func test_smoke_refreshList_updatesVisibleFiles() async {
        let filesClient = MockSmokeFilesClient()
        filesClient.treeQueue = [
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 1,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "f1", path: "/old.txt", entryType: .file, sizeBytes: 12, checksum: nil, version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            ),
            .success(
                FsTreeResponse(
                    username: "jose",
                    cursor: 2,
                    snapshotAt: Date(),
                    entries: [
                        FsEntryResponse(entryId: "f2", path: "/new.txt", entryType: .file, sizeBytes: 20, checksum: nil, version: 1, updatedAt: Date(), deleted: false)
                    ]
                )
            )
        ]

        let viewModel = FilesViewModel(
            apiClient: filesClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreSmoke()
        )            { "jose" }

        await viewModel.loadFiles()
        XCTAssertEqual(viewModel.visibleFiles.map(\.id), ["f1"])

        await viewModel.loadFiles()
        XCTAssertEqual(viewModel.visibleFiles.map(\.id), ["f2", "f1"])
    }

    private func makeSessionStore() -> (SessionStore, String) {
        let suiteName = "BusinessFlowSmokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SessionStore(userDefaults: defaults, tokenStore: TestSessionTokenStore()), suiteName)
    }

    private func waitUntilDownloadCompletes(_ viewModel: FilesViewModel) async {
        for _ in 0..<200 {
            if viewModel.downloadStatusMessage != nil {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for download to finish")
    }
}

private final class MockSmokeLoginClient: NodeAPIClientProtocol {
    var loginResult: Result<AuthLoginResponse, NodeAPIError> = .success(
        AuthLoginResponse(token: "", username: "", quotaMb: 0, expiresAt: Date())
    )

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        try loginResult.get()
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}

private final class MockSmokeFilesClient: NodeAPIClientProtocol {
    var treeResult: Result<FsTreeResponse, NodeAPIError> = .success(
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    )
    var treeQueue: [Result<FsTreeResponse, NodeAPIError>] = []
    var downloadData = Data()

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        if !treeQueue.isEmpty {
            return try treeQueue.removeFirst().get()
        }
        return try treeResult.get()
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        onProgress(1)
        return downloadData
    }

    func logout(token: String) async throws {}
}

private final class InMemoryFilesSyncStateStoreSmoke: FilesSyncStateStore {
    private var snapshot: FilesSyncSnapshot?

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        snapshot
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {
        self.snapshot = snapshot
    }

    func clearSnapshot(namespace: String) {
        snapshot = nil
    }
}

private final class TestSessionTokenStore: SessionTokenStore {
    private var token: String?

    func readToken() throws -> String? {
        token
    }

    func writeToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}
