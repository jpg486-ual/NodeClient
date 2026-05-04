//  BackgroundSyncScheduler.
//
//  Wrapper platform-specific sobre las APIs nativas de scheduling
//  background. iOS usa BGTaskScheduler, macOS usa
//  NSBackgroundActivityScheduler. La lógica funcional (qué hacer
//  cuando se dispara) vive en BackgroundSyncCoordinator.
//
//  Limitación: BGTaskScheduler iOS no es testeable
//  unitariamente; los tests cubren solo el coordinator.

import Foundation

/// Identifier reservado para BGTask iOS, declarado en
/// Info.plist `BGTaskSchedulerPermittedIdentifiers`.
public enum BackgroundSyncIdentifier {
    public static let appRefresh = "es.ual.NodeClient.refresh"
}

/// Política de scheduling. Configurable para tests con tolerance bajo
/// (1-2s) o producción con tolerance largo.
public struct BackgroundSyncPolicy {
    /// Intervalo mínimo entre ejecuciones (iOS earliestBeginDate
    /// offset; macOS interval).
    public let minimumInterval: TimeInterval
    /// Tolerance macOS (sin efecto iOS).
    public let tolerance: TimeInterval

    public static let production = Self(
        minimumInterval: 15 * 60,   // 15 min
        tolerance: 5 * 60           // 5 min macOS
    )

    public static let aggressive = Self(
        minimumInterval: 30 * 60,   // 30 min
        tolerance: 5 * 60
    )
}

protocol BackgroundSyncSchedulerProtocol {
    /// Programa la próxima ejecución del task background.
    func scheduleNextRefresh()
}

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// iOS BGTaskScheduler wrapper.
///
/// Uso típico (en NodeClientApp):
/// ```
/// .backgroundTask(.appRefresh(BackgroundSyncIdentifier.appRefresh)) {
///     let success = await coordinator.performBackgroundSync()
///     scheduler.scheduleNextRefresh()  // re-programar para próxima ventana
/// }
/// ```
struct IOSBackgroundSyncScheduler: BackgroundSyncSchedulerProtocol {
    let policy: BackgroundSyncPolicy

    init(policy: BackgroundSyncPolicy = .production) {
        self.policy = policy
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: BackgroundSyncIdentifier.appRefresh
        )
        request.earliestBeginDate = Date().addingTimeInterval(policy.minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler puede fallar si el identifier no está
            // declarado en Info.plist o si el task ya está pendiente.
            // No relanzamos: el coordinator no debe propagarlo a UI.
            // El error queda implícito en la ausencia de execución
            // futura, capturable via telemetry sync.background.skipped.
        }
    }
}
#endif

#if os(macOS)
/// macOS NSBackgroundActivityScheduler wrapper.
///
/// Uso típico (en NodeClientApp init o una vez al login):
/// ```
/// scheduler.scheduleNextRefresh()
/// // El scheduler vive como propiedad fuerte; cancelar con stop().
/// ```
final class MacOSBackgroundSyncScheduler: BackgroundSyncSchedulerProtocol {
    let policy: BackgroundSyncPolicy
    let onFire: () async -> Void
    private var activity: NSBackgroundActivityScheduler?

    init(
        policy: BackgroundSyncPolicy = .production,
        onFire: @escaping () async -> Void
    ) {
        self.policy = policy
        self.onFire = onFire
    }

    func scheduleNextRefresh() {
        let act = NSBackgroundActivityScheduler(
            identifier: BackgroundSyncIdentifier.appRefresh
        )
        act.repeats = true
        act.interval = policy.minimumInterval
        act.tolerance = policy.tolerance
        act.qualityOfService = .utility
        act.schedule { [weak self] completion in
            Task { [weak self] in
                await self?.onFire()
                completion(.finished)
            }
        }
        self.activity = act
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }
}
#endif
