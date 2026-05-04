//  ViewModel de la vista Favorites.
//  Cruza `FavoritesStore.favoriteIds` con el snapshot del
//  `FilesSyncStateStore` para mostrar entries vivos marcados como
//  favoritos. (placeholder conservado, ahora funcional).

import Combine
import Foundation

struct FavoriteItem: Identifiable, Equatable {
    let entryId: String
    let path: String
    let entryType: FsEntryResponse.EntryType
    let sizeBytes: Int64

    var id: String { entryId }

    init(from response: FsEntryResponse) {
        self.entryId = response.entryId
        self.path = response.path
        self.entryType = response.entryType
        self.sizeBytes = response.sizeBytes
    }
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published private(set) var items: [FavoriteItem] = []

    private let store: FavoritesStore
    private let snapshotStore: FilesSyncStateStore
    private let namespace: String

    init(
        store: FavoritesStore,
        snapshotStore: FilesSyncStateStore,
        namespace: String
    ) {
        self.store = store
        self.snapshotStore = snapshotStore
        self.namespace = namespace
    }

    func reload() {
        let ids = Set(store.favoriteIds(namespace: namespace))
        guard let snapshot = snapshotStore.readSnapshot(namespace: namespace) else {
            items = []
            return
        }
        items = snapshot.entries
            .filter { ids.contains($0.entryId) && !$0.deleted }
            .map { FavoriteItem(from: $0.asResponse) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func toggle(entryId: String) {
        store.toggle(entryId: entryId, namespace: namespace)
        reload()
    }

    func isFavorite(entryId: String) -> Bool {
        store.isFavorite(entryId: entryId, namespace: namespace)
    }
}
