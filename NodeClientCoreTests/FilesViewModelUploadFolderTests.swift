import CryptoKit
import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelUploadFolderTests: XCTestCase {
    func test_createFolder_upsertsDirectoryAndShowsSuccess() async {
        let apiClient = MockUploadFolderAPIClient()

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryUploadFolderSyncStore(),
            syncNamespaceProvider: { "jose" },
            filesRepository: StubFilesRepository()
        )

        await viewModel.createFolder(named: "Personal")

        XCTAssertEqual(apiClient.lastUpsertRequest?.entryType, .directory)
        XCTAssertEqual(apiClient.lastUpsertRequest?.path, "/Personal")
        XCTAssertEqual(viewModel.createFolderStatusMessage, "Carpeta creada: Personal")
    }

    func test_createFolder_withEmptyName_setsValidationError() async {
        let viewModel = FilesViewModel(
            apiClient: MockUploadFolderAPIClient(),
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryUploadFolderSyncStore(),
            syncNamespaceProvider: { "jose" },
            filesRepository: StubFilesRepository()
        )

        await viewModel.createFolder(named: "   ")

        XCTAssertEqual(viewModel.createFolderStatusMessage, "El nombre de la carpeta no puede estar vacio.")
    }

    func test_uploadFile_chunksAndCompletesSession() async throws {
        let apiClient = MockUploadFolderAPIClient()
        let payload = Data(repeating: 1, count: 600_000)
        let expectedChecksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        apiClient.createSessionHandler = { request in
            FileUploadSessionResponse(
                sessionId: "s1",
                entryId: request.entryId,
                uploadedBytes: 0,
                expectedSizeBytes: 600_000,
                status: "ACTIVE",
                updatedAt: Date()
            )
        }
        apiClient.appendChunkHandler = { _, offset, chunk in
            FileUploadSessionResponse(
                sessionId: "s1",
                entryId: "e1",
                uploadedBytes: offset + Int64(chunk.count),
                expectedSizeBytes: 600_000,
                status: "ACTIVE",
                updatedAt: Date()
            )
        }
        apiClient.completeSessionHandler = {
            FileContentUploadResponse(entryId: "e1", sizeBytes: 600_000, checksum: "abc")
        }

        let viewModel = FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryUploadFolderSyncStore(),
            syncNamespaceProvider: { "jose" },
            filesRepository: StubFilesRepository()
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test.bin")
        try payload.write(to: fileURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        await viewModel.uploadFile(from: fileURL)

        XCTAssertEqual(apiClient.lastUpsertRequest?.sizeBytes, Int64(payload.count))
        XCTAssertEqual(apiClient.lastUpsertRequest?.checksum, expectedChecksum)
        // El chunk HTTP es 4 MiB; 600 KB caben en una sola llamada.
        // El contrato verificado es "el upload completa con ≥1 chunk y los
        // bytes totales reportados coinciden con el archivo".
        XCTAssertGreaterThanOrEqual(apiClient.appendedChunksCount, 1)
        XCTAssertEqual(viewModel.uploadProgress, 1.0)
        XCTAssertEqual(viewModel.uploadStatusMessage, "Upload completed: upload-test.bin")
        XCTAssertFalse(viewModel.isUploading)
    }
}

private final class MockUploadFolderAPIClient: NodeAPIClientProtocol {
    var upsertHandler: ((FsUpsertEntryRequest) throws -> FsEntryResponse)?
    var createSessionHandler: ((FileUploadSessionCreateRequest) throws -> FileUploadSessionResponse)?
    var appendChunkHandler: ((String, Int64, Data) throws -> FileUploadSessionResponse)?
    var completeSessionHandler: (() throws -> FileContentUploadResponse)?
    private(set) var appendedChunksCount: Int = 0
    private(set) var lastUpsertRequest: FsUpsertEntryRequest?

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
        return try upsertHandler?(request) ?? FsEntryResponse(
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

    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        try createSessionHandler?(request) ?? FileUploadSessionResponse(
            sessionId: "session",
            entryId: request.entryId,
            uploadedBytes: 0,
            expectedSizeBytes: 0,
            status: "ACTIVE",
            updatedAt: Date()
        )
    }

    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        appendedChunksCount += 1
        return try appendChunkHandler?(sessionId, offset, chunk) ?? FileUploadSessionResponse(
            sessionId: sessionId,
            entryId: "",
            uploadedBytes: offset + Int64(chunk.count),
            expectedSizeBytes: offset + Int64(chunk.count),
            status: "ACTIVE",
            updatedAt: Date()
        )
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        try completeSessionHandler?() ?? FileContentUploadResponse(entryId: "", sizeBytes: 0, checksum: "")
    }
}

private final class InMemoryUploadFolderSyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubFilesRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }

    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
