import XCTest
@testable import NodeClient

@MainActor
final class FilesViewModelTests: XCTestCase {
    func test_loadFiles_withoutToken_setsSessionError() async {
        let apiClient = MockNodeAPIClient()
        let viewModel = FilesViewModel(apiClient: apiClient, sessionTokenProvider: { nil })

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.files.count, 0)
        XCTAssertEqual(viewModel.errorMessage, "No active session. Please login first.")
        XCTAssertEqual(apiClient.fetchTreeCallCount, 0)
    }

    func test_loadFiles_success_filtersDeletedAndSortsDirectoriesFirst() async {
        let apiClient = MockNodeAPIClient()
        apiClient.treeResult = .success(
            FsTreeResponse(
                username: "jose",
                cursor: 10,
                snapshotAt: Date(),
                entries: [
                    FsEntryResponse(entryId: "3", path: "/notes.txt", entryType: .file, sizeBytes: 120, checksum: "abc", version: 2, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "2", path: "/docs", entryType: .directory, sizeBytes: 0, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "4", path: "/zeta", entryType: .directory, sizeBytes: 0, checksum: nil, version: 1, updatedAt: Date(), deleted: false),
                    FsEntryResponse(entryId: "1", path: "/deleted.txt", entryType: .file, sizeBytes: 1, checksum: nil, version: 1, updatedAt: Date(), deleted: true)
                ]
            )
        )

        let viewModel = FilesViewModel(apiClient: apiClient, sessionTokenProvider: { "token" })

        await viewModel.loadFiles()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.files.map(\.id), ["2", "4", "3"])
        XCTAssertEqual(viewModel.files.first?.isFolder, true)
    }

    func test_loadFiles_unauthorized_setsExpectedMessage() async {
        let apiClient = MockNodeAPIClient()
        apiClient.treeResult = .failure(.unauthorized)
        let viewModel = FilesViewModel(apiClient: apiClient, sessionTokenProvider: { "expired-token" })

        await viewModel.loadFiles()

        XCTAssertEqual(viewModel.files.count, 0)
        XCTAssertEqual(viewModel.errorMessage, "Session expired or invalid token.")
    }
}

private final class MockNodeAPIClient: NodeAPIClientProtocol {
    var fetchTreeCallCount = 0
    var treeResult: Result<FsTreeResponse, NodeAPIError> = .success(
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    )

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        fetchTreeCallCount += 1
        return try treeResult.get()
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}
