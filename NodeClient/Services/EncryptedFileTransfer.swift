//  EncryptedFileTransfer — helper de alto nivel para el flujo
//  upload/download con cifrado modo A.
//
//  Flujo upload (streaming):
//    1. prepareWireUpload(plaintextURL, key?) → PreparedUpload con wireURL,
//       wireSize y wireChecksum (calcula SHA-256 del wire al vuelo, sin
//       cargar el archivo en RAM). Para key != nil cifra streaming a temp
//       NCE3; para key nil usa el archivo original directamente.
//    2. Caller hace upsertEntry(... checksum: prepared.wireChecksum,
//       sizeBytes: prepared.wireSize).
//    3. uploadFromPreparedWire(prepared, canonicalEntryId, ...) sube en
//       chunks de 4 MiB leyendo desde disco con FileHandle.
//    4. prepared.cleanup() borra el temp si aplica.
//
//  Flujo download:
//    - downloadStreamingToFile(entryId, outputURL, key?) — streaming.
//      Detecta magic NCE3; NCE3 → Nce3StreamingCipher.decryptStreaming;
//      sin magic → plain bytes directos a disco.
//    - downloadAndMaybeDecrypt(entryId, token, key?) — variante legacy
//      que devuelve `Data`. Detecta NCE3 y descifra a un temp.

import CommonCrypto
import CryptoKit
import Foundation

protocol EncryptedFileTransferProtocol {
    func downloadAndMaybeDecrypt(
        entryId: String,
        token: String,
        key: SymmetricKey?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
}

enum EncryptedFileTransferError: Error, Equatable {
    case encryptionFailed
    case decryptionFailed
    case keyRequiredButMissing
    case uploadFailed
    case ioFailure
}

/// Resultado de `prepareWireUpload`. Materializa el wire que se va a
/// subir y reporta su tamaño y checksum SHA-256, sin cargar el archivo en
/// RAM. Si la preparación creó un fichero temporal cifrado, `cleanup()` lo
/// elimina — siempre llamarlo (defer).
struct PreparedUpload {
    let wireURL: URL
    let wireSize: Int64
    let wireChecksum: String
    fileprivate let isTemporary: Bool

    /// Borra el archivo temporal si la preparación creó uno. Idempotente.
    /// Para uploads plain (sin cifrado) el archivo apuntado es el original
    /// del usuario y este método no hace nada.
    func cleanup() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: wireURL)
    }
}

struct EncryptedFileTransfer: EncryptedFileTransferProtocol {
    let apiClient: NodeAPIClientProtocol

    // MARK: - Streaming upload (NCE3)

