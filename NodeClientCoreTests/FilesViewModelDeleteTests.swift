//  TDD para `FilesViewModel.deleteFile`.
//  El cliente expone delete permanente con confirmación.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelDeleteTests: XCTestCase {
    func test_deleteFile_callsDedicatedDeleteEntryEndpoint() async {
        // El cliente usa `deleteEntry` (DELETE /fs/entries/{id})
        let apiClient = MockDeleteAPIClient()
        let viewModel = makeViewModel(apiClient: apiClient)
        let item = makeFileItem(id: "entry-1", name: "doc.pdf")

        await viewModel.deleteFile(item)

        XCTAssertEqual(apiClient.lastDeleteEntryId, "entry-1")
        XCTAssertEqual(apiClient.deleteCallCount, 1)
    }

    func test_deleteFile_success_setsConfirmationMessage() async {
        let viewModel = makeViewModel(apiClient: MockDeleteAPIClient())
        let item = makeFileItem(id: "entry-2", name: "report.pdf")

        await viewModel.deleteFile(item)

        XCTAssertEqual(viewModel.deleteStatusMessage, "Archivo eliminado: report.pdf")
    }

    func test_deleteFile_apiError_setsErrorMessageAndKeepsFile() async {
        let apiClient = MockDeleteAPIClient()
        apiClient.deleteHandler = { _ in
            throw NodeAPIError.api(statusCode: 500, errorCode: "INTERNAL", message: "boom")
        }
        let viewModel = makeViewModel(apiClient: apiClient)
        let item = makeFileItem(id: "entry-3", name: "fail.pdf")

        await viewModel.deleteFile(item)

        XCTAssertNotNil(viewModel.deleteStatusMessage)
        XCTAssertTrue(viewModel.deleteStatusMessage?.contains("No se ha podido eliminar") ?? false)
    }

    func test_deleteFile_withoutSession_setsErrorMessageAndDoesNotCallApi() async {
        let apiClient = MockDeleteAPIClient()
        let viewModel = makeViewModel(apiClient: apiClient, tokenProvider: { nil })
        let item = makeFileItem(id: "entry-4", name: "x.pdf")

        await viewModel.deleteFile(item)

        XCTAssertEqual(apiClient.deleteCallCount, 0)
        XCTAssertEqual(viewModel.deleteStatusMessage, "No hay una sesión activa. Inicia sesión.")
    }

    func test_clearDeleteStatus_resetsMessageToNil() async {
        let viewModel = makeViewModel(apiClient: MockDeleteAPIClient())
        let item = makeFileItem(id: "entry-5", name: "ok.pdf")

        await viewModel.deleteFile(item)
        XCTAssertNotNil(viewModel.deleteStatusMessage)

        viewModel.clearDeleteStatus()
        XCTAssertNil(viewModel.deleteStatusMessage)
    }

    // MARK: - Helpers

    private func makeViewModel(
        apiClient: NodeAPIClientProtocol,
        tokenProvider: @escaping () -> String? = { "token" }
    ) -> FilesViewModel {
        FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: tokenProvider,
            syncStateStore: InMemoryDeleteSyncStore(),
            syncNamespaceProvider: { "tester" },
            filesRepository: StubDeleteRepository()
        )
    }

    private func makeFileItem(id: String, name: String) -> FileItem {
        FileItem(
            id: id,
            name: name,
            detail: "1 KB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )
    }
}

private final class MockDeleteAPIClient: NodeAPIClientProtocol {
    var upsertHandler: ((FsUpsertEntryRequest) throws -> FsEntryResponse)?
    var deleteHandler: ((String) throws -> Void)?
    private(set) var lastUpsertRequest: FsUpsertEntryRequest?
    private(set) var lastDeleteEntryId: String?
    private(set) var deleteCallCount: Int = 0

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 1, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        lastUpsertRequest = request
        if let handler = upsertHandler {
            return try handler(request)
        }
        return FsEntryResponse(
            entryId: request.entryId,
            path: request.path,
            entryType: request.entryType == .directory ? .directory : .file,
            sizeBytes: request.sizeBytes ?? 0,
            checksum: request.checksum,
            version: 1,
            updatedAt: Date(),
            deleted: request.deleted
        )
    }

    func deleteEntry(token: String, entryId: String) async throws {
        lastDeleteEntryId = entryId
        deleteCallCount += 1
        if let handler = deleteHandler {
            try handler(entryId)
        }
    }

    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        FileUploadSessionResponse(
            sessionId: "s",
            entryId: request.entryId,
            uploadedBytes: 0,
            expectedSizeBytes: 0,
            status: "ACTIVE",
            updatedAt: Date()
        )
    }

    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        FileUploadSessionResponse(
            sessionId: sessionId,
            entryId: "",
            uploadedBytes: 0,
            expectedSizeBytes: 0,
            status: "ACTIVE",
            updatedAt: Date()
        )
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        FileContentUploadResponse(entryId: "", sizeBytes: 0, checksum: "")
    }
}

private final class InMemoryDeleteSyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubDeleteRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
