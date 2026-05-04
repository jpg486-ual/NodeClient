//  Factories estáticos del `FilesView` extraídos para mantener el
//  archivo principal navegable. Construyen los `@StateObject` por
//  defecto que el composition root (`NodeClientRootView`) consume.
//
//  Patrón calcado del split `*+iOS.swift` / `*+macOS.swift`: los
//  factories viven aquí, la View principal y los modifiers user-facing
//  permanecen en archivos hermanos del mismo directorio.

import SwiftUI

extension FilesView {
    static func makeDefaultViewModel() -> FilesViewModel {
        defaultViewModel()
    }

    static func makeDefaultFavoritesViewModel() -> FavoritesViewModel {
        defaultFavoritesViewModel()
    }

    static func defaultViewModel() -> FilesViewModel {
        // Base URL viene del shared UserDefaults (capturada al construir,
        // suficiente: el cambio de baseURL implica logout+login y reciclaje
        // del FilesViewModel). El username NO se captura — se lee dentro
        // del closure en cada llamada para que un cambio de usuario sin
        // recrear la VM (cold start vs hot reload, edge cases) no deje al
        // FilesViewModel apuntando a un namespace obsoleto.
        let sharedDefaults = NodeClientAppGroups.sharedUserDefaults()
        let baseURLString = sharedDefaults.string(forKey: SessionStore.baseURLKey)
            ?? UserDefaults.standard.string(forKey: SessionStore.baseURLKey)
            ?? "http://localhost:8080"
        let tokenStore = NodeClientAppGroups.makeSharedTokenStore()
        let baseURL = NodeAPIClient.resolveBaseURL(from: baseURLString)

        return FilesViewModel(
            apiClient: NodeAPIClient(baseURL: baseURL),
            sessionTokenProvider: {
                try? tokenStore.readToken()
            },
            syncNamespaceProvider: {
                Self.resolveCurrentNamespace()
            },
            // Vault compartido (singleton) para que la sesión de cifrado
            // abierta en Settings → Cifrado afecte a los uploads/downloads
            // desde Files.
            encryptionKeyVault: EncryptionKeyVault.shared,
            // Pre-check de cuota antes del upload: lee `quotaMb`
            // (sessionStore) + `quotaUsedBytes` (refresh profile) del
            // shared UserDefaults en cada llamada — captura cambios
            // sin reciclar el VM. Si falta cualquiera, devuelve nil
            // y el pre-check se omite (fail-open hasta tener datos).
            availableQuotaBytesProvider: {
                let defaults = NodeClientAppGroups.sharedUserDefaults()
                guard let quotaMb = defaults.object(forKey: SessionStore.quotaMbKey) as? Int,
                      let quotaUsedRaw = defaults.object(forKey: NodeClientAppGroups.quotaUsedBytesKey) as? Double
                else {
                    return nil
                }
                let totalBytes = Int64(quotaMb) * 1_048_576
                let usedBytes = Int64(quotaUsedRaw)
                return max(0, totalBytes - usedBytes)
            }
        )
    }

    static func defaultFavoritesViewModel() -> FavoritesViewModel {
        // Mismo razonamiento que en `defaultViewModel`: el namespace se
        // resuelve en cada lectura, no se captura. `FavoritesViewModel` se
        // recicla cuando el shell raíz se re-monta tras login, así que en
        // la práctica `resolveCurrentNamespace` se evalúa con el username
        // recién persistido. Si en el futuro alguien hace que la VM
        // sobreviva al swap de usuario, esto sigue siendo correcto.
        let namespace = Self.resolveCurrentNamespace()

        return FavoritesViewModel(
            store: UserDefaultsFavoritesStore(),
            snapshotStore: NodeClientAppGroups.makeSharedSyncStateStore(),
            namespace: namespace
        )
    }

    /// Resuelve el namespace activo leyendo el username del shared
    /// UserDefaults (con fallback a `.standard`). Devuelve `"anonymous"`
    /// si no hay sesión. Mismo contrato que `SessionStore.syncNamespace`
    /// pero accesible sin instancia — los closures en factories
    /// estáticas no tienen `sessionStore` en el scope.
    static func resolveCurrentNamespace() -> String {
        let sharedDefaults = NodeClientAppGroups.sharedUserDefaults()
        let username = sharedDefaults.string(forKey: SessionStore.usernameKey)
            ?? UserDefaults.standard.string(forKey: SessionStore.usernameKey)
        let normalized = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized?.isEmpty == false) ? normalized! : "anonymous"
    }
}
