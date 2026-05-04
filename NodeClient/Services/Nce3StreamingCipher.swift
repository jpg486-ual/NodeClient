//  Cifrado/descifrado streaming chunked AES-GCM 256.
//
//  Procesa el archivo por bloques de tamaño fijo (`chunkPlainSize`, default
//  1 MiB), encriptando cada bloque con un nonce derivado (`nonceBase ||
//  chunkIndex`) y un tag GCM independiente. Permite subir/bajar archivos
//  arbitrariamente grandes manteniendo RAM peak constante — solución frente
//  al problema clásico de los formatos de cifrado monolíticos que exigen
//  cargar el plaintext completo en memoria.
//
//  Formato wire NCE3 (ver `EncryptedFile.swift` para layout exacto):
//      [28 bytes header]
//      [chunkPlainSize bytes ciphertext][16 bytes tag]   ← chunk 0
//      [chunkPlainSize bytes ciphertext][16 bytes tag]   ← chunk 1
//      ...
//      [≤chunkPlainSize bytes ciphertext][16 bytes tag]  ← chunk N-1 (parcial)
//
//  Cada chunk se sella con `AES.GCM.Nonce(nonceBase || idx_BE_uint32)`. Esto
//  garantiza nonce único por chunk dentro de un mismo archivo (el `nonceBase`
//  es 8 bytes random per archivo, y `chunkIndex` lo extiende a los 12 bytes
//  exigidos por AES-GCM).

import CryptoKit
import Foundation

enum Nce3StreamingCipherError: Error, Equatable {
    case invalidHeader
    case unexpectedEndOfStream
    case authenticationFailed
    case unsupportedVersion
    case ioFailure
}

/// Cifrador/descifrador chunked AES-GCM con streaming desde/hacia disco.
/// Caseless enum (namespace de funciones static; no instanciable).
enum Nce3StreamingCipher {
    /// Tamaño plaintext por chunk. 1 MiB equilibra overhead per-chunk
    /// (header + tag = 16 bytes ÷ 1 MiB ≈ 0.0015% overhead) con RAM peak
    /// del proceso de cifrado.
    static let defaultChunkPlainSize: Int = 1_048_576

    /// AES-GCM tag estándar.
    static let tagLength: Int = 16

    /// Parte random del nonce, fija para un archivo.
    static let nonceBaseLength: Int = 8

    /// Parte determinista del nonce (chunk index uint32 BE).
    static let chunkIndexLength: Int = 4

    /// Versión actual del formato escrita en el header (byte 4).
    static let formatVersion: UInt8 = 1

    /// Sin flags activos.
    static let noFlags: UInt8 = 0

    /// Bit 0: el plaintext interno fue comprimido con LZFSE antes de
    /// cifrar. Al descifrar, los bytes recuperados deben pasarse por el
    /// decompresor LZFSE para reconstruir el original. La compresión es
    /// opt-in (ver `EncryptionPreferences`) y solo se aplica si reduce
    /// el tamaño ≥10% — en archivos ya comprimidos (jpg, mp4, zip) el
    /// flag queda en 0 y el upload va sin overhead.
    static let flagLzfseCompressed: UInt8 = 0x01

    /// Heurística mínima de tamaño bajo la cual no merece intentar
    /// comprimir (overhead del header LZFSE > ahorro probable).
    static let compressionMinPlainBytes: Int64 = 4_096

    /// Tamaño del sample que se lee para estimar si la compresión
    /// merece la pena, sin cargar el archivo entero en RAM. 1 MiB
    /// es suficiente para detectar entropía representativa en la
    /// mayoría de formatos (texto/binario denso/ya-comprimido).
    static let compressionSamplePlainBytes: Int = 1_048_576

    /// Si compressed.size >= raw.size × ratio → descartar compresión.
    static let compressionMaxRatio: Double = 0.9

    // MARK: - Header

    struct Header: Equatable {
        let version: UInt8
        let flags: UInt8
        let chunkPlainSize: UInt32
        let totalPlainSize: UInt64
        let nonceBase: Data // 8 bytes

        /// Cuántos chunks tiene un archivo de `totalPlainSize` con el
        /// `chunkPlainSize` de este header. El último chunk puede ser parcial.
        var chunkCount: Int {
            guard chunkPlainSize > 0 else { return 0 }
            let n = Int(totalPlainSize)
            let s = Int(chunkPlainSize)
            return (n + s - 1) / s
        }

