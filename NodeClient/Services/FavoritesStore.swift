//  Persistencia de items favoritos. UserDefaults en App Group suite
//  como infraestructura preparada para los consumidores compartidos.

import Foundation

protocol FavoritesStore {
    func toggle(entryId: String, namespace: String)
    func isFavorite(entryId: String, namespace: String) -> Bool
    func favoriteIds(namespace: String) -> [String]
    func clear(namespace: String)
}

final class UserDefaultsFavoritesStore: FavoritesStore {
    static let keyPrefix = "node.favorites"

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults ?? NodeClientAppGroups.sharedUserDefaults()
    }

    func toggle(entryId: String, namespace: String) {
        lock.lock()
        defer { lock.unlock() }

        var ids = readIds(namespace: namespace)
        if let index = ids.firstIndex(of: entryId) {
            ids.remove(at: index)
        } else {
            ids.append(entryId)
        }
        writeIds(ids, namespace: namespace)
    }

    func isFavorite(entryId: String, namespace: String) -> Bool {
        readIds(namespace: namespace).contains(entryId)
    }

    func favoriteIds(namespace: String) -> [String] {
        readIds(namespace: namespace)
    }

    func clear(namespace: String) {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: storageKey(namespace: namespace))
    }

    private func storageKey(namespace: String) -> String {
        let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "anonymous" : trimmed
        return "\(Self.keyPrefix).\(effective)"
    }

    private func readIds(namespace: String) -> [String] {
        guard let array = userDefaults.array(forKey: storageKey(namespace: namespace)) else {
            return []
        }
        return array.compactMap { $0 as? String }
    }

    private func writeIds(_ ids: [String], namespace: String) {
        userDefaults.set(ids, forKey: storageKey(namespace: namespace))
    }
}
