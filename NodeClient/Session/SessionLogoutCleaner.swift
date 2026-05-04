//  Limpieza completa al cerrar sesión.
//
//  `SessionStore.logout()` por sí mismo solo borra credenciales (token,
//  username, quota, expiresAt). Eso deja vivos otros stores que SÍ tienen
//  contenido del usuario:
//
//   - `FilesSyncStateStore`: snapshot SQLite del árbol (namespaced por
//     username). Si dos usuarios distintos terminan compartiendo namespace
//     (p.ej. ambos quedan en "anonymous" durante una ventana de auth),
//     el segundo ve el árbol del primero.
//   - `FavoritesStore`: lista de favoritos (UserDefaults, namespaced).
//   - `EncryptionKeyVault.shared`: la `SymmetricKey` activa en memoria.
//     Si el usuario A queda con vault unlocked y B inicia sesión sin
//     limpiar, los uploads de B se cifrarían con la key de A — fuga.
//
//  Este helper centraliza la limpieza y se llama desde:
//   - `MoreViewModel.logout(sessionStore:)` tras el logout remoto.
//   - `NodeClientApp.refreshSessionTokenIfNeeded()` cuando el server
//     devuelve `.expired` (token revocado).
//
//  Lo que NO se limpia (intencional):
//   - Encryption keychain entries (`verifier`, `salt`, `iterations`,
//     `token`): namespaced por username; un user B no puede leerlos del
//     namespace de A. Mantenerlos permite que A reentre sin re-importar
//     el token. Si A quiere borrarlos, tiene "Resetear cifrado" en Settings.
//   - Telemetría / observabilidad: métricas agregadas, no PII.

import Foundation

@MainActor
enum SessionLogoutCleaner {
    /// Ejecuta la limpieza local en el orden seguro: primero captura el
    /// namespace activo, luego borra los stores derivados, y finalmente
    /// invalida las credenciales en `sessionStore`. Si se invierte el
    /// orden el `syncNamespace` ya queda en `"anonymous"` y los `clear`
    /// no aciertan al namespace correcto.
    ///
    /// Los stores se inyectan con defaults a las factories compartidas
    /// para que producción no tenga que pasar nada y los tests puedan
    /// pasar mocks (los call sites como `MoreViewModel` ya tienen el
    /// `FilesSyncStateStore` inyectado y se lo pasan aquí para que el
    /// mock reciba la llamada de `clearSnapshot`).
    static func performLocalLogoutCleanup(
        sessionStore: SessionStore,
        syncStateStore: FilesSyncStateStore = NodeClientAppGroups.makeSharedSyncStateStore(),
        favoritesStore: FavoritesStore = UserDefaultsFavoritesStore(),
        keyVault: EncryptionKeyVault = .shared
    ) {
        let namespace = sessionStore.syncNamespace

        syncStateStore.clearSnapshot(namespace: namespace)
        favoritesStore.clear(namespace: namespace)
        keyVault.lock()

        sessionStore.logout()
    }
}
