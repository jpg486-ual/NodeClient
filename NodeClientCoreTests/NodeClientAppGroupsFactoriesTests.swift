//  Tests TDD para las factories `makeShared*` que
//  centralizan la construcción de stores compartidos entre app
//  principal y extensión.

import Foundation
@testable import NodeClientCore
import XCTest

final class NodeClientAppGroupsFactoriesTests: XCTestCase {
    func test_makeSharedTokenStore_usesSharedKeychainAccessGroup() {
        let store = NodeClientAppGroups.makeSharedTokenStore()
        XCTAssertEqual(
            store.testHookAccessGroup,
            NodeClientAppGroups.sharedKeychainAccessGroup,
            "El token store compartido debe declarar el access group Keychain Sharing"
        )
    }

    func test_makeSharedTelemetry_writesToSharedSuite() {
        let suiteName = "NodeClientAppGroupsFactoriesTests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test suite")
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let telemetry = NodeClientAppGroups.makeSharedTelemetry(userDefaults: suite)
        telemetry.increment(.syncIncrementalAttempt)
        telemetry.increment(.syncIncrementalAttempt)

        XCTAssertEqual(telemetry.value(for: .syncIncrementalAttempt), 2)

        // Verificación end-to-end: una nueva instancia que apunte al
        // mismo suite ve los counters incrementados.
        let secondInstance = NodeClientAppGroups.makeSharedTelemetry(userDefaults: suite)
        XCTAssertEqual(
            secondInstance.value(for: .syncIncrementalAttempt),
            2,
            "Counters persisten en el shared suite cross-instance"
        )
    }

    func test_makeSharedSyncStateStore_returnsFunctionalStore() {
        // Smoke: el store construido debe poder hacer round-trip de
        // un snapshot. Sin App Group entitlement, fallback graceful.
        let store = NodeClientAppGroups.makeSharedSyncStateStore()
        let namespace = "factory-test-\(UUID().uuidString)"
        defer { store.clearSnapshot(namespace: namespace) }

        let snapshot = FilesSyncSnapshot(cursor: 1, entries: [])
        store.writeSnapshot(snapshot, namespace: namespace)

        XCTAssertEqual(store.readSnapshot(namespace: namespace)?.cursor, 1)
    }
}
