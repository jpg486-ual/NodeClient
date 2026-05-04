//  Wrapper sobre el framework `Compression` de Apple. Comprime
//  `Data → Data` y descomprime `Data → Data` con LZFSE (Apple's algoritmo
//  nativo, mejor ratio/velocidad que zlib en hardware Apple Silicon).
//
//  El cifrado AES-GCM produce bytes indistinguibles de aleatorios, así
//  que comprimir POST-cifrado es contraproducente. La compresión se
//  aplica PRE-cifrado (compress-then-encrypt). Riesgos tipo CRIME/BREACH
//  no aplican porque el operador del nodo no puede inyectar plaintext
//  en archivos del usuario.
//
//  Para archivos grandes existen dos helpers RAM-bounded:
//  - `estimateCompressionRatio`: comprime un sample (1 MiB por defecto)
//    para decidir si vale la pena el coste sin cargar el archivo entero.
//  - `compressFile(from:to:)`: streaming via `OutputFilter` de
//    `Compression`. Lee/escribe en chunks (64 KiB), RAM peak constante.

import Compression
import Foundation

enum DataCompressorError: Error, Equatable {
    case compressionFailed
    case decompressionFailed
}

enum DataCompressor {
    enum Algorithm {
        case lzfse

        fileprivate var nsAlgorithm: NSData.CompressionAlgorithm {
            switch self {
            case .lzfse: return .lzfse
            }
        }

        fileprivate var streamingAlgorithm: Compression.Algorithm {
            switch self {
            case .lzfse: return .lzfse
            }
        }
    }

    static func compress(_ data: Data, using algorithm: Algorithm = .lzfse) throws -> Data {
        do {
            return try (data as NSData).compressed(using: algorithm.nsAlgorithm) as Data
        } catch {
            throw DataCompressorError.compressionFailed
        }
    }

    static func decompress(_ data: Data, using algorithm: Algorithm = .lzfse) throws -> Data {
        do {
            return try (data as NSData).decompressed(using: algorithm.nsAlgorithm) as Data
        } catch {
            throw DataCompressorError.decompressionFailed
        }
    }

    /// Estima el ratio de compresión (compressed/original) sobre los
    /// primeros `sampleBytes` del archivo, sin cargarlo entero en RAM.
    /// Útil para decidir si vale la pena comprimir un archivo grande.
    /// Devuelve `nil` si el archivo está vacío o no se pudo abrir.
    /// RAM peak ≈ `sampleBytes` (default 1 MiB).
    static func estimateCompressionRatio(
        plaintextURL: URL,
        sampleBytes: Int = 1_048_576,
        using algorithm: Algorithm = .lzfse
    ) throws -> Double? {
        let inHandle = try FileHandle(forReadingFrom: plaintextURL)
        defer { try? inHandle.close() }
        let sample: Data?
        if #available(macOS 10.15.4, iOS 13.4, *) {
            sample = try inHandle.read(upToCount: sampleBytes)
        } else {
            sample = inHandle.readData(ofLength: sampleBytes)
        }
        guard let bytes = sample, !bytes.isEmpty else {
            return nil
        }
        let compressed = try compress(bytes, using: algorithm)
        return Double(compressed.count) / Double(bytes.count)
    }

    /// Descomprime `compressedURL` streaming hacia `outputURL` usando
    /// `InputFilter` de `Compression`. Simétrico de `compressFile`.
    /// RAM peak ≈ `chunkSize` — el filter va consumiendo el input via
    /// la closure de read y emite plaintext chunk a chunk.
    static func decompressFile(
        from compressedURL: URL,
        to outputURL: URL,
        using algorithm: Algorithm = .lzfse,
        chunkSize: Int = 65_536
    ) throws {
        let inHandle = try FileHandle(forReadingFrom: compressedURL)
        defer { try? inHandle.close() }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outHandle.close() }

        do {
            let filter = try InputFilter(.decompress, using: algorithm.streamingAlgorithm) { (count: Int) -> Data? in
                let toRead = max(1, count)
                let chunk: Data
                if #available(macOS 10.15.4, iOS 13.4, *) {
                    chunk = (try inHandle.read(upToCount: toRead)) ?? Data()
                } else {
                    chunk = inHandle.readData(ofLength: toRead)
                }
                return chunk.isEmpty ? nil : chunk
            }
            while let plain = try filter.readData(ofLength: chunkSize), !plain.isEmpty {
                outHandle.write(plain)
            }
        } catch {
            throw DataCompressorError.decompressionFailed
        }
        try outHandle.synchronize()
    }

    /// Comprime `plaintextURL` streaming hacia `outputURL` usando
    /// `OutputFilter` de `Compression`. RAM peak ≈ `chunkSize`
    /// (default 64 KiB). Devuelve los bytes wire escritos.
    static func compressFile(
        from plaintextURL: URL,
        to outputURL: URL,
        using algorithm: Algorithm = .lzfse,
        chunkSize: Int = 65_536
    ) throws -> Int64 {
        let inHandle = try FileHandle(forReadingFrom: plaintextURL)
        defer { try? inHandle.close() }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outHandle.close() }

        var bytesWritten: Int64 = 0
        do {
            let filter = try OutputFilter(.compress, using: algorithm.streamingAlgorithm) { data in
                if let data {
                    outHandle.write(data)
                    bytesWritten += Int64(data.count)
                }
            }
            while true {
                let chunk: Data
                if #available(macOS 10.15.4, iOS 13.4, *) {
                    chunk = (try inHandle.read(upToCount: chunkSize)) ?? Data()
                } else {
                    chunk = inHandle.readData(ofLength: chunkSize)
                }
                if chunk.isEmpty {
                    try filter.finalize()
                    break
                }
                try filter.write(chunk)
            }
        } catch {
            throw DataCompressorError.compressionFailed
        }
        try outHandle.synchronize()
        return bytesWritten
    }
}