        func serialize() -> Data {
            precondition(nonceBase.count == Nce3StreamingCipher.nonceBaseLength)
            var out = Data()
            out.append(contentsOf: EncryptedFile.magicV3)
            out.append(version)
            out.append(flags)
            out.append(0) // reserved
            out.append(0) // reserved
            var chunkSizeBE = chunkPlainSize.bigEndian
            withUnsafeBytes(of: &chunkSizeBE) { out.append(contentsOf: $0) }
            var totalBE = totalPlainSize.bigEndian
            withUnsafeBytes(of: &totalBE) { out.append(contentsOf: $0) }
            out.append(nonceBase)
            return out
        }

        static func parse(_ data: Data) throws -> Self {
            guard data.count >= EncryptedFile.v3HeaderLength else {
                throw Nce3StreamingCipherError.invalidHeader
            }
            let prefix = Array(data.prefix(EncryptedFile.magicLength))
            guard prefix == EncryptedFile.magicV3 else {
                throw Nce3StreamingCipherError.invalidHeader
            }
            let base = data.startIndex
            let version = data[base + 4]
            guard version == Nce3StreamingCipher.formatVersion else {
                throw Nce3StreamingCipherError.unsupportedVersion
            }
            let flags = data[base + 5]
            // reserved 6..7 ignorados
            let chunkSizeBytes = data.subdata(in: (base + 8)..<(base + 12))
            let chunkPlainSize = chunkSizeBytes.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self).bigEndian
            }
            let totalSizeBytes = data.subdata(in: (base + 12)..<(base + 20))
            let totalPlainSize = totalSizeBytes.withUnsafeBytes { ptr in
                ptr.load(as: UInt64.self).bigEndian
            }
            let nonceBase = data.subdata(in: (base + 20)..<(base + 28))
            guard chunkPlainSize > 0 else {
                throw Nce3StreamingCipherError.invalidHeader
            }
            return Self(
                version: version,
                flags: flags,
                chunkPlainSize: chunkPlainSize,
                totalPlainSize: totalPlainSize,
                nonceBase: nonceBase
            )
        }
    }

    // MARK: - Nonce derivation

    /// Construye el nonce AES-GCM (12 bytes) para `chunkIndex`. Estándar
    /// counter prefix: `nonceBase || chunkIndex_BE_uint32`.
    static func nonce(forChunkIndex chunkIndex: UInt32, base nonceBase: Data) throws -> AES.GCM.Nonce {
        precondition(nonceBase.count == nonceBaseLength)
        var bytes = Data()
        bytes.append(nonceBase)
        var idxBE = chunkIndex.bigEndian
        withUnsafeBytes(of: &idxBE) { bytes.append(contentsOf: $0) }
        do {
            return try AES.GCM.Nonce(data: bytes)
        } catch {
            throw Nce3StreamingCipherError.invalidHeader
        }
    }

    // MARK: - Encrypt streaming

    /// Cifra `plaintextURL` produciendo bytes en formato NCE3.
    ///
    /// Llama `emitChunk` con cada bloque de bytes a transmitir (primero el
    /// header, luego los frames `ciphertext+tag`). El caller se encarga de
    /// enviar esos bytes via HTTP (chunked PUT) o escribirlos a disco. El
    /// archivo nunca se carga entero en RAM — solo `chunkPlainSize` bytes
    /// per iteración.
    ///
    /// - Parameters:
    ///   - plaintextURL: URL local del archivo plain a cifrar.
    ///   - key: clave AES-256 simétrica.
    ///   - chunkPlainSize: tamaño plaintext por chunk (default 1 MiB).
    ///   - emitChunk: closure async que recibe cada bloque de wire bytes.
    /// - Returns: tamaño total de wire bytes emitidos (header + N frames).
    /// - Throws: errores de IO o de cifrado.
    @discardableResult
    static func encryptStreaming(
        plaintextURL: URL,
        key: SymmetricKey,
        chunkPlainSize: Int = defaultChunkPlainSize,
        compressIfBeneficial: Bool = false,
        emitChunk: (Data) async throws -> Void
    ) async throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: plaintextURL.path)
        guard let totalSize = attrs[.size] as? Int64 else {
            throw Nce3StreamingCipherError.ioFailure
        }
        return try await encryptStreaming(
            plaintextURL: plaintextURL,
            totalSize: UInt64(totalSize),
            key: key,
            chunkPlainSize: chunkPlainSize,
            compressIfBeneficial: compressIfBeneficial,
            emitChunk: emitChunk
        )
    }

    /// Variante explícita que evita re-stat-ear el archivo cuando el caller
    /// ya conoce el tamaño (e.g. tests sintéticos).
    @discardableResult
    static func encryptStreaming(
        plaintextURL: URL,
        totalSize: UInt64,
        key: SymmetricKey,
        chunkPlainSize: Int = defaultChunkPlainSize,
        compressIfBeneficial: Bool = false,
        emitChunk: (Data) async throws -> Void
    ) async throws -> Int64 {
        precondition(chunkPlainSize > 0 && chunkPlainSize <= UInt32.max)

        // Compresión opcional: si el toggle está ON y el archivo es candidato
        // (>= 4 KiB y compresión reduce ≥10%), comprime a un temp con LZFSE
        // y usa el comprimido como input al cifrado. El header marca el flag
        // para que el decryptor descomprima al final.
        var effectiveSourceURL = plaintextURL
        var effectiveTotalSize = totalSize
        var headerFlags: UInt8 = noFlags
        var compressedTempURL: URL?
        defer {
            if let url = compressedTempURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        if compressIfBeneficial, Int64(totalSize) >= compressionMinPlainBytes {
            // Decisión RAM-bounded basada en sample: leemos el primer
            // MiB del archivo, comprimimos en memoria (1 MiB es seguro)
            // y si el ratio del sample reduce ≥10% asumimos que el
            // archivo entero también — hacemos streaming compress al
            // temp via `OutputFilter` (RAM ≈ 64 KiB).
            //
            // Si el sample miente (header compresible + cuerpo no, raro)
            // pagamos unos KB de overhead del header LZFSE — no merece
            // doble verificación. El gatekeeper del sample evita ~2x
            // I/O de disco para archivos obviamente incompresibles.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nce3-precompress-\(UUID().uuidString).bin")
            do {
                let sampleRatio = try DataCompressor.estimateCompressionRatio(
                    plaintextURL: plaintextURL,
                    sampleBytes: compressionSamplePlainBytes
                )
                if let ratio = sampleRatio, ratio < compressionMaxRatio {
                    let compressedSize = try DataCompressor.compressFile(
                        from: plaintextURL,
                        to: tempURL
                    )
                    compressedTempURL = tempURL
                    effectiveSourceURL = tempURL
                    effectiveTotalSize = UInt64(compressedSize)
                    headerFlags |= flagLzfseCompressed
                }
            } catch {
                // Cualquier fallo de estimate/stream → caer a plain
                // sin romper el upload.
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        var nonceBaseBytes = Data(count: nonceBaseLength)
        let status = nonceBaseBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, nonceBaseLength, base)
        }
        guard status == errSecSuccess else {
            throw Nce3StreamingCipherError.ioFailure
        }

        let header = Header(
            version: formatVersion,
            flags: headerFlags,
            chunkPlainSize: UInt32(chunkPlainSize),
            totalPlainSize: effectiveTotalSize,
            nonceBase: nonceBaseBytes
        )
        let headerData = header.serialize()
        try await emitChunk(headerData)
        var emittedBytes = Int64(headerData.count)

        let handle = try FileHandle(forReadingFrom: effectiveSourceURL)
        defer { try? handle.close() }

        var chunkIndex: UInt32 = 0
        var bytesProcessed: UInt64 = 0
        while bytesProcessed < effectiveTotalSize {
            let remaining = effectiveTotalSize - bytesProcessed
            let toRead = Int(min(UInt64(chunkPlainSize), remaining))
            let plain: Data
            if #available(macOS 10.15.4, iOS 13.4, *) {
                plain = (try handle.read(upToCount: toRead)) ?? Data()
            } else {
                plain = handle.readData(ofLength: toRead)
            }
            guard plain.count == toRead else {
                throw Nce3StreamingCipherError.unexpectedEndOfStream
            }
            let nonce = try nonce(forChunkIndex: chunkIndex, base: nonceBaseBytes)
            let sealed: AES.GCM.SealedBox
            do {
                sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
            } catch {
                throw Nce3StreamingCipherError.authenticationFailed
            }
            var frame = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            try await emitChunk(frame)
            emittedBytes += Int64(frame.count)
            bytesProcessed += UInt64(plain.count)
            chunkIndex += 1
        }
        return emittedBytes
    }

    // MARK: - Decrypt streaming

    /// Descifra un stream NCE3 escribiendo el plaintext a `outputURL`. El
    /// stream `wireBytes` produce los bytes wire en el orden recibidos —
    /// puede provenir de `URLSession.bytes(for:)` directamente.
    ///
    /// - Parameters:
    ///   - wireBytes: AsyncSequence de bytes wire NCE3 (header + frames).
    ///   - key: clave AES-256.
    ///   - outputURL: archivo de destino (se trunca si existe).
    ///   - onProgress: callback con bytes plaintext escritos (acumulado) y
    ///     totalPlainSize esperado.
    static func decryptStreaming<S: AsyncSequence>(
        wireBytes: S,
        key: SymmetricKey,
        outputURL: URL,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws where S.Element == UInt8 {
        var iterator = wireBytes.makeAsyncIterator()

        // 1) Leer header (28 bytes exactos).
        let headerData = try await readExactly(EncryptedFile.v3HeaderLength, from: &iterator)
        let header = try Header.parse(headerData)
        let isCompressed = (header.flags & flagLzfseCompressed) != 0

        // Si el header marca compresión, los chunks descifrados son los bytes
        // del archivo comprimido — los acumulamos a un temp y al final
        // descomprimimos a `outputURL`. Sin compresión, escribimos directo.
        let writeURL: URL
        let compressedTemp: URL?
        if isCompressed {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nce3-decompress-\(UUID().uuidString).bin")
            writeURL = temp
            compressedTemp = temp
        } else {
            writeURL = outputURL
            compressedTemp = nil
        }
        defer {
            if let url = compressedTemp {
                try? FileManager.default.removeItem(at: url)
            }
        }
        FileManager.default.createFile(atPath: writeURL.path, contents: nil, attributes: nil)
        let outHandle = try FileHandle(forWritingTo: writeURL)

        // 2) Iterar chunks. Cada frame es chunkPlainSize+tag, salvo el último
        //    cuyo plaintext puede ser menor (los bytes que faltan para llegar
        //    a totalPlainSize).
        var chunkIndex: UInt32 = 0
        var plainProcessed: UInt64 = 0
        let totalPlain = header.totalPlainSize
        let chunkSize = Int(header.chunkPlainSize)
        while plainProcessed < totalPlain {
            let remaining = totalPlain - plainProcessed
            let plainLenThisChunk = Int(min(UInt64(chunkSize), remaining))
            let frameLen = plainLenThisChunk + tagLength
            let frame = try await readExactly(frameLen, from: &iterator)
            let cipherBytes = frame.prefix(plainLenThisChunk)
            let tagBytes = frame.suffix(tagLength)
            let nonce = try nonce(forChunkIndex: chunkIndex, base: header.nonceBase)
            let sealed: AES.GCM.SealedBox
            do {
                sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherBytes, tag: tagBytes)
            } catch {
                throw Nce3StreamingCipherError.authenticationFailed
            }
            let plain: Data
            do {
                plain = try AES.GCM.open(sealed, using: key)
            } catch {
                throw Nce3StreamingCipherError.authenticationFailed
            }
            outHandle.write(plain)
            plainProcessed += UInt64(plain.count)
            chunkIndex += 1
            onProgress?(Int64(plainProcessed), Int64(totalPlain))
        }
        try outHandle.synchronize()
        try outHandle.close()

        if isCompressed {
            // Streaming descompresión LZFSE: compressed temp → outputURL,
            // RAM ≈ chunk size (64 KiB). Sin esto un archivo de varios
            // GB cifrado+comprimido reventaría la app al cargar el wire
            // descifrado entero a `Data(contentsOf:)`.
            do {
                try DataCompressor.decompressFile(from: writeURL, to: outputURL)
            } catch {
                throw Nce3StreamingCipherError.authenticationFailed
            }
        }
    }

    // MARK: - Helpers

    /// Acumula `count` bytes del iterator. Si EOF prematuro, lanza.
    private static func readExactly<I: AsyncIteratorProtocol>(
        _ count: Int,
        from iterator: inout I
    ) async throws -> Data where I.Element == UInt8 {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            guard let byte = try await iterator.next() else {
                throw Nce3StreamingCipherError.unexpectedEndOfStream
            }
            buffer.append(byte)
        }
        return buffer
    }
}
