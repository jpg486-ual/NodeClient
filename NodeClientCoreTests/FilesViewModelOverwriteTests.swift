//  TDD para el flujo de overwrite cuando un upload
//  colisiona con un path ya asignado por el backend.
//
//  Diagnóstico: el backend reserva los paths de por vida (incluso tras
//  DELETE el path sigue ocupado por la entry deleted=true). Pre-fix el
//  cliente generaba siempre un UUID nuevo y el upload fallaba con
//  `409 FS_PATH_CONFLICT` sin opción al usuario.
//
//  Fix:
//    - Antes del upload, lookup del path en el snapshot SQLite local.
//    - Si encuentra entry `deleted=true` → silent overwrite (revivir).
//    - Si encuentra entry `deleted=false` → setea `pendingOverwrite` y
//      la View muestra confirmation dialog.
//    - El upload (cuando se confirma o silent) reusa el `entryId`
//      canónico, incrementando version y actualizando size/checksum.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelOverwriteTests: XCTestCase {
    func test_uploadFile_collisionWithDeletedEntry_silentlyOverwritesReusingEntryId() async throws {
        let snapshot = makeSnapshot(entries: [
            makeEntry(entryId: "ghost-1", path: "/notes.txt", deleted: true)
        ])
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: snapshot))

        let url = try writeTempFile(name: "notes.txt", contents: Data("nuevo contenido".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertNil(viewModel.pendingOverwrite, "Para entries deleted, no se pide confirmación.")
        XCTAssertEqual(
            api.lastUpsertEntryId,
            "ghost-1",
            "Debe reusar el entryId canónico del entry deleted, no generar UUID nuevo."
        )
        XCTAssertTrue(
            (viewModel.uploadStatusMessage ?? "").hasPrefix("Upload completed"),
            "Upload debe completar con éxito tras el revive."
        )
    }

    func test_uploadFile_collisionWithLiveEntry_setsPendingOverwriteWithoutCallingApi() async throws {
        let snapshot = makeSnapshot(entries: [
            makeEntry(entryId: "alive-1", path: "/notes.txt", deleted: false)
        ])
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: snapshot))

        let url = try writeTempFile(name: "notes.txt", contents: Data("intento sobreescritura".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertEqual(viewModel.pendingOverwrite?.existingEntryId, "alive-1")
        XCTAssertEqual(viewModel.pendingOverwrite?.fileName, "notes.txt")
        XCTAssertEqual(viewModel.pendingOverwrite?.path, "/notes.txt")
        XCTAssertEqual(api.upsertCalls.count, 0, "No se debe contactar al backend hasta confirmar.")
    }

    func test_confirmPendingOverwrite_invokesUploadReusingExistingEntryId() async throws {
        let snapshot = makeSnapshot(entries: [
            makeEntry(entryId: "alive-2", path: "/contract.pdf", deleted: false)
        ])
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: snapshot))

        let v2Bytes = Data("v2-fresh-content".utf8)
        let url = try writeTempFile(name: "contract.pdf", contents: v2Bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)
        let pending = try XCTUnwrap(viewModel.pendingOverwrite)

        await viewModel.confirmPendingOverwrite(pending)

        XCTAssertNil(viewModel.pendingOverwrite, "Tras confirmar, propuesta limpia.")
        XCTAssertEqual(
            api.lastUpsertEntryId,
            "alive-2",
            "Confirm debe reusar entryId existente."
        )
        // Verificación clave del fix race-condition:
        // los chunks subidos al backend deben ser el payload v2 nuevo,
        // no quedarse vacíos si el race entre dialog dismiss y Task
        // hubiera limpiado pendingOverwrite antes de leer.
        let uploaded = api.chunkPayloads.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(uploaded, v2Bytes, "Los chunks deben contener el payload v2.")
        XCTAssertTrue((viewModel.uploadStatusMessage ?? "").hasPrefix("Upload completed"))
    }

    func test_confirmPendingOverwrite_survivesPendingClearedConcurrently() async throws {
        // Simula el race: tras setear pendingOverwrite, simulamos que el
        // dialog dismissa borrando la propiedad (cancelPendingOverwrite)
        // ANTES de que la Task asíncrona ejecute. El captured snapshot
        // del closure debe sobrevivir.
        let snapshot = makeSnapshot(entries: [
            makeEntry(entryId: "alive-race", path: "/race.txt", deleted: false)
        ])
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: snapshot))

        let url = try writeTempFile(name: "race.txt", contents: Data("nuevo".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)
        let captured = try XCTUnwrap(viewModel.pendingOverwrite)

        // Simula dismiss + cancel concurrente: limpia el state.
        viewModel.cancelPendingOverwrite()
        XCTAssertNil(viewModel.pendingOverwrite)

        // El user-tapped button llama confirm con el captured snapshot.
        await viewModel.confirmPendingOverwrite(captured)

        XCTAssertEqual(
            api.lastUpsertEntryId,
            "alive-race",
            "El snapshot capturado debe permitir el upload aunque pendingOverwrite ya esté nil."
        )
    }

    func test_cancelPendingOverwrite_clearsProposalWithoutUpload() async throws {
        let snapshot = makeSnapshot(entries: [
            makeEntry(entryId: "alive-3", path: "/keep.txt", deleted: false)
        ])
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: snapshot))

        let url = try writeTempFile(name: "keep.txt", contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)
        XCTAssertNotNil(viewModel.pendingOverwrite)

        viewModel.cancelPendingOverwrite()

        XCTAssertNil(viewModel.pendingOverwrite)
        XCTAssertEqual(api.upsertCalls.count, 0)
    }

    func test_uploadFile_noCollision_usesFreshUUIDFlow() async throws {
        // Snapshot vacío → flow legacy con UUID nuevo, sin pendingOverwrite.
        let api = MockOverwriteAPIClient()
        let viewModel = makeViewModel(apiClient: api, snapshotStore: SeededOverwriteSyncStore(snapshot: nil))

        let url = try writeTempFile(name: "fresh.txt", contents: Data("first time".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertNil(viewModel.pendingOverwrite)
        XCTAssertEqual(api.upsertCalls.count, 1)
        XCTAssertEqual(api.upsertCalls.first?.path, "/fresh.txt")
        // El entryId enviado es UUID nuevo; backend lo canonicaliza en
        // su response. El test mock usa el id que recibe.
    }

    // MARK: - Helpers

    private func makeViewModel(
        apiClient: NodeAPIClientProtocol,
        snapshotStore: FilesSyncStateStore
    ) -> FilesViewModel {
        FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: snapshotStore,
            syncNamespaceProvider: { "ns" },
            filesRepository: StubOverwriteRepository(),
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/x.bin") }
        )
    }

    private func makeSnapshot(entries: [FilesSyncEntry]) -> FilesSyncSnapshot {
        FilesSyncSnapshot(cursor: 1, entries: entries)
    }

    private func makeEntry(entryId: String, path: String, deleted: Bool) -> FilesSyncEntry {
        FilesSyncEntry(
            entryId: entryId,
            path: path,
            entryType: .file,
            sizeBytes: 42,
            checksum: "abc",
            version: 1,
            updatedAt: Date(),
            deleted: deleted
        )
    }

    private func writeTempFile(name: String, contents: Data) throws -> URL {
        // Crear un subdirectorio aislado para preservar el filename exacto
        // (sin prefijos UUID que contaminarían `lastPathComponent`).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, options: [.atomic])
        return url
    }
}

