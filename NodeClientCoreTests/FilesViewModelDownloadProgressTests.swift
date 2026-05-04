@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelDownloadProgressTests: XCTestCase {
    func test_startDownload_updatesProgressAndSavesFile() async {
        let apiClient = MockDownloadProgressAPIClient()
        apiClient.downloadHandler = { _, progress in
            progress(0.25)
            progress(0.75)
            return Data("hello".utf8)
        }

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForDownloadTests(),
            syncNamespaceProvider: { "jose" },
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/mock-download.txt") }
        )

        let file = FileItem(
            id: "file-1",
            name: "report.txt",
            detail: "12 KB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )

        viewModel.startDownload(file)
        await waitUntilDownloadCompletes(viewModel)

        XCTAssertFalse(viewModel.isDownloading)
        XCTAssertEqual(viewModel.downloadedFileURL?.path, "/tmp/mock-download.txt")
        XCTAssertEqual(viewModel.downloadProgress, 1.0)
        XCTAssertEqual(viewModel.downloadStatusMessage?.contains("Descargado"), true)
    }

    func test_cancelCurrentDownload_setsCanceledMessage() async {
        let apiClient = MockDownloadProgressAPIClient()
        apiClient.downloadHandler = { _, progress in
            progress(0.1)
            for _ in 0..<20 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return Data("late".utf8)
        }

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForDownloadTests(),
            syncNamespaceProvider: { "jose" },
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/never.txt") }
        )

        let file = FileItem(
            id: "file-2",
            name: "video.mp4",
            detail: "4 MB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )

        viewModel.startDownload(file)
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.cancelCurrentDownload()
        await waitUntilDownloadCompletes(viewModel)

        XCTAssertEqual(viewModel.downloadStatusMessage, "Descarga cancelada.")
        XCTAssertNil(viewModel.downloadedFileURL)
        XCTAssertEqual(viewModel.downloadProgress, 0)
    }

    func test_completeShare_whenCompleted_setsSuccessMessage() {
        let viewModel = FilesViewModel(
            apiClient: MockDownloadProgressAPIClient(),
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForDownloadTests()
        )            { "jose" }

        viewModel.completeShare(completed: true, errorDescription: nil)

        XCTAssertEqual(viewModel.shareStatusMessage, "Archivo exportado satisfactoriamente.")
    }

    func test_completeShare_whenCanceled_setsCanceledMessage() {
        let viewModel = FilesViewModel(
            apiClient: MockDownloadProgressAPIClient(),
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForDownloadTests()
        )            { "jose" }

        viewModel.completeShare(completed: false, errorDescription: nil)

        XCTAssertEqual(viewModel.shareStatusMessage, "Exportación cancelada.")
    }

    func test_completeShare_whenError_setsFailureMessage() {
        let viewModel = FilesViewModel(
            apiClient: MockDownloadProgressAPIClient(),
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryFilesSyncStateStoreForDownloadTests()
        )            { "jose" }

        viewModel.completeShare(completed: false, errorDescription: "permission denied")

        XCTAssertEqual(viewModel.shareStatusMessage, "Exportación fallida: permission denied")
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

private final class MockDownloadProgressAPIClient: NodeAPIClientProtocol {
    typealias DownloadHandler = (_ entryId: String, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data

    var downloadHandler: DownloadHandler = { _, _ in Data() }

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await downloadHandler(entryId, onProgress)
    }

    func logout(token: String) async throws {}
}

private final class InMemoryFilesSyncStateStoreForDownloadTests: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}

    func clearSnapshot(namespace: String) {}
}
