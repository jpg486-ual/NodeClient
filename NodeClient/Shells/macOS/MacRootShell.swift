//  Shell raíz macOS — NavigationSplitView con sidebar (Archivos / Favoritos /
//  Cifrado / Ajustes) y detail panel reusando los `body` de cada vista
//  existente.

#if os(macOS)
import SwiftUI

struct MacRootShell: View {
    @ObservedObject var filesViewModel: FilesViewModel
    @ObservedObject var favoritesViewModel: FavoritesViewModel
    @ObservedObject var moreViewModel: MoreViewModel
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var selection: SidebarDestination? = .files
    /// Pila de paths del NavigationStack de FilesView, lifted al shell para
    /// que sobreviva el swap del detail panel y SwiftUI no crashee al
    /// reconciliar el path durante el teardown.
    @State private var filesFolderStack: [String] = []

    /// Binding custom para la sidebar selection: vacía `filesFolderStack`
    /// **en el mismo set** en que cambia la selección cuando el usuario sale
    /// de Archivos. Crítico para evitar el crash de SwiftUI
    /// `AnyNavigationPath.Error.comparisonTypeMismatch` — usar `.onChange`
    /// no basta porque corre tras la re-renderización (FilesView ya está
    /// siendo destruida con el path obsoleto). Aquí ambos `@State` writes
    /// quedan en el mismo transaction batch y la re-render lee `[]`.
    private var selectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { selection },
            set: { newSelection in
                if newSelection != .files {
                    filesFolderStack = []
                }
                selection = newSelection
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            MacSidebarView(
                selection: selectionBinding,
                username: sessionStore.username,
                quotaMb: sessionStore.quotaMb,
                usedBytes: moreViewModel.usedBytes,
                role: moreViewModel.role,
                isLoggingOut: moreViewModel.isLoggingOut,
                logoutMessage: moreViewModel.logoutMessage,
                onLogout: {
                    await moreViewModel.logout(sessionStore: sessionStore)
                },
                onDismissLogoutMessage: {
                    moreViewModel.clearLogoutMessage()
                }
            )
        } detail: {
            MacDetailHost(
                destination: selection ?? .files,
                filesViewModel: filesViewModel,
                favoritesViewModel: favoritesViewModel,
                moreViewModel: moreViewModel,
                filesFolderStack: $filesFolderStack
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await moreViewModel.refreshProfile(sessionStore: sessionStore)
        }
        // Cuando otra vista (típicamente FavoritesView al tocar una
        // carpeta favorita) solicita navegar a un path, cambiamos
        // automáticamente la sidebar a Archivos. FilesView observa el
        // mismo valor y empuja al folderStack tras el cambio. No
        // pasamos por `selectionBinding` porque ir HACIA `.files` no
        // requiere limpiar la pila (de hecho, el `consumePendingFolderNavigation`
        // de FilesView la rellenará con el path solicitado).
        .onChange(of: filesViewModel.requestedFolderNavigation) { _, request in
            if request != nil {
                selection = .files
            }
        }
    }
}
#endif
