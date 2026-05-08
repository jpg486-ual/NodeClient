import Combine
import Foundation

@MainActor
final class MoreViewModel: ObservableObject {
    @Published private(set) var isLoggingOut = false
    @Published private(set) var logoutMessage: String?
    /// Rol del usuario devuelto por `GET /auth/me`.
    @Published private(set) var role: String?
    /// Bytes consumidos. Política:
    /// 1. Fuente primaria: `sessionStore.quotaUsedBytes` (RS-inflated
    ///    autoritativo del backend `GET /auth/me`). Refleja el storage real
    ///    distribuido (factor n/k de Reed-Solomon) que el cluster cobra.
    /// 2. Fallback offline: suma de `entry.sizeBytes` del snapshot SQLite
    ///    filtrando `!deleted && entryType == .file`. Subestima la quota
    ///    real (ignora factor n/k) pero permite mostrar algo cuando no hay
    ///    sesión activa o el backend no respondió aún.
    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var isRefreshingProfile = false
    @Published private(set) var profileRefreshError: String?
#if DEBUG
    @Published private(set) var debugTelemetryRows: [DebugTelemetryRow] = []
#endif

    init(
        apiClientFactory: ((URL) -> NodeAPIClientProtocol)? = nil,
        syncStateStore: FilesSyncStateStore? = nil,
        telemetryStore: SyncTelemetryStore? = nil
    ) {
        self.apiClientFactory = apiClientFactory ?? { NodeAPIClient(baseURL: $0) }
        self.syncStateStore = syncStateStore ?? SQLiteFilesSyncStateStore()
        self.telemetryStore = telemetryStore ?? UserDefaultsSyncTelemetryStore()
#if DEBUG
        refreshDebugTelemetry()
#endif
    }

    func logout(sessionStore: SessionStore) async {
        guard !isLoggingOut else {
            return
        }

        isLoggingOut = true
        logoutMessage = nil
        defer { isLoggingOut = false }

        guard let token = sessionStore.sessionToken, !token.isEmpty else {
            SessionLogoutCleaner.performLocalLogoutCleanup(
                sessionStore: sessionStore,
                syncStateStore: syncStateStore
            )
            return
        }

        let baseURLText = sessionStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText) else {
            SessionLogoutCleaner.performLocalLogoutCleanup(
                sessionStore: sessionStore,
                syncStateStore: syncStateStore
            )
            logoutMessage = "Base URL inválida. Sesión local cerrada."
            return
        }

        let apiClient = apiClientFactory(baseURL)