    /// Prepara los bytes wire para un upload streaming.
    ///
    /// Si `key == nil` el wire es el archivo plaintext original — el
    /// SHA-256 se computa leyendo el fichero por chunks (sin cargarlo en
    /// RAM). Si `key != nil` se cifra streaming a un fichero temporal con
    /// formato NCE3 (`Nce3StreamingCipher`), acumulando el SHA-256 sobre
    /// los bytes wire (header + frames).
    ///
    /// - Important: el caller DEBE invocar `prepared.cleanup()` (idempotente)
    ///   tras completar o abortar el upload, para liberar el temp cifrado.
    func prepareWireUpload(
        plaintextURL: URL,
        key: SymmetricKey?,
        chunkPlainSize: Int = Nce3StreamingCipher.defaultChunkPlainSize,
        compressIfBeneficial: Bool = false
    ) async throws -> PreparedUpload {
        guard let plainSize = (try? FileManager.default.attributesOfItem(atPath: plaintextURL.path))?[.size] as? Int64 else {
            throw EncryptedFileTransferError.ioFailure
        }

        if let key {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nce3-upload-\(UUID().uuidString).bin")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: tempURL)
            defer { try? outHandle.close() }

            var hasher = SHA256()
            do {
                try await Nce3StreamingCipher.encryptStreaming(
                    plaintextURL: plaintextURL,
                    totalSize: UInt64(plainSize),
                    key: key,
                    chunkPlainSize: chunkPlainSize,
                    compressIfBeneficial: compressIfBeneficial
                ) { wireChunk in
                    outHandle.write(wireChunk)
                    hasher.update(data: wireChunk)
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw EncryptedFileTransferError.encryptionFailed
            }
            try outHandle.synchronize()
            try outHandle.close()

            let digest = hasher.finalize()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let wireSize = (attrs[.size] as? Int64) ?? 0
            return PreparedUpload(
                wireURL: tempURL,
                wireSize: wireSize,
                wireChecksum: hex,
                isTemporary: true
            )
        }

        // Plain: streaming SHA-256 sobre el archivo del usuario.
        let hex = try Self.streamingSha256Hex(of: plaintextURL)
        return PreparedUpload(
            wireURL: plaintextURL,
            wireSize: plainSize,
            wireChecksum: hex,
            isTemporary: false
        )
    }

    /// Sube un wire previamente preparado leyendo `prepared.wireURL` por
    /// chunks de `httpChunkSize` (default 4 MiB) directamente desde disco
    /// — RAM peak constante independiente del tamaño total. Asume que la
    /// sesión de upload aún no existe; la crea, sube y completa.
    ///
    /// El caller debe haber hecho `upsertEntry` antes con
    /// `prepared.wireChecksum` y `prepared.wireSize` para que el server
    /// acepte el upload (`FileContentDistributionService` valida SHA-256
    /// del stream contra `FsEntry.checksum`).
    func uploadFromPreparedWire(
        prepared: PreparedUpload,
        entryId: String,
        token: String,
        httpChunkSize: Int = 4 * 1_048_576,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileContentUploadResponse {
        let session = try await apiClient.createUploadSession(
            token: token,
            request: FileUploadSessionCreateRequest(entryId: entryId)
        )

        let handle = try FileHandle(forReadingFrom: prepared.wireURL)
        defer { try? handle.close() }

        var sessionState = session
        var offset: Int64 = 0
        let totalSize = prepared.wireSize
        while offset < totalSize {
            let toRead = Int(min(Int64(httpChunkSize), totalSize - offset))
            let chunk: Data
            if #available(macOS 10.15.4, iOS 13.4, *) {
                chunk = (try handle.read(upToCount: toRead)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: toRead)
            }
            guard chunk.count == toRead else {
                throw EncryptedFileTransferError.ioFailure
            }
            sessionState = try await apiClient.appendUploadChunk(
                token: token,
                sessionId: sessionState.sessionId,
                offset: offset,
                chunk: chunk
            )
            offset += Int64(chunk.count)
            onProgress(Double(offset) / Double(max(totalSize, 1)))
        }

        return try await apiClient.completeUploadSession(
            token: token,
            sessionId: sessionState.sessionId
        )
    }

    /// Streaming SHA-256 sobre un archivo en disco. Lee en chunks de 1 MiB.
    private static func streamingSha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, iOS 13.4, *) {
                chunk = (try handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Streaming download

    /// Descarga `entryId` directamente al disco (`outputURL`) sin acumular el
    /// wire en RAM. El download
    /// usa `downloadFileContentBytes` (AsyncThrowingStream sobre
    /// `URLSession.bytes`) y el cipher consume los bytes conforme llegan del
    /// socket.
    ///
    /// Estrategia:
    ///   1. Abre el stream `(bytes, expectedLength)` del API client.
    ///   2. Lee los primeros 4 bytes para detectar magic NCE3 (peek mínimo).
    ///   3. Routing:
    ///      - NCE3 → `Nce3StreamingCipher.decryptStreaming` con un
    ///        `AsyncThrowingStream` que reemite el prefix leído + el resto
    ///        del iterator. RAM peak constante.
    ///      - sin magic (plain) → escribe el prefix + el resto a disco con
    ///        `FileHandle`. RAM peak constante.
    func downloadStreamingToFile(
        entryId: String,
        token: String,
        outputURL: URL,
        key: SymmetricKey?,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let (stream, expectedLength) = try await apiClient.downloadFileContentBytes(
            token: token,
            entryId: entryId
        )

        var iterator = stream.makeAsyncIterator()
        let prefix = try await Self.readPrefix(EncryptedFile.magicLength, from: &iterator)

        if EncryptedFile.isV3Magic(prefix) {
            guard let key else {
                throw EncryptedFileTransferError.keyRequiredButMissing
            }
            let chained = Self.chained(prefix: prefix, tail: iterator)
            do {
                try await Nce3StreamingCipher.decryptStreaming(
                    wireBytes: chained,
                    key: key,
                    outputURL: outputURL,
                    onProgress: { plainProcessed, totalPlain in
                        guard totalPlain > 0 else { return }
                        let pct = min(1.0, Double(plainProcessed) / Double(totalPlain))
                        onProgress(pct)
                    }
                )
            } catch {
                throw EncryptedFileTransferError.decryptionFailed
            }
            onProgress(1.0)
            return
        }

        // Plain: write streaming a disco. RAM peak ≈ tamaño del buffer
        // intermedio (acumulamos en lotes de 64 KiB para reducir syscalls
        // de write).
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outHandle.close() }

        outHandle.write(Data(prefix))
        var written = Int64(prefix.count)
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        do {
            while let byte = try await iterator.next() {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    outHandle.write(buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expectedLength > 0 {
                        let pct = min(1.0, Double(written) / Double(expectedLength))
                        onProgress(pct)
                    }
                }
            }
        } catch {
            throw EncryptedFileTransferError.ioFailure
        }
        if !buffer.isEmpty {
            outHandle.write(buffer)
            written += Int64(buffer.count)
        }
        onProgress(1.0)
    }

    /// Lee exactamente `count` bytes del iterator. Si el stream termina antes
    /// (e.g. archivo más corto que el magic length), devuelve los bytes
    /// recibidos sin lanzar — el caller decide cómo tratarlos (`hasMagic`
    /// devuelve false para data corta).
    private static func readPrefix<I: AsyncIteratorProtocol>(
        _ count: Int,
        from iterator: inout I
    ) async throws -> Data where I.Element == UInt8 {
        var prefix = Data()
        prefix.reserveCapacity(count)
        while prefix.count < count {
            guard let byte = try await iterator.next() else { break }
            prefix.append(byte)
        }
        return prefix
    }

    /// Construye un `AsyncThrowingStream<UInt8, Error>` que primero emite los
    /// bytes de `prefix` y a continuación drena el `tail` iterator. Usado
    /// para reinyectar los bytes peekeados del magic al consumidor real
    /// (cipher streaming o file write).
    private static func chained<I: AsyncIteratorProtocol & Sendable>(
        prefix: Data,
        tail: I
    ) -> AsyncThrowingStream<UInt8, Error> where I.Element == UInt8 {
        let prefixBytes = Array(prefix)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for byte in prefixBytes {
                    continuation.yield(byte)
                }
                var iterator = tail
                do {
                    while let byte = try await iterator.next() {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Descarga + descifra si detecta magic NCE3.
    /// Si la key es nil pero el archivo está cifrado, throws keyRequiredButMissing.
    /// Si el archivo NO está cifrado (sin magic), devuelve los bytes tal cual
    /// (compat con uploads pre-cifrado en este mismo cliente).
    func downloadAndMaybeDecrypt(
        entryId: String,
        token: String,
        key: SymmetricKey?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let raw = try await apiClient.downloadFileContent(
            token: token,
            entryId: entryId,
            onProgress: onProgress
        )

        guard EncryptedFile.isV3Magic(raw) else {
            return raw
        }

        guard let key else {
            throw EncryptedFileTransferError.keyRequiredButMissing
        }

        // NCE3 chunked: descifrar a un temp y devolver Data del resultado.
        // Mantiene compat con callers legacy que esperan `Data`. Para
        // archivos grandes preferir `downloadStreamingToFile`.
        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-decrypt-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempOutput) }
        do {
            let stream = AsyncStream<UInt8> { continuation in
                for byte in raw { continuation.yield(byte) }
                continuation.finish()
            }
            try await Nce3StreamingCipher.decryptStreaming(
                wireBytes: stream,
                key: key,
                outputURL: tempOutput
            )
            return try Data(contentsOf: tempOutput)
        } catch {
            throw EncryptedFileTransferError.decryptionFailed
        }
    }
}

// MARK: - SHA-256 helper

extension Data {
    /// Hex digest SHA-256 (64 chars). Usado para checksum cliente.
    var sha256Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { bufferPtr in
            _ = CC_SHA256(bufferPtr.baseAddress, CC_LONG(self.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
