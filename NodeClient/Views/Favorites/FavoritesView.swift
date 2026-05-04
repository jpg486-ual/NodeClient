//  Vista de favoritos con búsqueda y acciones por elemento.
//  Reusa `FileRowView` cruzando los IDs favoritos con `viewModel.files`
//  para presentar los `FileItem` reales y delegar download/rename/move/
//  delete/toggle-favorite al `FilesViewModel` compartido.

import SwiftUI

struct FavoritesView: View {
    @ObservedObject var filesViewModel: FilesViewModel
    @ObservedObject var favoritesViewModel: FavoritesViewModel

    @State private var searchText: String = ""
    @State private var pendingDeletion: FileItem?
    @State private var pendingRename: FileItem?
    @State private var pendingRenameNewName: String = ""
    @State private var pendingMove: FileItem?

    init(
        filesViewModel: FilesViewModel,
        favoritesViewModel: FavoritesViewModel
    ) {
        self.filesViewModel = filesViewModel
        self.favoritesViewModel = favoritesViewModel
    }

    var body: some View {
        composedBody
    }

    // MARK: - Composition (split para evitar type-check timeout SwiftUI)

    private var composedBody: some View {
        withMoveSheet
    }

    private var baseNavigation: some View {
        NavigationStack {
            content
                .navigationTitle("Favoritos")
                .platformSearchableAutomatic(text: $searchText)
                .task {
                    if filesViewModel.files.isEmpty, filesViewModel.errorMessage == nil {
                        await filesViewModel.loadFiles()
                    }
                    favoritesViewModel.reload()
                }
                .onChange(of: filesViewModel.files.count) { _, _ in
                    favoritesViewModel.reload()
                }
        }
    }

    private var withRefresh: some View {
        baseNavigation
            .modifier(PlatformPullToRefreshModifier {
                await filesViewModel.loadFiles(showsLoadingState: false)
            })
    }

    private var withDeleteDialog: some View {
        withRefresh
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
                    Task { await filesViewModel.deleteFile(target) }
                }
                Button("Cancelar", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { _ in
                Text("Esta acción no se puede deshacer. El archivo se borrará permanentemente.")
            }
    }

    private var withRenameAlert: some View {
        withDeleteDialog
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
                    Task { await filesViewModel.renameFile(target, to: newName) }
                }
                Button("Cancelar", role: .cancel) {
                    pendingRename = nil
                    pendingRenameNewName = ""
                }
            } message: { item in
                Text("Introduce el nuevo nombre para «\(item.name)».")
            }
    }

    private var withMoveSheet: some View {
        withRenameAlert
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
                            Task { await filesViewModel.moveFile(target, to: destination) }
                        }
                    )
                }
            }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if visibleItems.isEmpty {
            if searchText.isEmpty && favoritesViewModel.items.isEmpty {
                FavoritesEmptyStateView()
            } else {
                EmptyStateView(
                    title: "Sin resultados",
                    message: "Ningún favorito coincide con la búsqueda.",
                    systemImage: "magnifyingglass"
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(visibleItems) { item in
                        rowView(for: item)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func rowView(for item: FileItem) -> some View {
        FileRowView(
            item: item,
            isDownloading: filesViewModel.isDownloading
                && filesViewModel.downloadingFileID == item.id,
            downloadProgress: filesViewModel.downloadProgress,
            onDownload: { filesViewModel.startDownload(item) },
            onCancelDownload: { filesViewModel.cancelCurrentDownload() },
            isFavorite: true,
            onToggleFavorite: { favoritesViewModel.toggle(entryId: item.id) },
            onTap: {
                // Solo carpetas son navegables; archivos no tienen
                // acción al tocar (la descarga va por su botón propio).
                if item.isFolder, !item.path.isEmpty {
                    filesViewModel.requestedFolderNavigation = item.path
                }
            },
            onRename: {
                pendingRenameNewName = item.name
                pendingRename = item
            },
            onMove: { pendingMove = item },
            onDelete: { pendingDeletion = item }
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Derivations

    private var visibleItems: [FileItem] {
        let favoriteIds = Set(favoritesViewModel.items.map(\.entryId))
        let raw = filesViewModel.files.filter { favoriteIds.contains($0.id) }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [FileItem]
        if trimmed.isEmpty {
            filtered = raw
        } else {
            filtered = raw.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func availableFolders(excluding item: FileItem) -> [String] {
        var paths: Set<String> = ["/"]
        for entry in filesViewModel.files where entry.isFolder && entry.id != item.id {
            if !entry.path.isEmpty { paths.insert(entry.path) }
        }
        return paths.sorted()
    }
}

private struct FavoritesEmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "star")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Sin favoritos")
                .font(.title3.weight(.semibold))
            Text("Toca la estrella en cualquier archivo o carpeta para añadirlo aquí.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
