//  Tests propios del `DataCompressor` (sanity LZFSE) y del store de preferencias.

// swiftlint:disable single_test_class
// El archivo agrupa 2 suites cohesivas (data compressor sanity +
// encryption preferences) — separar añade overhead sin claridad.
// Excepción local al rule.

@testable import NodeClientCore
import XCTest

// MARK: - DataCompressor sanity

final class DataCompressorTests: XCTestCase {
    func test_compress_decompress_roundtrip() throws {
        let original = Data(repeating: 0x42, count: 16_384)
        let compressed = try DataCompressor.compress(original, using: .lzfse)
        let recovered = try DataCompressor.decompress(compressed, using: .lzfse)
        XCTAssertEqual(recovered, original)
        XCTAssertLessThan(compressed.count, original.count)
    }

    func test_decompress_invalidBytes_throws() {
        XCTAssertThrowsError(try DataCompressor.decompress(Data([0x00, 0x01, 0x02, 0x03]), using: .lzfse)) { error in
            XCTAssertEqual(error as? DataCompressorError, .decompressionFailed)
        }
    }
}

// MARK: - Preferences store

final class EncryptionPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "test.encryption.preferences.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_compressionEnabled_defaultsToTrue_whenAbsent() {
        let store = UserDefaultsEncryptionPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.compressionEnabled)
    }

    func test_compressionEnabled_persistsFalse() {
        var store = UserDefaultsEncryptionPreferencesStore(defaults: defaults)
        store.compressionEnabled = false
        XCTAssertFalse(store.compressionEnabled)

        let reloaded = UserDefaultsEncryptionPreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.compressionEnabled)
    }

    func test_compressionEnabled_persistsTrueExplicitly() {
        var store = UserDefaultsEncryptionPreferencesStore(defaults: defaults)
        store.compressionEnabled = true
        XCTAssertTrue(store.compressionEnabled)

        let reloaded = UserDefaultsEncryptionPreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.compressionEnabled)
    }
}
// swiftlint:enable single_test_class
