//  Shell raíz iOS — TabView con Archivos / Favoritos / Ajustes.
//
//  La lógica iOS del shell vive aquí,
//  el archivo entero está envuelto en `#if os(iOS)` para no compilarse
//  en macOS. NodeClientRootView elige el shell según plataforma.

#if os(iOS)
import SwiftUI

struct IOSRootShell: View {
    @ObservedObject var filesViewModel: FilesViewModel
    @ObservedObject var favoritesViewModel: FavoritesViewModel
    @ObservedObject var moreViewModel: MoreViewModel
    @EnvironmentObject private var sessionStore: SessionStore
    /// Pila de paths del NavigationStack de FilesView. Lifted al shell por
    /// simetría con macOS (donde es necesario para evitar crashes durante
    /// el swap del detail panel). En iOS la TabView preserva FilesView
    /// alive, así que el path solo se modifica desde la propia tab.
    @State private var filesFolderStack: [String] = []

    // Tabs depurados.
    enum Tab {
        case files
        case favorites
        case more
    }

    @State private var selectedTab: Tab = .files

    var body: some View {
        TabView(selection: $selectedTab) {
            FilesView(
                viewModel: filesViewModel,
                favoritesViewModel: favoritesViewModel,
                folderStack: $filesFolderStack
            )
                .tabItem {
                    Label("Archivos", systemImage: "folder")
                }
                .tag(Tab.files)

            FavoritesView(
                filesViewModel: filesViewModel,
                favoritesViewModel: favoritesViewModel
            )
                .tabItem {
                    Label("Favoritos", systemImage: "star")
                }
                .tag(Tab.favorites)

#if DEBUG
            MoreView(
                onLogout: {
                    await moreViewModel.logout(sessionStore: sessionStore)
                },
                isLoggingOut: moreViewModel.isLoggingOut,
                logoutMessage: moreViewModel.logoutMessage,
                onDismissLogoutMessage: {
                    moreViewModel.clearLogoutMessage()
                },
                role: moreViewModel.role,
                usedBytes: moreViewModel.usedBytes,
                isRefreshingProfile: moreViewModel.isRefreshingProfile,
                onRefreshProfile: {
                    await moreViewModel.refreshProfile(sessionStore: sessionStore)
                },
                debugTelemetryRows: moreViewModel.debugTelemetryRows,
                onRefreshDebugTelemetry: {
                    moreViewModel.refreshDebugTelemetry()
                },
                onResetDebugTelemetry: {
                    moreViewModel.resetDebugTelemetry()
                }
            )
                .tabItem {
                    Label("Ajustes", systemImage: "gearshape")
                }
                .tag(Tab.more)
#else
            MoreView(
                onLogout: {
                    await moreViewModel.logout(sessionStore: sessionStore)
                },
                isLoggingOut: moreViewModel.isLoggingOut,
                logoutMessage: moreViewModel.logoutMessage,
                onDismissLogoutMessage: {
                    moreViewModel.clearLogoutMessage()
                },
                role: moreViewModel.role,
                usedBytes: moreViewModel.usedBytes,
                isRefreshingProfile: moreViewModel.isRefreshingProfile,
                onRefreshProfile: {
                    await moreViewModel.refreshProfile(sessionStore: sessionStore)
                }
            )
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.more)
#endif
        }
        // Cuando otra vista (típicamente FavoritesView al tocar una
        // carpeta favorita) solicita navegar a un path, cambiamos
        // automáticamente a la tab Files. FilesView observa el mismo
        // valor y empuja al folderStack tras el cambio de tab.
        .onChange(of: filesViewModel.requestedFolderNavigation) { _, request in
            if request != nil {
                selectedTab = .files
            }
        }
    }
}
#endif
