import Foundation
@testable import NodeClientCore
import XCTest

final class SQLiteFilesSyncStateStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var legacyDefaults: UserDefaults!
    private var legacyDefaultsSuiteName: String!
    private var telemetry: InMemorySyncTelemetryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteFilesSyncStateStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        legacyDefaultsSuiteName = "SQLiteFilesSyncStateStoreTests.\(UUID().uuidString)"
        legacyDefaults = UserDefaults(suiteName: legacyDefaultsSuiteName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsSuiteName)
        telemetry = InMemorySyncTelemetryStore()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let legacyDefaults, let legacyDefaultsSuiteName {
            legacyDefaults.removePersistentDomain(forName: legacyDefaultsSuiteName)
        }
        legacyDefaults = nil
        legacyDefaultsSuiteName = nil
        telemetry = nil
        try super.tearDownWithError()
    }

    func test_writeAndReadSnapshot_roundTrip() {
        let store = makeStore()
        let snapshot = FilesSyncSnapshot(
            cursor: 42,
            entries: [
                FilesSyncEntry(
                    entryId: "file-1",
                    path: "/docs/readme.md",
                    entryType: .file,
                    sizeBytes: 128,
                    checksum: "abc123",
                    version: 3,
                    updatedAt: Date(timeIntervalSince1970: 1_711_925_200),
                    deleted: false
                ),
                FilesSyncEntry(
                    entryId: "dir-1",
                    path: "/docs",
                    entryType: .directory,
                    sizeBytes: 0,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(timeIntervalSince1970: 1_711_925_100),
                    deleted: false
                )
            ]
        )

        store.writeSnapshot(snapshot, namespace: "jose")
        let loaded = store.readSnapshot(namespace: "jose")

        XCTAssertEqual(loaded?.cursor, 42)
        XCTAssertEqual(loaded?.entries.count, 2)
        XCTAssertEqual(Set(loaded?.entries.map(\.entryId) ?? []), Set(["file-1", "dir-1"]))
    }

    func test_namespaces_areIsolated() {
        let store = makeStore()

        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 10, entries: [sampleEntry(id: "a")]),
            namespace: "alice"
        )
        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 20, entries: [sampleEntry(id: "b")]),
            namespace: "bob"
        )

        XCTAssertEqual(store.readSnapshot(namespace: "alice")?.cursor, 10)
        XCTAssertEqual(store.readSnapshot(namespace: "bob")?.cursor, 20)
        XCTAssertEqual(store.readSnapshot(namespace: "alice")?.entries.first?.entryId, "a")
        XCTAssertEqual(store.readSnapshot(namespace: "bob")?.entries.first?.entryId, "b")
    }

    func test_clearSnapshot_removesOnlyTargetNamespace() {
        let store = makeStore()

        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 10, entries: [sampleEntry(id: "a")]),
            namespace: "alice"
        )
        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 20, entries: [sampleEntry(id: "b")]),
            namespace: "bob"
        )

        store.clearSnapshot(namespace: "alice")

        XCTAssertNil(store.readSnapshot(namespace: "alice"))
        XCTAssertEqual(store.readSnapshot(namespace: "bob")?.cursor, 20)
    }

    func test_writeSnapshot_overwritesPreviousEntriesForNamespace() {
        let store = makeStore()

        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 1, entries: [sampleEntry(id: "legacy")]),
            namespace: "jose"
        )
        store.writeSnapshot(
            FilesSyncSnapshot(cursor: 2, entries: [sampleEntry(id: "fresh")]),
            namespace: "jose"
        )

        let loaded = store.readSnapshot(namespace: "jose")

        XCTAssertEqual(loaded?.cursor, 2)
        XCTAssertEqual(loaded?.entries.map(\.entryId), ["fresh"])
    }

    func test_init_migratesLegacySnapshotFromUserDefaults_once() {
        let legacyStore = UserDefaultsFilesSyncStateStore(userDefaults: legacyDefaults)
        let legacySnapshot = FilesSyncSnapshot(cursor: 77, entries: [sampleEntry(id: "legacy")])
        legacyStore.writeSnapshot(legacySnapshot, namespace: "jose")

        let sqliteStore = makeStore()

        let loaded = sqliteStore.readSnapshot(namespace: "jose")
        XCTAssertEqual(loaded?.cursor, 77)
        XCTAssertEqual(loaded?.entries.map(\.entryId), ["legacy"])
        XCTAssertNil(legacyStore.readSnapshot(namespace: "jose"))
        XCTAssertEqual(telemetry.value(for: .migrationLegacySnapshotSuccess), 1)
    }

    func test_init_doesNotOverrideExistingSQLiteSnapshotDuringMigration() {
        let sqliteStore = makeStore()
        sqliteStore.writeSnapshot(
            FilesSyncSnapshot(cursor: 10, entries: [sampleEntry(id: "sqlite")]),
            namespace: "jose"
        )

        let legacyStore = UserDefaultsFilesSyncStateStore(userDefaults: legacyDefaults)
        legacyStore.writeSnapshot(
            FilesSyncSnapshot(cursor: 99, entries: [sampleEntry(id: "legacy")]),
            namespace: "jose"
        )

        let reloadedStore = makeStore()
        let loaded = reloadedStore.readSnapshot(namespace: "jose")

        XCTAssertEqual(loaded?.cursor, 10)
        XCTAssertEqual(loaded?.entries.map(\.entryId), ["sqlite"])
        XCTAssertNil(legacyStore.readSnapshot(namespace: "jose"))
        XCTAssertEqual(telemetry.value(for: .migrationLegacySnapshotSkippedExisting), 1)
    }

    func test_init_whenLegacyPayloadIsInvalid_recordsInvalidPayloadTelemetryAndKeepsLegacyKey() {
        let invalidData = Data("{invalid-json}".utf8)
        let key = UserDefaultsFilesSyncStateStore.snapshotKeyPrefix + ".jose"
        legacyDefaults.set(invalidData, forKey: key)

        _ = makeStore()

        XCTAssertEqual(telemetry.value(for: .migrationLegacySnapshotInvalidPayload), 1)
        XCTAssertNotNil(legacyDefaults.data(forKey: key))
    }

    private func makeStore() -> SQLiteFilesSyncStateStore {
        SQLiteFilesSyncStateStore(
            fileURL: temporaryDirectory.appendingPathComponent("sync-state.sqlite"),
            legacyUserDefaults: legacyDefaults,
            telemetryStore: telemetry
        )
    }

    private func sampleEntry(id: String) -> FilesSyncEntry {
        FilesSyncEntry(
            entryId: id,
            path: "/\(id).txt",
            entryType: .file,
            sizeBytes: 1,
            checksum: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_711_925_300),
            deleted: false
        )
    }
}

private final class InMemorySyncTelemetryStore: SyncTelemetryStore {
    private var counters: [SyncTelemetryEvent: Int] = [:]

    func increment(_ event: SyncTelemetryEvent) {
        counters[event, default: 0] += 1
    }

    func value(for event: SyncTelemetryEvent) -> Int {
        counters[event, default: 0]
    }

    func snapshot() -> [SyncTelemetryEvent: Int] {
        counters
    }

    func resetAll() {
        counters.removeAll()
    }
}
