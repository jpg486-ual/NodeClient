//  Extensión macOS de FilesView — concentra el chrome Mac (toolbar
//  refresh button, NSWorkspace reveal en Finder en lugar de share sheet,
//  fileImporter sin allowsMultipleSelection).
//
//  Evitamos `NSSavePanel` desde el Button de un .alert: presenta
//  modal-on-modal y crashea con EXC_BREAKPOINT en algunas configuraciones
//  de sandbox. En su lugar pedimos a Finder que seleccione el archivo
//  ya descargado en su ubicación temporal — el usuario lo arrastra/copia
//  donde quiera.

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FilesView {
    /// macOS no aplica gesture pull-to-refresh: la navegación base se
    /// devuelve sin envolverla. El refresh se hace por botón de toolbar.
    var platformRefreshable: AnyView {
        AnyView(baseNavigation)
    }

    /// El `.fileImporter` se ancla directamente al botón disparador
    /// (`uploadToolbarButton`) — no a la cadena central — para que se
    /// presente sobre el destino actual cuando el usuario está dentro
    /// de una subcarpeta.
    var platformFileImporter: AnyView {
        AnyView(withAlerts)
    }

    /// macOS no necesita share sheet — la acción de "guardar" abre Finder.
    var platformShareSheetWrapper: AnyView {
        platformFileImporter
    }

    var saveActionTitle: String { "Mostrar en Finder" }

    /// Pide a Finder que seleccione el archivo descargado. Diferido
    /// fuera del cycle del alert para que el sistema desmonte el modal
    /// antes de pedirle a Finder que tome foco.
    func handleSaveToFiles() {
        guard let sourceURL = viewModel.downloadedFileURL else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            viewModel.completeShare(completed: true, errorDescription: nil)
            viewModel.clearDownloadedFileURL()
        }
    }

    /// Toolbar macOS — refresh + nueva carpeta + subir archivo. Usamos
    /// `.primaryAction` para que macOS los pegue al borde derecho del
    /// toolbar de la ventana de forma consistente, sin shifts cuando
    /// cambia el navigationTitle. Los botones de nueva carpeta y subir
    /// llevan sus modificadores (.alert / .fileImporter) anclados al
    /// propio botón en `FilesView` para evitar el bug de SwiftUI que
    /// difiere alerts de modifiers anclados en vistas obscurecidas
    /// por un push de NavigationStack.
    @ToolbarContentBuilder var platformExtraToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.loadFiles() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Recargar")
            .help("Recargar archivos")
        }
        ToolbarItem(placement: .primaryAction) {
            newFolderToolbarButton
        }
        ToolbarItem(placement: .primaryAction) {
            uploadToolbarButton
        }
    }

    /// macOS no usa FAB — los equivalentes (nueva carpeta, subir
    /// archivo) viven ya en `platformExtraToolbarItems`. La overlay
    /// queda vacía para no introducir hit-testing fantasma sobre el
    /// contenido.
    @ViewBuilder var platformFloatingActionMenu: some View {
        EmptyView()
    }
}
#endif
