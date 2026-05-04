//  Extensión iOS de FilesView — concentra el chrome iOS (refreshable
//  pull-gesture, fileImporter con allowsMultipleSelection, share sheet
//  vía UIActivityViewController, save-to-files via share sheet).
//
//  El archivo entero está envuelto en `#if os(iOS)` para no compilarse
//  en macOS. La divergencia plataforma queda físicamente separada.

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension FilesView {
    /// `baseNavigation` envuelta en `.refreshable` (pull-gesture).
    var platformRefreshable: AnyView {
        AnyView(
            baseNavigation
                .refreshable {
                    await viewModel.loadFiles(showsLoadingState: false)
                }
        )
    }

    /// El `.fileImporter` se ancla directamente al botón disparador
    /// (`uploadFAB`) — no a la cadena central — para que se presente
    /// sobre el destino actual cuando el usuario está dentro de una
    /// subcarpeta. Mismo razonamiento que el alert "New Folder".
    var platformFileImporter: AnyView {
        AnyView(withAlerts)
    }

    /// Share sheet sobre `platformFileImporter`.
    var platformShareSheetWrapper: AnyView {
        AnyView(
            platformFileImporter
                .sheet(isPresented: $isShareSheetPresented, onDismiss: {
                    shareFileURL = nil
                    viewModel.clearDownloadedFileURL()
                }) {
                    if let url = shareFileURL {
                        FileShareActivityView(activityItems: [url]) { completed, errorDescription in
                            viewModel.completeShare(completed: completed, errorDescription: errorDescription)
                        }
                    } else {
                        EmptyView()
                    }
                }
        )
    }

    var saveActionTitle: String { "Guardar en Archivos" }

    /// En iOS el "guardar en Archivos" es vía share sheet — el sistema
    /// presenta un picker que el usuario navega para elegir destino.
    func handleSaveToFiles() {
        guard let sourceURL = viewModel.downloadedFileURL else { return }
        shareFileURL = sourceURL
        isShareSheetPresented = sourceURL != nil
    }

    /// iOS no añade items extra a la toolbar — el pull-to-refresh es
    /// gesture nativo, no hace falta botón de Refresh.
    @ToolbarContentBuilder var platformExtraToolbarItems: some ToolbarContent {
        if false {
            ToolbarItem(placement: .automatic) { EmptyView() }
        }
    }

    /// iOS preserva la FAB clásica (overlay bottom-trailing) con
    /// nueva carpeta + subir archivo. Patrón móvil estándar.
    @ViewBuilder var platformFloatingActionMenu: some View {
        floatingActionMenu
    }
}

/// Wrapper SwiftUI sobre `UIActivityViewController` para presentar el
/// share sheet desde un `.sheet`. iOS-only.
struct FileShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: (Bool, String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            onComplete(completed, error?.localizedDescription)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
