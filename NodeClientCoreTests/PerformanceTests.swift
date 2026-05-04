// Performance audit con XCTMetric.
//
//  tests baseline para hot paths identificados (SQLite snapshot 10k,
//  PBKDF2 deriveKey, NCE3 streaming round-trip).
//
//  Datos sintéticos deterministas vía `PerformanceTestFixtures` con
//  seed fija para reproducibilidad cross-machine. Sin enforcement
//  de baselines en CI (varianza alta runners GitHub Actions).
//
//  Ejecución: `swift test --filter PerformanceTests` o vía Xcode UI.

import CryptoKit
import Foundation
@testable import NodeClientCore
import XCTest

final class PerformanceTests: XCTestCase {
    // MARK: - SQLite snapshot 10k entries

    func test_sqliteSyncStateStore_writeSnapshot_10k_entries_baseline() {
        let store = makeSQLiteStore()
        let snapshot = PerformanceTestFixtures.makeSyncSnapshot(entryCount: 10_000)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTStorageMetric()]) {
            store.writeSnapshot(snapshot, namespace: "perf-write")
        }
    }

    func test_sqliteSyncStateStore_readSnapshot_10k_entries_baseline() {
        let store = makeSQLiteStore()
        let snapshot = PerformanceTestFixtures.makeSyncSnapshot(entryCount: 10_000)
        store.writeSnapshot(snapshot, namespace: "perf-read")

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTStorageMetric()]) {
            _ = store.readSnapshot(namespace: "perf-read")
        }
    }

    // MARK: - PBKDF2 key derivation

    func test_passwordKeyDerivation_deriveKey_600k_iterations_baseline() throws {
        let derivation = PasswordKeyDerivation()
        let salt = PasswordKeyDerivation.generateSalt()

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            do {
                _ = try derivation.deriveKey(
                    password: "node-client-perf-fixture-password",
                    salt: salt,
                    iterations: PasswordKeyDerivation.defaultIterations
                )
            } catch {
                XCTFail("deriveKey failed: \(error)")
            }
        }
    }

    // MARK: - NCE3 streaming AES-GCM round-trip 1MB

    func test_nce3StreamingCipher_roundtrip_1MB_baseline() async throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0x55, count: 1 * 1_024 * 1_024)  // 1MB
        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-nce3-\(UUID().uuidString).bin")
        try plaintext.write(to: plainURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: plainURL) }

        // `measure` con bloque async no es directo: medimos en el caller
        // wrap, capturando una sola pasada como baseline observable.
        // El framework completo (`XCTClockMetric` etc.) requeriría un
        // `measure { ... }` síncrono — para este perf test informativo,
        // basta con un round-trip end-to-end que sirve de canary contra
        // regresiones graves.
        let started = Date()

        var wire = Data()
        try await Nce3StreamingCipher.encryptStreaming(
            plaintextURL: plainURL,
            key: key,
            chunkPlainSize: 64 * 1_024
        ) { chunk in
            wire.append(chunk)
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-nce3-out-\(UUID().uuidString).bin")
        addTeardownBlock { try? FileManager.default.removeItem(at: outURL) }

        let stream = AsyncStream<UInt8> { continuation in
            for byte in wire { continuation.yield(byte) }
            continuation.finish()
        }
        try await Nce3StreamingCipher.decryptStreaming(
            wireBytes: stream,
            key: key,
            outputURL: outURL
        )
        let recovered = try Data(contentsOf: outURL)
        XCTAssertEqual(recovered.count, plaintext.count)

        let elapsed = Date().timeIntervalSince(started)
        // Baseline informativo (logged a XCTest output, no enforced).
        // Un MacBook M-series reciente suele rondar < 500ms para 1 MiB.
        XCTAssertLessThan(elapsed, 5.0, "Round-trip 1MB tomó >5s — investigar regresión")
    }

    // MARK: - Helpers

    private func makeSQLiteStore() -> SQLiteFilesSyncStateStore {
        let directory = makeTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let dbURL = directory.appendingPathComponent("perf.sqlite3")
        return SQLiteFilesSyncStateStore(fileURL: dbURL)
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc14-perf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