// MARK: - Mocks

private final class MockOverwriteAPIClient: NodeAPIClientProtocol, @unchecked Sendable {
    var upsertCalls: [FsUpsertEntryRequest] = []
    var chunkPayloads: [Data] = []
    private(set) var lastUpsertEntryId: String?

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        upsertCalls.append(request)
        lastUpsertEntryId = request.entryId
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

    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        FileUploadSessionResponse(
            sessionId: "s",
            entryId: request.entryId,
            uploadedBytes: 0,
            expectedSizeBytes: 0,
            status: "OPEN",
            updatedAt: Date()
        )
    }

    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        chunkPayloads.append(chunk)
        return FileUploadSessionResponse(
            sessionId: sessionId,
            entryId: "",
            uploadedBytes: offset + Int64(chunk.count),
            expectedSizeBytes: offset + Int64(chunk.count),
            status: "OPEN",
            updatedAt: Date()
        )
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        FileContentUploadResponse(entryId: "", sizeBytes: 0, checksum: "")
    }

    func logout(token: String) async throws {}
}

private final class SeededOverwriteSyncStore: FilesSyncStateStore {
    let snapshot: FilesSyncSnapshot?

    init(snapshot: FilesSyncSnapshot?) { self.snapshot = snapshot }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { snapshot }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubOverwriteRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
