//  TDD del auto-recovery silencioso de 409 en `performUpload`.
//
//  Política aplicada (decidida por el operador):
//  - Staleness (`FILE_UPLOAD_*_CONFLICT`, `FILE_CONTENT_CONFLICT`):
//    refetch silencioso del árbol + retry una sola vez.
//  - `FS_PATH_CONFLICT`: refetch silencioso, luego silent overwrite si
//    el entry traído está `deleted=true`, o auto-disparo del
//    `pendingOverwrite` si está vivo.
//  - Si tras la única reintento sigue fallando, surface toast.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelUploadConflictTests: XCTestCase {
    func test_uploadFile_whenStalenessConflictOnComplete_silentlyRefreshesAndRetries() async throws {
        let api = SequencedConflictAPIClient()
        api.upsertResults = [
            .failure(.api(statusCode: 409, errorCode: "FILE_UPLOAD_COMPLETE_CONFLICT", message: "stale")),
            .successDefault
        ]
        let observability = InMemoryObservabilityStore()
        let viewModel = makeViewModel(api: api, repo: FakeRefreshRepository(), observability: observability)

        let url = try writeTempFile(name: "report.pdf", contents: Data("v2".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertEqual(api.upsertCalls.count, 2, "Tras el 409 staleness debe haber un único retry.")
        XCTAssertTrue(
            (viewModel.uploadStatusMessage ?? "").hasPrefix("Upload completed"),
            "El retry debe completar el upload sin que el usuario lo perciba."
        )
        XCTAssertEqual(observability.counter("upload.autoRetry.attempted"), 1)
        XCTAssertEqual(observability.counter("upload.success"), 1)
        XCTAssertEqual(observability.counter("upload.autoRetry.exhausted"), 0)
    }

    func test_uploadFile_whenStalenessConflictTwiceInARow_surfacesToast() async throws {
        let api = SequencedConflictAPIClient()
        api.upsertResults = [
            .failure(.api(statusCode: 409, errorCode: "FILE_UPLOAD_COMPLETE_CONFLICT", message: "stale")),
            .failure(.api(statusCode: 409, errorCode: "FILE_UPLOAD_COMPLETE_CONFLICT", message: "stale again"))
        ]
        let observability = InMemoryObservabilityStore()
        let viewModel = makeViewModel(api: api, repo: FakeRefreshRepository(), observability: observability)

        let url = try writeTempFile(name: "doc.txt", contents: Data("a".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertEqual(api.upsertCalls.count, 2)
        XCTAssertNotNil(viewModel.uploadStatusMessage)
        XCTAssertFalse(
            (viewModel.uploadStatusMessage ?? "").hasPrefix("Upload completed"),
            "Tras agotar el budget, debe surface toast de error."
        )
        XCTAssertEqual(observability.counter("upload.autoRetry.attempted"), 1)
        XCTAssertEqual(observability.counter("upload.autoRetry.exhausted"), 1)
        XCTAssertEqual(
            observability.counter("upload.failure"),
            1,
            "Un upload + retry fracasado se contabiliza como 1 failure (el final)."
        )
    }

    func test_uploadFile_whenFsPathConflict_triggersPendingOverwriteAfterSilentRefetch() async throws {
        let store = MutableSeededSyncStore(snapshot: nil) // snapshot inicial vacío
        let api = SequencedConflictAPIClient()
        api.upsertResults = [
            .failure(.api(statusCode: 409, errorCode: "FS_PATH_CONFLICT", message: "exists"))
        ]
        let repo = FakeRefreshRepository()
        // El refetch revela un entry vivo en ese path (otro cliente lo subió).
        repo.onSynchronize = {
            store.snapshot = FilesSyncSnapshot(
                cursor: 7,
                entries: [Self.makeEntry(entryId: "remote-1", path: "/notes.txt", deleted: false)]
            )
            return []
        }
        let observability = InMemoryObservabilityStore()
        let viewModel = makeViewModel(
            api: api,
            repo: repo,
            observability: observability,
            store: store
        )

        let url = try writeTempFile(name: "notes.txt", contents: Data("local".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertEqual(
            viewModel.pendingOverwrite?.existingEntryId,
            "remote-1",
            "Tras silent refetch, debe disparar el diálogo con el entry recién traído."
        )
        XCTAssertEqual(viewModel.pendingOverwrite?.path, "/notes.txt")
        XCTAssertEqual(api.upsertCalls.count, 1, "No se debe reintentar el upsert hasta que el usuario decida.")
        XCTAssertNil(
            viewModel.uploadStatusMessage,
            "El usuario no ve toast de error — está esperando su decisión."
        )
        XCTAssertEqual(observability.counter("upload.autoRetry.attempted"), 1)
    }

    func test_uploadFile_whenFsPathConflictAndExistingDeleted_silentOverwrite() async throws {
        let store = MutableSeededSyncStore(snapshot: nil)
        let api = SequencedConflictAPIClient()
        api.upsertResults = [
            .failure(.api(statusCode: 409, errorCode: "FS_PATH_CONFLICT", message: "exists")),
            .successDefault
        ]
        let repo = FakeRefreshRepository()
        // El refetch revela un entry deleted=true: silent revive.
        repo.onSynchronize = {
            store.snapshot = FilesSyncSnapshot(
                cursor: 9,
                entries: [Self.makeEntry(entryId: "ghost-1", path: "/zombie.txt", deleted: true)]
            )
            return []
        }
        let observability = InMemoryObservabilityStore()
        let viewModel = makeViewModel(
            api: api,
            repo: repo,
            observability: observability,
            store: store
        )

        let url = try writeTempFile(name: "zombie.txt", contents: Data("rebirth".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertNil(viewModel.pendingOverwrite, "Si el entry está deleted, no se pide confirmación.")
        XCTAssertEqual(api.upsertCalls.count, 2, "Retry con el entryId reusado del entry deleted.")
        XCTAssertEqual(api.upsertCalls.last?.entryId, "ghost-1")
        XCTAssertTrue(
            (viewModel.uploadStatusMessage ?? "").hasPrefix("Upload completed"),
            "Resucitación silenciosa exitosa."
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        api: NodeAPIClientProtocol,
        repo: FilesRepositoryProtocol,
        observability: ObservabilityStore,
        store: FilesSyncStateStore = MutableSeededSyncStore(snapshot: nil)
    ) -> FilesViewModel {
        FilesViewModel(
            apiClient: api,
            sessionTokenProvider: { "token" },
            syncStateStore: store,
            syncNamespaceProvider: { "ns" },
            filesRepository: repo,
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/x.bin") },
            observabilityStore: observability
        )
    }

    private static func makeEntry(entryId: String, path: String, deleted: Bool) -> FilesSyncEntry {
        FilesSyncEntry(
            entryId: entryId,
            path: path,
            entryType: .file,
            sizeBytes: 1,
            checksum: "abc",
            version: 1,
            updatedAt: Date(),
            deleted: deleted
        )
    }

    private func writeTempFile(name: String, contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, options: [.atomic])
        return url
    }
}

// MARK: - Mocks

/// Resultado encapsulado para `upsertEntry` — éxito devuelve un
/// `FsEntryResponse` derivado del request, para no tener que construir
/// fixtures completos en cada test.
private enum UpsertResult {
    case successDefault
    case failure(NodeAPIError)
}

private final class SequencedConflictAPIClient: NodeAPIClientProtocol, @unchecked Sendable {
    var upsertResults: [UpsertResult] = []
    var upsertCalls: [FsUpsertEntryRequest] = []

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: "", quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        upsertCalls.append(request)
        let result = upsertResults.isEmpty ? .successDefault : upsertResults.removeFirst()
        switch result {
        case .successDefault:
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

        case let .failure(error):
            throw error
        }
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
        FileUploadSessionResponse(
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

/// Repository de tests cuyo `synchronizeFiles` ejecuta un closure
/// inyectado por el test (típicamente para mutar el syncStateStore
/// simulando que el server devolvió un snapshot fresco).
private final class FakeRefreshRepository: FilesRepositoryProtocol, @unchecked Sendable {
    var onSynchronize: (() -> [FileItem])?

    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] {
        onSynchronize?() ?? []
    }
}

private final class MutableSeededSyncStore: FilesSyncStateStore, @unchecked Sendable {
    var snapshot: FilesSyncSnapshot?

    init(snapshot: FilesSyncSnapshot?) { self.snapshot = snapshot }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { snapshot }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) { self.snapshot = snapshot }
    func clearSnapshot(namespace: String) { snapshot = nil }
}

/// Observabilidad in-memory para verificar contadores en assertions.
private final class InMemoryObservabilityStore: ObservabilityStore, @unchecked Sendable {
    private var counters: [String: Int] = [:]

    func counter(_ name: String) -> Int { counters[name] ?? 0 }

    func log(level: LogLevel, category: String, event: String, message: String?, metadata: [String: String]) {}

    func incrementCounter(_ name: String) {
        counters[name, default: 0] += 1
    }

    func recordDuration(_ name: String, milliseconds: Double) {}

    func counter(named name: String) -> Int { counters[name] ?? 0 }

    func latestDuration(named name: String) -> Double? { nil }

    func recentTraces(limit: Int, minimumLevel: LogLevel?) -> [DiagnosticTrace] { [] }

    func reset() { counters.removeAll() }
}
