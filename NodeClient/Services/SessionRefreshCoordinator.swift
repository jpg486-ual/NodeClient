//  Refresh proactivo de tokens de sesión.
//
//  Backend revoca tokens al refrescar y rechaza refresh sobre tokens
//  expirados (401). Como TTL es de 7 días, esta política es de margen
//  amplio: refrescamos solo cuando el token está dentro de la última
//  hora de validez.
//
//  Cross-process: se comparte el mismo `(token, expiresAt)`
//  vía Keychain access group + App Group UserDefaults. Si ambos entran
//  a la ventana de 1h al mismo tiempo, el `CrossProcessFileLock`
//  garantiza que solo uno haga el HTTP refresh; el segundo re-lee tras
//  adquirir el lock y se entera de que ya hay token nuevo.
//
//  Single-flight intra-proceso: el actor serializa concurrencia dentro
//  del mismo proceso. 5 ops async paralelas → 1 sola HTTP call.

import Foundation

actor SessionRefreshCoordinator {
    enum RefreshResult: Equatable {
        /// Sesión activa y aún fuera de la ventana de margen.
        case stillValid(token: String)
        /// Refresh ejecutado con éxito; nuevo token persistido.
        case refreshed(token: String, expiresAt: Date)
        /// No hay sesión activa (el caller decide flujo de login).
        case noActiveSession
        /// Refresh devolvió 401 — token revocado o expirado pre-refresh.
        /// El coordinator ya limpió la sesión persistida; el caller
        /// debe redirigir a Login.
        case expired
    }

    /// Margen pre-expiración: si `expiresAt - now ≤ marginSeconds`,
    /// dispara refresh. 1 hora cubre con holgura latencia de red,
    /// drift de reloj y lock contention.
    static let defaultMarginSeconds: TimeInterval = 3_600

    private let apiClient: SessionRefreshAPIClient
    private let tokenStore: SessionTokenStore
    private let userDefaults: UserDefaults
    private let lock: CrossProcessFileLock?
    private let clock: @Sendable () -> Date
    private let marginSeconds: TimeInterval
    /// Single-flight intra-proceso: si una tarea de refresh está en
    /// vuelo, otras llamadas await su resultado en lugar de iniciar
    /// otra (sin esto, las 5 calls concurrentes entrarían al
    /// `apiClient.refresh` por reentrancy del actor en el await).
    private var inFlightRefresh: Task<RefreshResult, Never>?

    init(
        apiClient: SessionRefreshAPIClient,
        tokenStore: SessionTokenStore,
        userDefaults: UserDefaults,
        lock: CrossProcessFileLock?,
        clock: @Sendable @escaping () -> Date = Date.init,
        marginSeconds: TimeInterval = SessionRefreshCoordinator.defaultMarginSeconds
    ) {
        self.apiClient = apiClient
        self.tokenStore = tokenStore
        self.userDefaults = userDefaults
        self.lock = lock
        self.clock = clock
        self.marginSeconds = marginSeconds
    }

    /// Devuelve token actual (o refresca y devuelve el nuevo). Cero
    /// efectos secundarios si el token tiene >1h de vida — caller barato
    /// llamarlo en cualquier punto.
    func ensureFreshTokenIfNeeded() async -> RefreshResult {
        // Quick path sincrono dentro del actor: si no estamos en margen,
        // devolvemos sin tocar nada (no hay await, no hay reentrancy).
        guard let currentToken = readCurrentToken(), !currentToken.isEmpty else {
            return .noActiveSession
        }
        guard let expiresAt = readExpiresAt() else {
            return .stillValid(token: currentToken)
        }
        if !inMargin(expiresAt: expiresAt) {
            return .stillValid(token: currentToken)
        }

        // En margen — single-flight: si ya hay refresh en vuelo, espera
        // su resultado en lugar de iniciar otro (HTTP refresh revocaría
        // el token nuevo del primero).
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let task = Task<RefreshResult, Never> { [weak self] in
            guard let self else { return .noActiveSession }
            return await self.performRefresh()
        }
        inFlightRefresh = task
        let result = await task.value
        // Limpiamos para que el siguiente caller pueda iniciar uno nuevo
        // si volvemos a estar en margen (raro: solo si el server emite
        // tokens con TTL ≤ marginSeconds).
        inFlightRefresh = nil
        return result
    }

    /// Critical section sobre el flock del App Group container. Con un
    /// único proceso es no-op; preparado para coordinar con futuras
    /// extensiones. Aislado del entry-point para que el
    /// patrón single-flight pueda envolver TODA la I/O en una sola tarea.
    private func performRefresh() async -> RefreshResult {
        let handle: CrossProcessFileLock.Handle?
        if let lock {
            do {
                handle = try lock.acquire()
            } catch {
                handle = nil
            }
        } else {
            handle = nil
        }
        defer { handle?.release() }

        // Re-leer estado tras adquirir el lock — el otro proceso pudo
        // haber refrescado mientras esperábamos.
        guard let postLockToken = readCurrentToken(), !postLockToken.isEmpty else {
            return .noActiveSession
        }
        guard let postLockExpiresAt = readExpiresAt() else {
            return .stillValid(token: postLockToken)
        }
        if !inMargin(expiresAt: postLockExpiresAt) {
            return .stillValid(token: postLockToken)
        }

        do {
            let response = try await apiClient.refresh(token: postLockToken)
            try persist(token: response.token, expiresAt: response.expiresAt)
            return .refreshed(token: response.token, expiresAt: response.expiresAt)
        } catch let NodeAPIError.api(statusCode, _, _) where statusCode == 401 {
            clearPersistedSession()
            return .expired
        } catch {
            return .stillValid(token: postLockToken)
        }
    }

    /// Helper para callers que solo necesitan "dame un token usable
    /// ahora" — refresca si toca, lanza si la sesión está expirada o
    /// ausente.
    func currentTokenIfActive() async throws -> String {
        switch await ensureFreshTokenIfNeeded() {
        case let .stillValid(token):
            return token

        case let .refreshed(token, _):
            return token

        case .noActiveSession:
            throw SessionUnavailableError.noActiveSession

        case .expired:
            throw SessionUnavailableError.expired
        }
    }

    /// Hook de logout para invalidar cache (no aplica al actor, pero
    /// expone API simétrica con el resto de stores compartidos).
    func invalidate() {
        clearPersistedSession()
    }

    // MARK: - Helpers

    private func inMargin(expiresAt: Date) -> Bool {
        let now = clock()
        return expiresAt.timeIntervalSince(now) <= marginSeconds
    }

    private func readCurrentToken() -> String? {
        try? tokenStore.readToken()
    }

    private func readExpiresAt() -> Date? {
        guard let raw = userDefaults.object(forKey: NodeClientAppGroups.sessionExpiresAtKey) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: raw)
    }

    private func persist(token: String, expiresAt: Date) throws {
        try tokenStore.writeToken(token)
        userDefaults.set(expiresAt.timeIntervalSince1970, forKey: NodeClientAppGroups.sessionExpiresAtKey)
    }

    private func clearPersistedSession() {
        try? tokenStore.deleteToken()
        userDefaults.removeObject(forKey: NodeClientAppGroups.sessionExpiresAtKey)
        userDefaults.removeObject(forKey: NodeClientAppGroups.sessionTokenLegacyKey)
    }
}

enum SessionUnavailableError: Error, Equatable {
    case noActiveSession
    case expired
}
