//  TDD para upload/download con cifrado client-side.
//
//  Cuando la `EncryptionKeyVault.shared.currentKey`
//  está activa, el cliente cifra el plaintext antes de subirlo y descifra
//  el wireData antes de guardarlo. Si no hay key, el flow legacy (plain)
//  se mantiene intacto. Si emerge un archivo cifrado en download sin key,
//  mensaje legible al usuario.

import CryptoKit
import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelEncryptedTransferTests: XCTestCase {
    func test_uploadFile_withoutKey_sendsPlaintextChunks() async throws {
        let api = MockEncryptedFlowAPIClient()
        let vault = EncryptionKeyVault()  // sin key activa
        let viewModel = makeViewModel(apiClient: api, vault: vault)

        let payload = Data("hola mundo".utf8)
        let url = try writeTempFile(name: "plain.txt", contents: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        XCTAssertEqual(api.chunkPayloads.first, payload, "Sin key, los bytes subidos son el plaintext.")
        XCTAssertEqual(
            viewModel.uploadStatusMessage?.hasPrefix("Upload completed:"),
            true,
            "Mensaje plain (sin '(encrypted)')."
        )
    }

    func test_uploadFile_withKey_encryptsBeforeSendingChunks() async throws {
        let api = MockEncryptedFlowAPIClient()
        let key = SymmetricKey(size: .bits256)
        let vault = EncryptionKeyVault()
        vault.unlock(key: key, forUsername: "demo-jose")

        let viewModel = makeViewModel(apiClient: api, vault: vault)
        let plaintext = Data("contenido sensible".utf8)
        let url = try writeTempFile(name: "secret.txt", contents: plaintext)
        defer { try? FileManager.default.removeItem(at: url) }

        await viewModel.uploadFile(from: url)

        let uploaded = api.chunkPayloads.reduce(into: Data()) { $0.append($1) }
        XCTAssertNotEqual(uploaded, plaintext, "Con key, los bytes subidos NO deben ser el plaintext.")
        // El upload streaming emite siempre formato NCE3 chunked
        // (único formato cifrado soportado por el cliente).
        XCTAssertTrue(EncryptedFile.isV3Magic(uploaded),
                      "El upload con key debe emitir wire NCE3.")

        // Round-trip streaming: descifrar el wire NCE3 recupera el plaintext.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-decrypt-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try await Nce3StreamingCipher.decryptStreaming(
            wireBytes: AsyncStream<UInt8> { continuation in
                for byte in uploaded { continuation.yield(byte) }
                continuation.finish()
            },
            key: key,
            outputURL: outURL
        )
        let recovered = try Data(contentsOf: outURL)
        XCTAssertEqual(recovered, plaintext)

        XCTAssertEqual(
            viewModel.uploadStatusMessage?.hasPrefix("Upload completed (encrypted):"),
            true,
            "Mensaje debe indicar '(encrypted)' explícitamente."
        )
    }

    func test_downloadFile_withEncryptedBlobAndMatchingKey_decryptsBeforeSave() async throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("payload protegido".utf8)
        let wireData = try await Self.makeNce3Wire(plaintext: plaintext, key: key)

        let api = MockEncryptedFlowAPIClient()
        api.downloadResponse = wireData
        let vault = EncryptionKeyVault()
        vault.unlock(key: key, forUsername: "demo-jose")

        var savedPayload: Data?
        let viewModel = makeViewModel(
            apiClient: api,
            vault: vault,
            fileSaver: { data, _ in
                savedPayload = data
                return URL(fileURLWithPath: "/tmp/decrypted.bin")
            }
        )

        await viewModel.downloadFile(makeFileItem(id: "f1", name: "secret.bin"))

        XCTAssertEqual(savedPayload, plaintext, "El archivo guardado en disco debe ser el plaintext.")
        XCTAssertNil(viewModel.downloadStatusMessage?.contains("error") ?? false ? "" : nil)
    }

    func test_downloadFile_withEncryptedBlob_butNoKey_setsLegibleErrorMessage() async throws {
        let key = SymmetricKey(size: .bits256)
        let wireData = try await Self.makeNce3Wire(plaintext: Data("x".utf8), key: key)

        let api = MockEncryptedFlowAPIClient()
        api.downloadResponse = wireData
        let vault = EncryptionKeyVault()  // sin key

        var savedPayload: Data?
        let viewModel = makeViewModel(
            apiClient: api,
            vault: vault,
            fileSaver: { data, _ in
                savedPayload = data
                return URL(fileURLWithPath: "/tmp/should-not-save.bin")
            }
        )

        await viewModel.downloadFile(makeFileItem(id: "f2", name: "encrypted.bin"))

        XCTAssertNil(savedPayload, "No debe guardar archivo si está cifrado y no hay key.")
        XCTAssertEqual(viewModel.downloadStatusMessage,
                       "Este archivo está cifrado. Desbloquea el cifrado en Settings → Cifrado para abrirlo.")
    }

    func test_downloadFile_withPlaintextBlob_andActiveKey_savesWithoutDecrypt() async throws {
        // Compatibilidad backwards: archivos subidos antes de activar
        // cifrado siguen siendo accesibles aunque haya key activa.
        let plaintext = Data("compat-legacy".utf8)
        let api = MockEncryptedFlowAPIClient()
        api.downloadResponse = plaintext
        let vault = EncryptionKeyVault()
        vault.unlock(key: SymmetricKey(size: .bits256), forUsername: "demo-jose")

        var savedPayload: Data?
        let viewModel = makeViewModel(
            apiClient: api,
            vault: vault,
            fileSaver: { data, _ in
                savedPayload = data
                return URL(fileURLWithPath: "/tmp/plain.bin")
            }
        )

        await viewModel.downloadFile(makeFileItem(id: "f3", name: "legacy.bin"))

        XCTAssertEqual(savedPayload, plaintext, "Sin magic NCE3 → guardar tal cual.")
    }

    // MARK: - Helpers

    private func makeViewModel(
        apiClient: NodeAPIClientProtocol,
        vault: EncryptionKeyVault,
        fileSaver: @escaping (Data, String) throws -> URL = { _, _ in URL(fileURLWithPath: "/tmp/x.bin") }
    ) -> FilesViewModel {
        FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryEncryptedFlowSyncStore(),
            syncNamespaceProvider: { "demo-jose" },
            filesRepository: StubEncryptedFlowRepository(),
            fileSaver: fileSaver,
            encryptionKeyVault: vault
        )
    }

    private func makeFileItem(id: String, name: String) -> FileItem {
        FileItem(
            id: id,
            name: name,
            path: "/\(name)",
            detail: "1 KB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )
    }

    private func writeTempFile(name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encflow-\(UUID().uuidString)-\(name)")
        try contents.write(to: url, options: [.atomic])
        return url
    }

    /// Construye un wire NCE3 in-memory cifrando `plaintext` con `key`.
    /// Útil para fabricar la respuesta del API mock en los tests de
    /// download cifrado sin levantar el flujo completo de upload.
    private static func makeNce3Wire(plaintext: Data, key: SymmetricKey) async throws -> Data {
        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-fixture-\(UUID().uuidString).bin")
        try plaintext.write(to: plainURL)
        defer { try? FileManager.default.removeItem(at: plainURL) }

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: plainURL,
            key: key,
            chunkPlainSize: 1_024
        ) { chunk in
            wire.append(chunk)
        }
        return wire
    }
}

// MARK: - Mock que captura chunks crudos del upload

private final class MockEncryptedFlowAPIClient: NodeAPIClientProtocol, @unchecked Sendable {
    var downloadResponse = Data()
    var chunkPayloads: [Data] = []

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        onProgress(1.0)
        return downloadResponse
    }

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        FsEntryResponse(
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
            sessionId: "sess",
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

private final class InMemoryEncryptedFlowSyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubEncryptedFlowRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
