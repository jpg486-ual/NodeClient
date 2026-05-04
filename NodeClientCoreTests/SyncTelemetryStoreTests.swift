@testable import NodeClientCore
import XCTest

final class SyncTelemetryStoreTests: XCTestCase {
    func test_incrementAndValue_updatesCounters() {
        let defaults = makeDefaults()
        let store = UserDefaultsSyncTelemetryStore(userDefaults: defaults)

        store.increment(.syncIncrementalAttempt)
        store.increment(.syncIncrementalAttempt)
        store.increment(.syncNetworkError)

        XCTAssertEqual(store.value(for: .syncIncrementalAttempt), 2)
        XCTAssertEqual(store.value(for: .syncNetworkError), 1)
        XCTAssertEqual(store.value(for: .syncApiError), 0)
    }

    func test_snapshot_returnsAllEvents() {
        let defaults = makeDefaults()
        let store = UserDefaultsSyncTelemetryStore(userDefaults: defaults)

        store.increment(.migrationLegacySnapshotSuccess)

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot[.migrationLegacySnapshotSuccess], 1)
        XCTAssertEqual(snapshot[.syncFullAttempt], 0)
        XCTAssertEqual(snapshot.count, SyncTelemetryEvent.allCases.count)
    }

    func test_resetAll_clearsCounters() {
        let defaults = makeDefaults()
        let store = UserDefaultsSyncTelemetryStore(userDefaults: defaults)

        store.increment(.syncFullAttempt)
        store.increment(.syncFallbackFullResync)

        store.resetAll()

        XCTAssertEqual(store.value(for: .syncFullAttempt), 0)
        XCTAssertEqual(store.value(for: .syncFallbackFullResync), 0)
    }

    private func makeDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "SyncTelemetryStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite", file: file, line: line)
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