        do {
            try await apiClient.logout(token: token)
            SessionLogoutCleaner.performLocalLogoutCleanup(
                sessionStore: sessionStore,
                syncStateStore: syncStateStore
            )
            logoutMessage = "Sesión cerrada en el nodo y en el dispositivo."
        } catch let error as NodeAPIError {
            SessionLogoutCleaner.performLocalLogoutCleanup(
                sessionStore: sessionStore,
                syncStateStore: syncStateStore
            )
            logoutMessage = Self.message(for: error)
        } catch {
            SessionLogoutCleaner.performLocalLogoutCleanup(
                sessionStore: sessionStore,
                syncStateStore: syncStateStore
            )
            logoutMessage = "No se pudo confirmar logout remoto. Sesión local cerrada."
        }
    }

    func clearLogoutMessage() {
        logoutMessage = nil
    }

        /// Refresca el perfil del usuario (`GET /auth/me`) y resuelve `usedBytes`
    /// con la política: backend `quotaUsedBytes` (RS-inflated, autoritativo)
    /// como fuente primaria; fallback al snapshot SQLite cuando no hay sesión
    /// activa o el backend falló. Llamado onAppear de MoreView + tras
    /// upload/delete (hook a invocar desde el caller cuando emerja).
    func refreshProfile(sessionStore: SessionStore) async {
        guard let token = sessionStore.sessionToken, !token.isEmpty else {
            // Sin sesión: usedBytes proviene del snapshot SQLite (fallback).
            recomputeUsedBytesFromSnapshot(namespace: sessionStore.syncNamespace)
            profileRefreshError = nil
            return
        }
        let baseURLText = sessionStore.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText) else {
            profileRefreshError = "Base URL inválida."
            return
        }

        isRefreshingProfile = true
        profileRefreshError = nil
        defer { isRefreshingProfile = false }

        let client = apiClientFactory(baseURL)
        do {
            let profile = try await client.fetchProfile(token: token)
            role = profile.role
            sessionStore.updateSession(
                baseURL: sessionStore.baseURL,
                token: token,
                username: profile.username,
                quotaMb: profile.quotaMb,
                expiresAt: sessionStore.sessionExpiresAt,
                quotaUsedBytes: profile.quotaUsedBytes
            )
            // Resolver `usedBytes` ahora que `sessionStore.quotaUsedBytes`
            // está actualizado con el valor RS-inflated del backend.
            resolveUsedBytes(sessionStore: sessionStore)
        } catch let error as NodeAPIError {
            profileRefreshError = Self.message(for: error)
            // Backend falló — caemos al snapshot SQLite si está disponible.
            recomputeUsedBytesFromSnapshot(namespace: sessionStore.syncNamespace)
        } catch {
            profileRefreshError = "No se pudo refrescar el perfil."
            recomputeUsedBytesFromSnapshot(namespace: sessionStore.syncNamespace)
        }
    }

    /// Aplica la política `usedBytes`: prefiere `sessionStore.quotaUsedBytes`
    /// (backend authoritative, RS-inflated); cae al snapshot SQLite cuando el
    /// backend aún no ha respondido.
    private func resolveUsedBytes(sessionStore: SessionStore) {
        if let backendUsedBytes = sessionStore.quotaUsedBytes {
            usedBytes = backendUsedBytes
            return
        }
        recomputeUsedBytesFromSnapshot(namespace: sessionStore.syncNamespace)
    }

    /// Fallback offline: suma raw `entry.sizeBytes` del SQLite snapshot.
    /// Subestima la quota real (ignora factor RS n/k) pero permite mostrar
    /// algo cuando el backend no está disponible aún.
    private func recomputeUsedBytesFromSnapshot(namespace: String) {
        guard let snapshot = syncStateStore.readSnapshot(namespace: namespace) else {
            usedBytes = 0
            return
        }
        usedBytes = snapshot.entries
            .filter { !$0.deleted && $0.entryType == .file }
            .map { $0.sizeBytes }
            .reduce(0, +)
    }

#if DEBUG
    func refreshDebugTelemetry() {
        let current = telemetryStore.snapshot()
        debugTelemetryRows = SyncTelemetryEvent.allCases.map { event in
            DebugTelemetryRow(eventName: event.rawValue, value: current[event, default: 0])
        }
    }

    func resetDebugTelemetry() {
        telemetryStore.resetAll()
        refreshDebugTelemetry()
    }
#endif

    private static func message(for error: NodeAPIError) -> String {
        switch error {
        case .unauthorized:
            return "La sesión ya no era válida. Sesión local cerrada."

        case .invalidURL:
            return "URL del nodo inválida. Sesión local cerrada."

        case .notFound:
            return "Endpoint de logout no encontrado. Sesión local cerrada."

        case let .api(_, errorCode, message):
            if errorCode == "INVALID_SESSION" {
                return "La sesión ya no era válida. Sesión local cerrada."
            }
            let base = message ?? "Error del nodo: \(errorCode)."
            return "\(base) Sesión local cerrada."

        case .server(let statusCode):
            return "El nodo respondió \(statusCode). Sesión local cerrada."

        case .transport(let detail):
            return "Error de red al cerrar sesión: \(detail). Sesión local cerrada."

        case .invalidResponse:
            return "Respuesta inválida del nodo. Sesión local cerrada."
        }
    }

    private let apiClientFactory: (URL) -> NodeAPIClientProtocol
    private let syncStateStore: FilesSyncStateStore
    private let telemetryStore: SyncTelemetryStore
}

#if DEBUG
struct DebugTelemetryRow: Equatable {
    let eventName: String
    let value: Int
}
#endif
