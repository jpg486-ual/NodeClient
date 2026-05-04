//  Tests download streaming verdadero (sin RAM buffer del wire).

import CryptoKit
import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class EncryptedFileTransferStreamingDownloadTests: XCTestCase {
    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    private func tempURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nc17bis-\(UUID().uuidString)-\(suffix)")
    }

    // MARK: - NCE3 streaming round-trip

    func test_downloadStreamingToFile_decryptsNCE3StreamFromAsyncBytes() async throws {
        let key = makeKey()
        let plaintext = Data((0..<3_500).map { UInt8($0 & 0xFF) }) // 3500 bytes

        // Cifrar a un wire NCE3 in-memory (simula lo que el server enviaría
        // si el upload usó `prepareWireUpload`). chunkSize 1024 → 4 chunks
        // (1024+1024+1024+428).
        let plainURL = tempURL("plain.bin")
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
        XCTAssertTrue(EncryptedFile.isV3Magic(wire))

        let api = StreamingDownloadStubAPIClient(payload: wire)
        let transfer = EncryptedFileTransfer(apiClient: api)

        let outURL = tempURL("decrypted.bin")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await transfer.downloadStreamingToFile(
            entryId: "e1",
            token: "t",
            outputURL: outURL,
            key: key
        )

        let recovered = try Data(contentsOf: outURL)
        XCTAssertEqual(recovered, plaintext, "Round-trip NCE3 streaming debe ser byte-perfect.")
        // El adapter NO debe haber sido llamado
        // por el path monolítico legacy `downloadFileContent`.
        XCTAssertEqual(
            api.monolithicCallCount,
            0,
            "El download debe usar `downloadFileContentBytes`, no el path legacy in-memory."
        )
        XCTAssertEqual(api.streamingCallCount, 1)
    }

    // MARK: - Plain (sin magic) streaming a disco

    func test_downloadStreamingToFile_writesPlainBytesDirectlyToDisk() async throws {
        let plaintext = Data("plaintext content without magic".utf8)
        let api = StreamingDownloadStubAPIClient(payload: plaintext)
        let transfer = EncryptedFileTransfer(apiClient: api)

        let outURL = tempURL("plain-out.bin")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await transfer.downloadStreamingToFile(
            entryId: "e2",
            token: "t",
            outputURL: outURL,
            key: nil
        )

        XCTAssertEqual(try Data(contentsOf: outURL), plaintext)
        XCTAssertEqual(api.streamingCallCount, 1)
    }

    func test_downloadStreamingToFile_writesPlainLargerThanInternalBufferCorrectly() async throws {
        // 200 KiB (el buffer interno es 64 KiB → ≥3 flushes).
        let plaintext = Data(repeating: 0x33, count: 200 * 1_024)
        let api = StreamingDownloadStubAPIClient(payload: plaintext)
        let transfer = EncryptedFileTransfer(apiClient: api)

        let outURL = tempURL("plain-large.bin")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await transfer.downloadStreamingToFile(
            entryId: "e3",
            token: "t",
            outputURL: outURL,
            key: nil
        )
        XCTAssertEqual(try Data(contentsOf: outURL), plaintext)
    }

    // MARK: - Errors

    func test_downloadStreamingToFile_throwsKeyRequiredWhenEncryptedAndNoKey() async throws {
        let key = makeKey()
        let plaintext = Data("secret".utf8)
        let plainURL = tempURL("plain.bin")
        try plaintext.write(to: plainURL)
        defer { try? FileManager.default.removeItem(at: plainURL) }

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: plainURL,
            key: key,
            chunkPlainSize: 64
        ) { wire.append($0) }

        let api = StreamingDownloadStubAPIClient(payload: wire)
        let transfer = EncryptedFileTransfer(apiClient: api)

        let outURL = tempURL("never.bin")
        defer { try? FileManager.default.removeItem(at: outURL) }

        do {
            try await transfer.downloadStreamingToFile(
                entryId: "e5",
                token: "t",
                outputURL: outURL,
                key: nil
            )
            XCTFail("Expected keyRequiredButMissing")
        } catch {
            XCTAssertEqual(error as? EncryptedFileTransferError, .keyRequiredButMissing)
        }
    }

    // MARK: - Empty file

    func test_downloadStreamingToFile_handlesEmptyPayloadAsPlain() async throws {
        let api = StreamingDownloadStubAPIClient(payload: Data())
        let transfer = EncryptedFileTransfer(apiClient: api)

        let outURL = tempURL("empty.bin")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await transfer.downloadStreamingToFile(
            entryId: "e6",
            token: "t",
            outputURL: outURL,
            key: nil
        )
        XCTAssertEqual(try Data(contentsOf: outURL), Data())
    }
}

// MARK: - Stub API client

/// Mock minimalista que implementa `downloadFileContentBytes` directamente
/// (sin pasar por la default extension del protocol). Permite contar
/// llamadas separadas a la versión streaming vs la monolítica legacy
private final class StreamingDownloadStubAPIClient: NodeAPIClientProtocol, @unchecked Sendable {
    let payload: Data
    private(set) var streamingCallCount = 0
    private(set) var monolithicCallCount = 0

    init(payload: Data) {
        self.payload = payload
    }

    // Required protocol stubs (mínimos para satisfacer la compilación).
    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: "", quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func logout(token: String) async throws {}

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
            uploadedBytes: offset + Int64(chunk.count),
            expectedSizeBytes: 0,
            status: "ACTIVE",
            updatedAt: Date()
        )
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        FileContentUploadResponse(entryId: "", sizeBytes: 0, checksum: "")
    }

    // Versión monolítica: incrementa contador para detectar uso indebido.
    func downloadFileContent(
        token: String,
        entryId: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        monolithicCallCount += 1
        return payload
    }

    // Emite cada byte del payload via
    // AsyncThrowingStream y reporta `expectedLength`.
    func downloadFileContentBytes(
        token: String,
        entryId: String
    ) async throws -> (stream: AsyncThrowingStream<UInt8, Error>, expectedLength: Int64) {
        streamingCallCount += 1
        let bytes = Array(payload)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        return (stream, Int64(bytes.count))
    }
}
