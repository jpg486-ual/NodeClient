//  Identifiers + factories de stores compartidos vía App Group y
//  Keychain access group. Infraestructura preparada para activar las
//  direcciones futuras sin
//  regenerar provisioning profile. Con un único proceso es no-op
//  funcional; los entitlements quedan firmados.

import Foundation

enum NodeClientAppGroups {
    /// App Group identifier compartido. Tiene que estar registrado
    /// en el portal Apple Developer del team `NZT7MS65HC` (provisioning
    /// automatic en Simulator basta con declararlo en entitlements).
    static let sharedAppGroup = "group.es.ual.NodeClient"

    /// Keychain access group identifier. Formato `<TEAM>.<bundle-prefix>`.
    /// Habilita lectura/escritura compartida del keychain con futuros
    /// consumidores.
    static let sharedKeychainAccessGroup = "NZT7MS65HC.es.ual.NodeClient"

    // MARK: - UserDefaults shared keys
    //
    // Las constantes viven en este enum (no en `SessionStore`) para que
    // futuros consumidores compartidos puedan leer/escribir
    // directamente en el suite sin importar las dependencias de UI
    // del `SessionStore`.

    /// Key en shared UserDefaults para el `Date.timeIntervalSince1970`
    /// del `expiresAt` de la sesión activa. Lo lee `SessionRefreshCoordinator`
    /// para decidir refresh proactivo en margen 1h.
    static let sessionExpiresAtKey = "node.sessionExpiresAt"

    /// Key en shared UserDefaults para `quotaUsedBytes` (live RS-inflated
    /// consumption del usuario, computado server-side). Persistido como
    /// `Double` para evitar issues de precisión con Int64 en NSNumber.
    /// Refrescado en cada `MoreViewModel.refreshProfile`.
    static let quotaUsedBytesKey = "node.quotaUsedBytes"

    /// Key legacy del session token cuando aún se persistía en
    /// UserDefaults (pre-Keychain). Mantenida solo para que la
    /// migración de SessionStore.init la pueda limpiar.
    static let sessionTokenLegacyKey = "node.sessionToken"

    /// Returns la URL del container App Group si el binario tiene
    /// el entitlement firmado correctamente, `nil` en otro caso
    /// (tests SwiftPM sin firma, builds locales sin provisioning).
    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroup)
    }

    /// Directorio base donde todos los stores SQLite y caches de la
    /// app principal y la extensión deben persistir sus datos.
    /// Prioriza el App Group container; si no está disponible cae a
    /// `applicationSupport` o a `temporaryDirectory` como último
    /// recurso.
    static func resolvedDataDirectory(fileManager: FileManager = .default) -> URL {
        let baseDirectory: URL
        if let appGroupContainer = containerURL(fileManager: fileManager) {
            baseDirectory = appGroupContainer
        } else if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            baseDirectory = appSupport
        } else {
            baseDirectory = fileManager.temporaryDirectory
        }
        return baseDirectory.appendingPathComponent("NodeClient", isDirectory: true)
    }

    /// `UserDefaults(suiteName:)` compartido entre app y extensión.
    /// Cae a `.standard` si el suite no está disponible (entitlement
    /// faltante).
    static func sharedUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: sharedAppGroup) ?? .standard
    }

    // MARK: - Factories shared

    /// Token store con `kSecAttrAccessGroup` declarado, preparado
    /// para que futuros consumidores compartidos lean el
    /// item escrito por la app.
    static func makeSharedTokenStore() -> KeychainSessionTokenStore {
        KeychainSessionTokenStore(accessGroup: sharedKeychainAccessGroup)
    }

    /// Telemetría persistida en el suite compartido.
    static func makeSharedTelemetry(
        userDefaults: UserDefaults? = nil
    ) -> SyncTelemetryStore {
        UserDefaultsSyncTelemetryStore(
            userDefaults: userDefaults ?? sharedUserDefaults()
        )
    }

    /// SQLite sync state store con path resuelto vía
    /// `resolvedDataDirectory` (App Group container o fallback).
    static func makeSharedSyncStateStore(
        fileManager: FileManager = .default
    ) -> SQLiteFilesSyncStateStore {
        SQLiteFilesSyncStateStore(
            fileManager: fileManager,
            telemetryStore: makeSharedTelemetry()
        )
    }

    /// Keychain store de cifrado con `kSecAttrAccessGroup` declarado.
    /// Diseñado para que un consumidor compartido pueda
    /// resolver la `SymmetricKey` del usuario sin re-prompt de password.
    /// El access group `NZT7MS65HC.es.ual.NodeClient` queda firmado
    /// como infraestructura preparada.
    static func makeSharedEncryptionPasswordStore() -> KeychainEncryptionPasswordStore {
        KeychainEncryptionPasswordStore(accessGroup: sharedKeychainAccessGroup)
    }

    /// Lock advisory `flock(2)` sobre `<App Group container>/refresh.lock`
    /// para serializar refresh de token entre procesos. Con un único
    /// proceso queda como no-op funcional; preparado para reactivar la
    /// coordinación cross-process si se añade la extensión.
    /// Devuelve nil si el container no está disponible (entitlement
    /// faltante en build local).
    static func makeSharedRefreshLock(
        fileManager: FileManager = .default
    ) -> CrossProcessFileLock? {
        guard let container = containerURL(fileManager: fileManager) else {
            return nil
        }
        return CrossProcessFileLock(
            path: container.appendingPathComponent("refresh.lock", isDirectory: false)
        )
    }

    /// Factory unificada del `SessionRefreshCoordinator`. Centraliza
    /// la inyección de stores compartidos (token Keychain + UserDefaults
    /// expiresAt + flock container) para que cualquier consumidor
    /// presente o futuro reciba la misma configuración.
    static func makeSharedRefreshCoordinator(
        apiClient: NodeAPIClientProtocol
    ) -> SessionRefreshCoordinator {
        SessionRefreshCoordinator(
            apiClient: apiClient,
            tokenStore: makeSharedTokenStore(),
            userDefaults: sharedUserDefaults(),
            lock: makeSharedRefreshLock()
        )
    }
}
