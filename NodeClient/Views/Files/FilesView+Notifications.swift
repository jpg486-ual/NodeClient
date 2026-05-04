//  Modificadores user-facing (alerts, confirmation dialogs, sheets)
//  extraídos del `FilesView` principal para mantenerlo navegable.
//
//  Se aplican vía `applyNotificationModifiers` desde
//  `folderContent(for:)`, NO desde `baseNavigation`. Razón: el bug de
//  SwiftUI con `NavigationStack` + `NavigationSplitView` difiere
//  alerts/sheets cuyo anchor está en una vista obscurecida por un
//  push. Anclar al destino actualmente visible los presenta en su
//  contexto correcto.

import SwiftUI

extension FilesView {
    @ViewBuilder
    func applyNotificationModifiers(_ content: some View) -> some View {
        content
            .alert(
                "Descarga",
                isPresented: Binding(
                    get: { viewModel.downloadStatusMessage != nil },
                    set: { newValue in
                        if !newValue {
                            viewModel.clearDownloadStatus()
                        }
                    }
                ),
                actions: {
                    if viewModel.downloadedFileURL != nil {
                        Button(saveActionTitle) {
                            handleSaveToFiles()
                        }
                    }
                    Button("OK", role: .cancel) {
                        viewModel.clearDownloadStatus()
                    }
                },
                message: {
                    Text(viewModel.downloadStatusMessage ?? "")
                }
            )
            .alert(
                "Share",
                isPresented: Binding(
                    get: { viewModel.shareStatusMessage != nil },
                    set: { newValue in
                        if !newValue {
                            viewModel.clearShareStatus()
                        }
                    }
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        viewModel.clearShareStatus()
                    }
                },
                message: {
                    Text(viewModel.shareStatusMessage ?? "")
                }
            )
            .alert(
                "Info",
                isPresented: Binding(
                    get: { generalStatusMessage != nil },
                    set: { newValue in
                        if !newValue {
                            clearGeneralStatus()
                        }
                    }
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        clearGeneralStatus()
                    }
                },
                message: {
                    Text(generalStatusMessage ?? "")
                }
            )
            .confirmationDialog(
                "¿Eliminar archivo?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { item in
                Button("Eliminar", role: .destructive) {
                    let target = item
                    pendingDeletion = nil
                    Task { await viewModel.deleteFile(target) }
                }
                Button("Cancelar", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { _ in
                Text("Esta acción no se puede deshacer. El archivo se borrará permanentemente.")
            }
            // Confirmation cuando un upload colisiona con un path ya
            // asignado a un archivo vivo. Sobreescribir implica reusar
            // el entryId canónico del backend (que reserva los paths
            // de por vida) e incrementar la version.
            .confirmationDialog(
                "¿Sobreescribir archivo?",
                // Binding set NO toca `pendingOverwrite` — el dialog
                // dismissa por el Button tap, que es quien controla
                // la transición. Si setteáramos a nil aquí desde el
                // setter, el Task async perdería la referencia
                // antes de leerla (race fix).
                isPresented: Binding(
                    get: { viewModel.pendingOverwrite != nil },
                    set: { _ in }
                ),
                titleVisibility: .visible,
                presenting: viewModel.pendingOverwrite
            ) { proposal in
                Button("Sobreescribir", role: .destructive) {
                    // Capturamos `proposal` síncronamente en el closure
                    // y se lo pasamos al Task. Aunque la dismissal del
                    // dialog mute `pendingOverwrite` antes de que el
                    // Task ejecute, el snapshot local sobrevive.
                    let captured = proposal
                    Task { await viewModel.confirmPendingOverwrite(captured) }
                }
                Button("Cancelar", role: .cancel) {
                    viewModel.cancelPendingOverwrite()
                }
            } message: { proposal in
                Text("Ya existe un archivo «\(proposal.fileName)» en esta carpeta. Si confirmas, su contenido se reemplazará por el archivo nuevo. La versión anterior no se podrá recuperar.")
            }
            .alert(
                "Renombrar",
                isPresented: Binding(
                    get: { pendingRename != nil },
                    set: { if !$0 { pendingRename = nil } }
                ),
                presenting: pendingRename
            ) { item in
                TextField("Nuevo nombre", text: $pendingRenameNewName)
                    .platformIdentifierField()
                Button("Renombrar") {
                    let target = item
                    let newName = pendingRenameNewName
                    pendingRename = nil
                    pendingRenameNewName = ""
                    Task { await viewModel.renameFile(target, to: newName) }
                }
                Button("Cancelar", role: .cancel) {
                    pendingRename = nil
                    pendingRenameNewName = ""
                }
            } message: { item in
                Text("Introduce el nuevo nombre para «\(item.name)».")
            }
            .sheet(
                isPresented: Binding(
                    get: { pendingMove != nil },
                    set: { if !$0 { pendingMove = nil } }
                )
            ) {
                if let target = pendingMove {
                    MoveDestinationPickerView(
                        item: target,
                        availableFolders: availableFolders(excluding: target),
                        onCancel: { pendingMove = nil },
                        onPick: { destination in
                            pendingMove = nil
                            Task { await viewModel.moveFile(target, to: destination) }
                        }
                    )
                }
            }
    }

    /// Recopila paths de carpetas visibles + raíz "/", filtrando la
    /// propia carpeta padre del archivo (movimiento al mismo sitio
    /// sería no-op).
    func availableFolders(excluding item: FileItem) -> [String] {
        var paths: Set<String> = ["/"]
        for entry in viewModel.visibleFiles where entry.isFolder && entry.id != item.id {
            if !entry.path.isEmpty { paths.insert(entry.path) }
        }
        return paths.sorted()
    }
}
