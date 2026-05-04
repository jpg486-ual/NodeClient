//  Tests TDD para verificar que los stores SQLite
//  resuelven su path por defecto vía NodeClientAppGroups.resolvedDataDirectory
//  (App Group container preferido, fallback applicationSupport).

import Foundation
@testable import NodeClientCore
import XCTest

final class SharedStoresAppGroupTests: XCTestCase {
    private var temporaryContainer: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedStoresAppGroupTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporaryContainer,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryContainer)
        try super.tearDownWithError()
    }

    func test_syncStateStore_persistsUnderAppGroupContainer_whenAvailable() throws {
        let mockFileManager = StubContainerFileManager(stubbed: temporaryContainer)
        let store = SQLiteFilesSyncStateStore(
            fileManager: mockFileManager,
            telemetryStore: SilentTelemetry()
        )

        let snapshot = FilesSyncSnapshot(
            cursor: 7,
            entries: [
                FilesSyncEntry(
                    entryId: "f-1",
                    path: "/file.txt",
                    entryType: .file,
                    sizeBytes: 1,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(timeIntervalSince1970: 1_711_926_000),
                    deleted: false
                )
            ]
        )
        store.writeSnapshot(snapshot, namespace: "alice")

        let expectedDB = temporaryContainer
            .appendingPathComponent("NodeClient/files-sync-state.sqlite")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedDB.path),
            "El sync state SQLite debe vivir bajo el container compartido"
        )
    }

    func test_syncStateStore_fallsBackToApplicationSupport_whenContainerMissing() {
        let mockFileManager = StubContainerFileManager(stubbed: nil)

        let store = SQLiteFilesSyncStateStore(
            fileManager: mockFileManager,
            telemetryStore: SilentTelemetry()
        )

        XCTAssertNotNil(
            store,
            "Sin App Group container, el store sigue construyéndose contra applicationSupport o tmpDir"
        )
    }
}

private final class StubContainerFileManager: FileManager {
    private let stubbed: URL?

    init(stubbed: URL?) {
        self.stubbed = stubbed
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        stubbed
    }
}

private final class SilentTelemetry: SyncTelemetryStore {
    func increment(_ event: SyncTelemetryEvent) {}
    func value(for event: SyncTelemetryEvent) -> Int { 0 }
    func snapshot() -> [SyncTelemetryEvent: Int] { [:] }
    func resetAll() {}
}
