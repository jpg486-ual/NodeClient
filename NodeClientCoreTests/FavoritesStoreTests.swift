//  Tests TDD para FavoritesStore + impl
//  UserDefaults shared.

import Foundation
@testable import NodeClientCore
import XCTest

final class FavoritesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "FavoritesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func test_toggle_addsEntryId_whenNotFavorite() {
        let store = makeStore()
        store.toggle(entryId: "f-1", namespace: "alice")

        XCTAssertTrue(store.isFavorite(entryId: "f-1", namespace: "alice"))
        XCTAssertEqual(store.favoriteIds(namespace: "alice"), ["f-1"])
    }

    func test_toggle_removesEntryId_whenAlreadyFavorite() {
        let store = makeStore()
        store.toggle(entryId: "f-1", namespace: "alice")
        store.toggle(entryId: "f-1", namespace: "alice")

        XCTAssertFalse(store.isFavorite(entryId: "f-1", namespace: "alice"))
        XCTAssertTrue(store.favoriteIds(namespace: "alice").isEmpty)
    }

    func test_isFavorite_reflectsState_acrossEntries() {
        let store = makeStore()
        store.toggle(entryId: "f-1", namespace: "alice")
        store.toggle(entryId: "f-2", namespace: "alice")

        XCTAssertTrue(store.isFavorite(entryId: "f-1", namespace: "alice"))
        XCTAssertTrue(store.isFavorite(entryId: "f-2", namespace: "alice"))
        XCTAssertFalse(store.isFavorite(entryId: "f-other", namespace: "alice"))
    }

    func test_favorites_isolatedByNamespace() {
        let store = makeStore()
        store.toggle(entryId: "f-alice", namespace: "alice")
        store.toggle(entryId: "f-bob", namespace: "bob")

        XCTAssertEqual(store.favoriteIds(namespace: "alice"), ["f-alice"])
        XCTAssertEqual(store.favoriteIds(namespace: "bob"), ["f-bob"])
        XCTAssertFalse(store.isFavorite(entryId: "f-alice", namespace: "bob"))
    }

    func test_clear_removesNamespaceOnly() {
        let store = makeStore()
        store.toggle(entryId: "f-alice", namespace: "alice")
        store.toggle(entryId: "f-bob", namespace: "bob")

        store.clear(namespace: "alice")

        XCTAssertTrue(store.favoriteIds(namespace: "alice").isEmpty)
        XCTAssertEqual(store.favoriteIds(namespace: "bob"), ["f-bob"])
    }

    private func makeStore() -> UserDefaultsFavoritesStore {
        UserDefaultsFavoritesStore(userDefaults: defaults)
    }
}
