//  BackgroundSyncCoordinator.
//
//  Lógica funcional cross-platform de sync en segundo plano.
//  Independiente de la API platform-specific (BGTaskScheduler iOS /
//  NSBackgroundActivityScheduler macOS), que vive en
//  BackgroundSyncScheduler.
//
//  Política offline respetada: sin red o sin sesión termina
//  silenciosamente con telemetry. Nunca despierta UI.

import Foundation

protocol BackgroundSyncCoordinatorProtocol: AnyObject {
    /// Ejecuta una pasada de sync background. Devuelve `true` si el sync
    /// se completó con éxito, `false` si se omitió o falló.
    /// El llamador (BGTask handler) usa el bool para reportar `setTaskCompleted(success:)`.
    func performBackgroundSync() async -> Bool
}

@MainActor
final class BackgroundSyncCoordinator: BackgroundSyncCoordinatorProtocol {
    init(
        sessionStore: SessionStore,
        repository: FilesRepositoryProtocol,
        telemetry: SyncTelemetryStore,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.sessionStore = sessionStore
        self.repository = repository
        self.telemetry = telemetry
        self.clock = clock
    }

    func performBackgroundSync() async -> Bool {
        telemetry.increment(.syncBackgroundAttempt)

        // 1. Sin sesión activa → skip silencioso.
        guard let token = sessionStore.sessionToken, !token.isEmpty else {
            telemetry.increment(.syncBackgroundSkippedNoSession)
            return false
        }

        let namespace = sessionStore.syncNamespace

        // 2. Intentar sync delegando en repositorio.
        do {
            _ = try await repository.synchronizeFiles(token: token, namespace: namespace)
            telemetry.increment(.syncBackgroundSuccess)
            return true
        } catch let error as NodeAPIError {
            switch error {
            case .transport:
                // Sin red → política offline: skip silencioso.
                telemetry.increment(.syncBackgroundSkippedOffline)
                return false

            default:
                telemetry.increment(.syncBackgroundErrorApi)
                return false
            }
        } catch {
            telemetry.increment(.syncBackgroundErrorUnexpected)
            return false
        }
    }

    private let sessionStore: SessionStore
    private let repository: FilesRepositoryProtocol
    private let telemetry: SyncTelemetryStore
    private let clock: () -> Date
}
