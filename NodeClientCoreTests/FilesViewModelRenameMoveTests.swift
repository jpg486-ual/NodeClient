//  TDD para `FilesViewModel.renameFile` y
//  `FilesViewModel.moveFile`.
//  Cubrimos:
//  - rename: ok, empty name, slash inválido, no-session, mismo nombre, error api
//  - move: ok, mismo destino, error api
//  - helpers de paths.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelRenameMoveTests: XCTestCase {
    // MARK: - Rename

    func test_renameFile_callsPatchEntryWithComputedNewPath() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e1", name: "old.txt", path: "/folder/old.txt")

        await viewModel.renameFile(item, to: "new.txt")

        XCTAssertEqual(api.lastPatchEntryId, "e1")
        XCTAssertEqual(api.lastPatchRequest?.newPath, "/folder/new.txt")
        XCTAssertEqual(viewModel.renameStatusMessage, "Renamed to: new.txt")
    }

    func test_renameFile_emptyName_setsValidationError() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e1", name: "old.txt", path: "/old.txt")

        await viewModel.renameFile(item, to: "  ")

        XCTAssertEqual(viewModel.renameStatusMessage, "New name cannot be empty.")
        XCTAssertNil(api.lastPatchRequest)
    }

    func test_renameFile_nameWithSlash_setsValidationError() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e1", name: "old.txt", path: "/old.txt")

        await viewModel.renameFile(item, to: "subdir/new.txt")

        XCTAssertEqual(viewModel.renameStatusMessage, "Name cannot contain '/'.")
        XCTAssertNil(api.lastPatchRequest)
    }

    func test_renameFile_apiConflict_setsErrorMessage() async {
        let api = MockRenameMoveAPIClient()
        api.patchHandler = { _, _ in
            throw NodeAPIError.api(statusCode: 409, errorCode: "FS_PATH_CONFLICT", message: "conflict")
        }
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e1", name: "old.txt", path: "/old.txt")

        await viewModel.renameFile(item, to: "new.txt")

        XCTAssertNotNil(viewModel.renameStatusMessage)
        XCTAssertEqual(viewModel.renameStatusMessage?.contains("Cannot rename"), true)
    }

    func test_renameFile_sameName_isNoOp() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e1", name: "same.txt", path: "/same.txt")

        await viewModel.renameFile(item, to: "same.txt")

        XCTAssertNil(viewModel.renameStatusMessage)
        XCTAssertNil(api.lastPatchRequest)
    }

    // MARK: - Move

    func test_moveFile_changesParentPathPreservingName() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e2", name: "doc.pdf", path: "/inbox/doc.pdf")

        await viewModel.moveFile(item, to: "/archive")

        XCTAssertEqual(api.lastPatchEntryId, "e2")
        XCTAssertEqual(api.lastPatchRequest?.newPath, "/archive/doc.pdf")
        XCTAssertEqual(viewModel.moveStatusMessage, "Moved to: /archive/doc.pdf")
    }

    func test_moveFile_toRoot_normalizesPath() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e3", name: "x.bin", path: "/folder/x.bin")

        await viewModel.moveFile(item, to: "/")

        XCTAssertEqual(api.lastPatchRequest?.newPath, "/x.bin")
    }

    func test_moveFile_sameDestination_isNoOp() async {
        let api = MockRenameMoveAPIClient()
        let viewModel = makeViewModel(apiClient: api)
        let item = makeFileItem(id: "e4", name: "stay.txt", path: "/folder/stay.txt")

        await viewModel.moveFile(item, to: "/folder")

        XCTAssertNil(api.lastPatchRequest)
        XCTAssertNil(viewModel.moveStatusMessage)
    }

    // MARK: - Helpers exposed for testing

    func test_replaceLastPathComponent_handlesNestedPaths() {
        XCTAssertEqual(FilesViewModel.replaceLastPathComponent(in: "/a/b.txt", with: "c.txt"), "/a/c.txt")
        XCTAssertEqual(FilesViewModel.replaceLastPathComponent(in: "/x.txt", with: "y.txt"), "/y.txt")
        XCTAssertEqual(FilesViewModel.replaceLastPathComponent(in: "/a/b/c.txt", with: "d.txt"), "/a/b/d.txt")
    }

    func test_normalizeParentPath_alwaysReturnsAbsoluteWithoutTrailingSlash() {
        XCTAssertEqual(FilesViewModel.normalizeParentPath(""), "/")
        XCTAssertEqual(FilesViewModel.normalizeParentPath("/"), "/")
        XCTAssertEqual(FilesViewModel.normalizeParentPath("/foo/"), "/foo")
        XCTAssertEqual(FilesViewModel.normalizeParentPath("/foo"), "/foo")
        XCTAssertEqual(FilesViewModel.normalizeParentPath("foo"), "/foo")
    }

    // MARK: - Setup

    private func makeViewModel(apiClient: NodeAPIClientProtocol) -> FilesViewModel {
        FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryRenameMoveSyncStore(),
            syncNamespaceProvider: { "tester" },
            filesRepository: StubRenameMoveRepository()
        )
    }

    private func makeFileItem(id: String, name: String, path: String) -> FileItem {
        FileItem(
            id: id,
            name: name,
            path: path,
            detail: "1 KB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )
    }
}

private final class MockRenameMoveAPIClient: NodeAPIClientProtocol {
    var patchHandler: ((String, FsPatchEntryRequest) throws -> FsEntryResponse)?
    private(set) var lastPatchEntryId: String?
    private(set) var lastPatchRequest: FsPatchEntryRequest?

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}

    func patchEntry(token: String, entryId: String, request: FsPatchEntryRequest) async throws -> FsEntryResponse {
        lastPatchEntryId = entryId
        lastPatchRequest = request
        if let handler = patchHandler {
            return try handler(entryId, request)
        }
        return FsEntryResponse(
            entryId: entryId,
            path: request.newPath,
            entryType: .file,
            sizeBytes: 0,
            checksum: nil,
            version: 2,
            updatedAt: Date(),
            deleted: false
        )
    }
}

private final class InMemoryRenameMoveSyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubRenameMoveRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
