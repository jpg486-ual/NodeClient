//  Tests TDD Nce3StreamingCipher.

import CryptoKit
@testable import NodeClientCore
import XCTest

final class Nce3StreamingCipherTests: XCTestCase {
    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    private func writeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-test-\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }

    private func collectStream(_ chunks: [Data]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for chunk in chunks {
                for byte in chunk {
                    continuation.yield(byte)
                }
            }
            continuation.finish()
        }
    }

    // MARK: - Header round-trip

    func test_header_serialize_parse_roundtrip() throws {
        let nonceBase = Data(repeating: 0xAB, count: Nce3StreamingCipher.nonceBaseLength)
        let header = Nce3StreamingCipher.Header(
            version: Nce3StreamingCipher.formatVersion,
            flags: 0,
            chunkPlainSize: 1_048_576,
            totalPlainSize: 5_000_000,
            nonceBase: nonceBase
        )
        let serialized = header.serialize()
        XCTAssertEqual(serialized.count, EncryptedFile.v3HeaderLength)
        let parsed = try Nce3StreamingCipher.Header.parse(serialized)
        XCTAssertEqual(parsed, header)
    }

    func test_header_parse_rejects_invalidMagic() {
        var bogus = Data(count: EncryptedFile.v3HeaderLength)
        bogus[0] = 0x4E
        bogus[1] = 0x43
        bogus[2] = 0x45
        bogus[3] = 0x39 // not "3"
        XCTAssertThrowsError(try Nce3StreamingCipher.Header.parse(bogus)) { err in
            XCTAssertEqual(err as? Nce3StreamingCipherError, .invalidHeader)
        }
    }

    func test_header_parse_rejects_unknownVersion() {
        let nonceBase = Data(count: 8)
        let header = Nce3StreamingCipher.Header(
            version: 99,
            flags: 0,
            chunkPlainSize: 1_024,
            totalPlainSize: 10,
            nonceBase: nonceBase
        )
        var serialized = header.serialize()
        // Patch version byte (offset 4) to confirm parse rejects.
        serialized[4] = 99
        XCTAssertThrowsError(try Nce3StreamingCipher.Header.parse(serialized)) { err in
            XCTAssertEqual(err as? Nce3StreamingCipherError, .unsupportedVersion)
        }
    }

    func test_header_parse_rejects_zeroChunkSize() {
        let nonceBase = Data(count: 8)
        var serialized = Data()
        serialized.append(contentsOf: EncryptedFile.magicV3)
        serialized.append(Nce3StreamingCipher.formatVersion)
        serialized.append(0) // flags
        serialized.append(0) // reserved
        serialized.append(0) // reserved
        // chunkPlainSize = 0
        var zeroSize: UInt32 = 0
        withUnsafeBytes(of: &zeroSize) { serialized.append(contentsOf: $0) }
        var totalSize: UInt64 = 100
        withUnsafeBytes(of: &totalSize) { serialized.append(contentsOf: $0) }
        serialized.append(nonceBase)
        XCTAssertThrowsError(try Nce3StreamingCipher.Header.parse(serialized)) { err in
            XCTAssertEqual(err as? Nce3StreamingCipherError, .invalidHeader)
        }
    }

    // MARK: - Nonce derivation

    func test_nonce_derivation_uniquePerChunkIndex() throws {
        let nonceBase = Data(repeating: 0xCC, count: 8)
        let n0 = try Nce3StreamingCipher.nonce(forChunkIndex: 0, base: nonceBase)
        let n1 = try Nce3StreamingCipher.nonce(forChunkIndex: 1, base: nonceBase)
        let n0Bytes = n0.withUnsafeBytes { Data($0) }
        let n1Bytes = n1.withUnsafeBytes { Data($0) }
        XCTAssertEqual(n0Bytes.count, 12)
        XCTAssertEqual(n1Bytes.count, 12)
        XCTAssertNotEqual(n0Bytes, n1Bytes)
        XCTAssertEqual(n0Bytes.prefix(8), nonceBase)
        XCTAssertEqual(n1Bytes.prefix(8), nonceBase)
    }

    // MARK: - Encrypt streaming

    func test_encryptStreaming_emitsHeaderAndFrames_singleChunk() async throws {
        let key = makeKey()
        let plaintext = Data("hello streaming".utf8)
        let url = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: url) }

        var wire = Data()
        let total = try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: url,
            key: key,
            chunkPlainSize: 1_024
        ) { chunk in
            wire.append(chunk)
        }

        XCTAssertEqual(Int(total), wire.count)
        let header = try Nce3StreamingCipher.Header.parse(wire)
        XCTAssertEqual(header.totalPlainSize, UInt64(plaintext.count))
        XCTAssertEqual(header.chunkPlainSize, 1_024)
        XCTAssertEqual(header.chunkCount, 1)
        // wire size = header (28) + plaintext + tag (16)
        XCTAssertEqual(wire.count, EncryptedFile.v3HeaderLength + plaintext.count + 16)
    }

    func test_encryptStreaming_multipleChunks_lastChunkPartial() async throws {
        let key = makeKey()
        let plaintext = Data((0..<2_500).map { UInt8($0 & 0xFF) }) // 2500 bytes
        let url = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: url) }

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: url,
            key: key,
            chunkPlainSize: 1_024 // → 3 chunks: 1_024, 1_024, 452
        ) { chunk in
            wire.append(chunk)
        }
        let header = try Nce3StreamingCipher.Header.parse(wire)
        XCTAssertEqual(header.chunkCount, 3)
        // Total wire = 28 (header) + 2 chunks * (1_024+16) + last chunk (452+16)
        let expectedWire = EncryptedFile.v3HeaderLength
            + (1_024 + Nce3StreamingCipher.tagLength) * 2
            + (452 + Nce3StreamingCipher.tagLength)
        XCTAssertEqual(wire.count, expectedWire)
    }

    // MARK: - Decrypt streaming round-trip

    // MARK: - Compresión LZFSE pre-cifrado

    func test_encryptStreaming_compressIfBeneficial_setsFlagAndReducesSize_compressibleData() async throws {
        let key = makeKey()
        // 8 KiB de bytes redundantes — LZFSE comprime muy bien.
        let plaintext = Data(repeating: 0x41, count: 8_192)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 4_096,
            compressIfBeneficial: true
        ) { chunk in
            wireChunks.append(chunk)
        }
        let wire = wireChunks.reduce(Data(), +)
        let header = try Nce3StreamingCipher.Header.parse(wire)

        XCTAssertEqual(header.flags & Nce3StreamingCipher.flagLzfseCompressed,
                       Nce3StreamingCipher.flagLzfseCompressed)
        XCTAssertLessThan(wire.count, plaintext.count, "wire must be smaller than plaintext")

        // Roundtrip: decrypt debe reconstruir el plaintext original.
        let outUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outUrl) }
        try await Nce3StreamingCipher.decryptStreaming(
            wireBytes: collectStream(wireChunks),
            key: key,
            outputURL: outUrl
        )
        let recovered = try Data(contentsOf: outUrl)
        XCTAssertEqual(recovered, plaintext)
    }

    func test_encryptStreaming_compressIfBeneficial_skipsCompression_incompressibleData() async throws {
        let key = makeKey()
        // Bytes pseudoaleatorios — incompresibles.
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        XCTAssertEqual(status, errSecSuccess)
        let plaintext = Data(bytes)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 4_096,
            compressIfBeneficial: true
        ) { chunk in
            wireChunks.append(chunk)
        }
        let wire = wireChunks.reduce(Data(), +)
        let header = try Nce3StreamingCipher.Header.parse(wire)

        XCTAssertEqual(
            header.flags & Nce3StreamingCipher.flagLzfseCompressed,
            0,
            "flag should be off when compression doesn't reduce size"
        )
    }

    func test_encryptStreaming_compressIfBeneficial_skipsCompression_belowSizeThreshold() async throws {
        let key = makeKey()
        // < 4 KiB → la heurística no intenta comprimir.
        let plaintext = Data(repeating: 0x41, count: 1_000)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 1_024,
            compressIfBeneficial: true
        ) { chunk in
            wireChunks.append(chunk)
        }
        let wire = wireChunks.reduce(Data(), +)
        let header = try Nce3StreamingCipher.Header.parse(wire)

        XCTAssertEqual(header.flags & Nce3StreamingCipher.flagLzfseCompressed, 0)
    }

    func test_encryptStreaming_compressionDisabled_doesNotSetFlag() async throws {
        let key = makeKey()
        let plaintext = Data(repeating: 0x41, count: 8_192)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 4_096,
            compressIfBeneficial: false
        ) { chunk in
            wireChunks.append(chunk)
        }
        let wire = wireChunks.reduce(Data(), +)
        let header = try Nce3StreamingCipher.Header.parse(wire)

        XCTAssertEqual(header.flags & Nce3StreamingCipher.flagLzfseCompressed, 0)
    }

    func test_encrypt_then_decrypt_streaming_roundtrip_smallPayload() async throws {
        let key = makeKey()
        let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 16
        ) { chunk in
            wireChunks.append(chunk)
        }

        let outUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await Nce3StreamingCipher.decryptStreaming(
            wireBytes: collectStream(wireChunks),
            key: key,
            outputURL: outUrl
        )
        let recovered = try Data(contentsOf: outUrl)
        XCTAssertEqual(recovered, plaintext)
    }

    func test_encrypt_then_decrypt_streaming_roundtrip_4MiB() async throws {
        let key = makeKey()
        // 4 MiB pseudo-random plaintext (deterministic, no fragility)
        var bytes = [UInt8]()
        bytes.reserveCapacity(4 * 1_048_576)
        var seed: UInt32 = 0x9E3779B1
        for _ in 0..<(4 * 1_048_576) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(seed & 0xFF))
        }
        let plaintext = Data(bytes)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wireChunks = [Data]()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 1_048_576 // 1 MiB → 4 chunks exact
        ) { chunk in
            wireChunks.append(chunk)
        }
        let header = try Nce3StreamingCipher.Header.parse(wireChunks[0])
        XCTAssertEqual(header.chunkCount, 4)

        let outUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await Nce3StreamingCipher.decryptStreaming(
            wireBytes: collectStream(wireChunks),
            key: key,
            outputURL: outUrl
        )
        let recovered = try Data(contentsOf: outUrl)
        XCTAssertEqual(recovered.count, plaintext.count)
        XCTAssertEqual(recovered, plaintext)
    }

    // MARK: - Tampering

    func test_decryptStreaming_rejectsTamperedCiphertext() async throws {
        let key = makeKey()
        let plaintext = Data(repeating: 0x55, count: 200)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 64
        ) { chunk in
            wire.append(chunk)
        }
        // Flip a byte in the first ciphertext frame (offset = headerLen + 0).
        let flipIndex = EncryptedFile.v3HeaderLength
        wire[flipIndex] ^= 0xFF

        let outUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        do {
            try await Nce3StreamingCipher.decryptStreaming(
                wireBytes: collectStream([wire]),
                key: key,
                outputURL: outUrl
            )
            XCTFail("Expected authenticationFailed")
        } catch {
            XCTAssertEqual(error as? Nce3StreamingCipherError, .authenticationFailed)
        }
    }

    func test_decryptStreaming_rejectsTruncatedStream() async throws {
        let key = makeKey()
        let plaintext = Data(repeating: 0x42, count: 500)
        let inUrl = try writeTempFile(contents: plaintext)
        defer { try? FileManager.default.removeItem(at: inUrl) }

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: inUrl,
            key: key,
            chunkPlainSize: 128
        ) { chunk in
            wire.append(chunk)
        }
        // Truncar el stream a 80% — el último frame queda incompleto.
        let truncated = wire.prefix(Int(Double(wire.count) * 0.8))

        let outUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nce3-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        do {
            try await Nce3StreamingCipher.decryptStreaming(
                wireBytes: collectStream([Data(truncated)]),
                key: key,
                outputURL: outUrl
            )
            XCTFail("Expected unexpectedEndOfStream")
        } catch {
            XCTAssertEqual(error as? Nce3StreamingCipherError, .unexpectedEndOfStream)
        }
    }

    // MARK: - Compatibility detection

    func test_isV3Magic_detectsMagicCorrectly() {
        let plain = Data("plain".utf8)
        XCTAssertFalse(EncryptedFile.isV3Magic(plain))

        var v3 = Data()
        v3.append(contentsOf: EncryptedFile.magicV3)
        v3.append(0)
        XCTAssertTrue(EncryptedFile.isV3Magic(v3))
    }
}
