//  Root view tras el auth gate — selecciona el shell según plataforma.
//
//  Mantiene la propiedad de los ViewModels compartidos (filesViewModel,
//  favoritesViewModel, moreViewModel) como `@StateObject` para que ambos
//  shells accedan al mismo state. La única bifurcación `#if os` del
//  proyecto vive aquí; el resto de divergencia iOS/macOS está en archivos
//  físicos separados (Shells/iOS, Shells/macOS, *+iOS.swift, *+macOS.swift).

import SwiftUI

struct NodeClientRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.scenePhase)
    private var scenePhase
    @StateObject private var moreViewModel = MoreViewModel()
    /// Compartidos entre las pestañas Files y Favorites para que las
    /// acciones (download, rename, delete, toggle favorito) operen sobre
    /// el mismo state y se mantenga la consistencia de progreso.
    @StateObject private var filesViewModel = FilesView.makeDefaultViewModel()
    @StateObject private var favoritesViewModel = FilesView.makeDefaultFavoritesViewModel()
    /// Loop de refresco mientras la app está en foreground. Cancela en
    /// background/inactive para no consumir red ni batería; reanuda al
    /// volver a `.active`. Es independiente del `BackgroundSyncScheduler`
    /// (BGAppRefresh / NSBackgroundActivityScheduler) que cubre el caso
    /// "app cerrada o suspendida".
    @State private var foregroundSyncTask: Task<Void, Never>?

    var body: some View {
        rootShell
            .onAppear { startForegroundSync() }
            .onDisappear { stopForegroundSync() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    startForegroundSync()

                case .inactive, .background:
                    stopForegroundSync()

                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder private var rootShell: some View {
#if os(iOS)
        IOSRootShell(
            filesViewModel: filesViewModel,
            favoritesViewModel: favoritesViewModel,
            moreViewModel: moreViewModel
        )
#else
        MacRootShell(
            filesViewModel: filesViewModel,
            favoritesViewModel: favoritesViewModel,
            moreViewModel: moreViewModel
        )
#endif
    }

    /// Intervalo conservador: 30 s mantiene latencia perceptible baja
    /// para cambios cross-device sin saturar el backend ni la red. Se
    /// ajusta aquí si el operador detecta carga excesiva.
    private static let foregroundSyncInterval: UInt64 = 30 * 1_000_000_000

    private func startForegroundSync() {
        guard foregroundSyncTask == nil else { return }
        foregroundSyncTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.foregroundSyncInterval)
                if Task.isCancelled { break }
                guard sessionStore.isAuthenticated else { continue }
                await filesViewModel.loadFiles(showsLoadingState: false)
                // Si el server rechazó con 401 (token revocado server-side
                // sin que la expiración local lo capturase), invalidamos
                // localmente para devolver al usuario al login. Sin esto,
                // el loop seguiría 401-ando cada 30s indefinidamente.
                // El logout cambia `sessionStore.isAuthenticated` → false,
                // `ContentView` swappea a LoginView, NodeClientRootView
                // desaparece y `.onDisappear` cancela esta Task.
                if filesViewModel.lastSyncFailedAuth {
                    // Logout reactivo por 401 detectado en el foreground
                    // sync loop. Misma cleanup chain que el logout manual y
                    // que el `.expired` del coordinator de refresh.
                    SessionLogoutCleaner.performLocalLogoutCleanup(sessionStore: sessionStore)
                    break
                }
            }
            foregroundSyncTask = nil
        }
    }

    private func stopForegroundSync() {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
    }
}

#Preview {
    NodeClientRootView()
        .environmentObject(SessionStore())
}
