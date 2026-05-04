//  Tests TDD para FavoritesViewModel.
//  Cruza `FavoritesStore.favoriteIds` con el snapshot del
//  `FilesSyncStateStore` para mostrar entries vivos marcados
//  como favoritos.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FavoritesViewModelTests: XCTestCase {
    private var favorites: InMemoryFavoritesStore!
    private var snapshotStore: InMemoryFavoritesSnapshotStore!

    override func setUp() {
        super.setUp()
        favorites = InMemoryFavoritesStore()
        snapshotStore = InMemoryFavoritesSnapshotStore()
    }

    override func tearDown() {
        favorites = nil
        snapshotStore = nil
        super.tearDown()
    }

    func test_reload_includesOnlyFavoriteAndAliveEntries() {
        snapshotStore.snapshot = makeSnapshot(entries: [
            entry(id: "f-1", path: "/a.txt", deleted: false),
            entry(id: "f-2", path: "/b.txt", deleted: false),
            entry(id: "f-3", path: "/old.txt", deleted: true)
        ])
        favorites.toggle(entryId: "f-1", namespace: "alice")
        favorites.toggle(entryId: "f-3", namespace: "alice")

        let viewModel = makeViewModel()
        viewModel.reload()

        XCTAssertEqual(
            viewModel.items.map(\.entryId),
            ["f-1"],
            "f-3 está borrado y no debe aparecer aunque sea favorito; f-2 no es favorito"
        )
    }

    func test_toggle_propagatesToStoreAndReloads() {
        snapshotStore.snapshot = makeSnapshot(entries: [
            entry(id: "f-1", path: "/a.txt", deleted: false)
        ])

        let viewModel = makeViewModel()
        viewModel.reload()
        XCTAssertTrue(viewModel.items.isEmpty)

        viewModel.toggle(entryId: "f-1")

        XCTAssertEqual(viewModel.items.map(\.entryId), ["f-1"])
        XCTAssertTrue(favorites.isFavorite(entryId: "f-1", namespace: "alice"))
    }

    func test_isFavorite_reflectsStoreState() {
        favorites.toggle(entryId: "f-1", namespace: "alice")
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.isFavorite(entryId: "f-1"))
        XCTAssertFalse(viewModel.isFavorite(entryId: "f-other"))
    }

    private func makeViewModel() -> FavoritesViewModel {
        FavoritesViewModel(
            store: favorites,
            snapshotStore: snapshotStore,
            namespace: "alice"
        )
    }

    private func makeSnapshot(entries: [FsEntryResponse]) -> FilesSyncSnapshot {
        FilesSyncSnapshot(
            cursor: 1,
            entries: entries.map(FilesSyncEntry.init(response:))
        )
    }

    private func entry(id: String, path: String, deleted: Bool) -> FsEntryResponse {
        FsEntryResponse(
            entryId: id,
            path: path,
            entryType: .file,
            sizeBytes: 100,
            checksum: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_711_926_000),
            deleted: deleted
        )
    }
}

private final class InMemoryFavoritesStore: FavoritesStore {
    private var byNamespace: [String: Set<String>] = [:]

    func toggle(entryId: String, namespace: String) {
        var set = byNamespace[namespace] ?? []
        if set.contains(entryId) {
            set.remove(entryId)
        } else {
            set.insert(entryId)
        }
        byNamespace[namespace] = set
    }

    func isFavorite(entryId: String, namespace: String) -> Bool {
        byNamespace[namespace]?.contains(entryId) ?? false
    }

    func favoriteIds(namespace: String) -> [String] {
        Array(byNamespace[namespace] ?? []).sorted()
    }

    func clear(namespace: String) {
        byNamespace[namespace] = nil
    }
}

private final class InMemoryFavoritesSnapshotStore: FilesSyncStateStore {
    var snapshot: FilesSyncSnapshot?

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { snapshot }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) { self.snapshot = snapshot }
    func clearSnapshot(namespace: String) { snapshot = nil }
}
