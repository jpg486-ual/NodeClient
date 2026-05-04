//  Vista principal del navegador de archivos. La divergencia iOS/macOS
//  vive en archivos separados (`FilesView+iOS.swift`, `FilesView+macOS.swift`)
//  vía extensiones — este archivo es platform-agnostic. Los miembros que
//  las extensiones necesitan acceder son `internal` (sin `private`).

import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @State var searchText = ""
    @StateObject var viewModel: FilesViewModel
    @StateObject var favoritesViewModel: FavoritesViewModel
    /// Pila de paths del `NavigationStack`. Vacía == raíz "/". Push al
    /// entrar en carpeta, pop por back button / swipe nativo iOS.
    ///
    /// Vive en el shell padre en lugar de como `@State` interno: en macOS,
    /// el detail panel del `NavigationSplitView` swappea entre FilesView y
    /// otros destinations cuando el usuario cambia la sidebar. Con `[String]`
    /// no vacío como `@State`, SwiftUI crashea durante el teardown con
    /// `AnyNavigationPath.Error.comparisonTypeMismatch` (try! interno al
    /// reconciliar el path). El shell mantiene el array vivo y lo vacía
    /// atómicamente con el cambio de selección — ver
    /// `MacRootShell.selectionBinding`.
    @Binding var folderStack: [String]
    @State var shareFileURL: URL?
    @State var isShareSheetPresented = false
    @State var featureNoticeMessage: String?
    @State var isNewFolderDialogPresented = false
    @State var newFolderName = ""
    @State var isFileImporterPresented = false
    @State var pendingDeletion: FileItem?
    @State var pendingRename: FileItem?
    @State var pendingRenameNewName: String = ""
    @State var pendingMove: FileItem?

    var activePath: String { folderStack.last ?? "/" }

    init(
        viewModel: FilesViewModel = Self.defaultViewModel(),
        favoritesViewModel: FavoritesViewModel = Self.defaultFavoritesViewModel(),
        folderStack: Binding<[String]>
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _favoritesViewModel = StateObject(wrappedValue: favoritesViewModel)
        _folderStack = folderStack
    }

    var body: some View {
        composedBody
    }

    private var composedBody: some View {
        platformShareSheetWrapper
    }

    var baseNavigation: AnyView {
        AnyView(
            NavigationStack(path: $folderStack) {
                folderContent(for: "/")
                    .navigationTitle("NodeClient")
                    .navigationDestination(for: String.self) { path in
                        folderContent(for: path)
                            .navigationTitle(folderTitle(for: path))
                    }
            }
            .onChange(of: folderStack) { _, _ in
                viewModel.setCurrentFolder(activePath)
            }
            // Consume la solicitud de navegación tanto al cambiar el
            // valor mientras la View ya está montada (caso TabView iOS,
            // ambas pestañas vivas) como al aparecer con un valor ya
            // pendiente (caso macOS NavigationSplitView: MacDetailHost
            // swappea destinos, así que FilesView se monta DESPUÉS de
            // que `requestedFolderNavigation` se haya seteado desde
            // FavoritesView — `.onChange` solo no basta porque no hay
            // transición observable). `.onAppear` cubre ese gap.
            .onChange(of: viewModel.requestedFolderNavigation) { _, _ in
                consumePendingFolderNavigation()
            }
            .onAppear {
                consumePendingFolderNavigation()
            }
        )
    }

    private func consumePendingFolderNavigation() {
        guard let path = viewModel.requestedFolderNavigation, !path.isEmpty else { return }
        if folderStack.last != path {
            folderStack.append(path)
        }
        viewModel.requestedFolderNavigation = nil
    }

    /// Última componente del path como display name. La raíz se rotula
    /// fija como "NodeClient" en `baseNavigation`.
    func folderTitle(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// `withSearchAndLoading` se construye sobre `platformRefreshable`
    /// (definido por plataforma en `FilesView+iOS.swift` /
    /// `FilesView+macOS.swift`). En iOS aplica `.refreshable`, en macOS
    /// devuelve la navegación base sin gesture-pull.
    var withSearchAndLoading: AnyView {
        AnyView(
            platformRefreshable
                .onChange(of: searchText) { _, newValue in
                    viewModel.updateSearchQuery(newValue)
                }
                .task {
                    if viewModel.files.isEmpty, viewModel.errorMessage == nil {
                        await viewModel.loadFiles()
                    }
                }
        )
    }

    /// Passthrough al chain de search/loading. Las alerts/dialogs/sheets
    /// user-facing **NO** se aplican aquí — viven en `applyNotificationModifiers`
    /// y se cuelgan dentro de `folderContent` para que el destino actual
    /// (raíz o subcarpeta) sea su anchor visible. Sin esto, SwiftUI
    /// difiere su presentación cuando hay un push de NavigationStack
    /// activo y se acumulan al volver al root.
    var withAlerts: AnyView {
        AnyView(withSearchAndLoading)
    }

    // `applyNotificationModifiers(_:)` y `availableFolders(excluding:)`
    // viven en `FilesView+Notifications.swift`.

    // `platformFileImporter`, `platformShareSheetWrapper`, `saveActionTitle`,
    // `handleSaveToFiles`, `platformRefreshable` y la wrappper toolbar viven
    // en `FilesView+iOS.swift` y `FilesView+macOS.swift`.

    @ViewBuilder
    func folderContent(for path: String) -> some View {
        applyNotificationModifiers(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let hintMessage = viewModel.downloadHintMessage {
                        recoveryHintBanner(message: hintMessage)
                    }

                    if viewModel.isUploading {
                        uploadProgressSection
                    }

                    filesStateSection(for: path)
                }
                .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
                platformExtraToolbarItems
            }
            .modifier(PlatformFolderEnhancementsModifier(searchText: $searchText, onRefresh: {
                await viewModel.loadFiles(showsLoadingState: false)
            }))
            // Drag-and-drop desde Finder al área visible del folder
            // (raíz o sub-carpeta). macOS-only en runtime; iOS deja el
            // modifier transparente. El bulk upload usa `currentFolderPath`
            // que ya está sincronizado con `activePath` via `.onChange`
            // del NavigationStack en `baseNavigation`.
            .platformFolderDropTarget(
                onDrop: { urls in
                    Task { await viewModel.uploadFiles(from: urls) }
                },
                onRejectedFolders: {
                    featureNoticeMessage = "Las carpetas no se pueden subir todavía. Sólo archivos individuales."
                }
            )
            .overlay(alignment: .bottomTrailing) {
                platformFloatingActionMenu
            }
        )
    }

    /// Banner prominente ancho completo cuando el
    /// servidor está reconstruyendo el archivo desde fragmentos remotos.
    /// Aparece tras 2s sin progreso (configurable). Tipografía clara,
    /// fondo destacado, spinner animado para confirmar actividad.
    private func recoveryHintBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Reconstruyendo archivo")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.orange.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconstruyendo archivo. \(message)")
    }

    private var uploadProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uploading file...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: viewModel.uploadProgress)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func filesStateSection(for path: String) -> some View {
        if viewModel.isLoading && viewModel.files.isEmpty {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
        } else if let errorMessage = viewModel.errorMessage {
            EmptyStateView(
                title: "No se puede mostrar contenido",
                message: errorMessage,
                systemImage: "exclamationmark.triangle"
            )
            .padding(.horizontal, 20)
        } else {
            let items = viewModel.filesForFolder(path)
            if items.isEmpty {
                EmptyStateView(
                    title: "Carpeta vacía",
                    message: "Cuando subas archivos aquí, se mostrarán automáticamente.",
                    systemImage: "tray"
                )
                .padding(.horizontal, 20)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        FileRowView(
                            item: item,
                            isDownloading: viewModel.isDownloading && viewModel.downloadingFileID == item.id,
                            downloadProgress: viewModel.downloadProgress,
                            onDownload: {
                                viewModel.startDownload(item)
                            },
                            onCancelDownload: {
                                viewModel.cancelCurrentDownload()
                            },
                            isFavorite: favoritesViewModel.isFavorite(entryId: item.id),
                            onToggleFavorite: {
                                favoritesViewModel.toggle(entryId: item.id)
                            },
                            onTap: {
                                if item.isFolder, !item.path.isEmpty {
                                    folderStack.append(item.path)
                                }
                            },
                            onRename: {
                                pendingRenameNewName = item.name
                                pendingRename = item
                            },
                            onMove: {
                                pendingMove = item
                            },
                            onDelete: {
                                pendingDeletion = item
                            }
                        )
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    private var sortMenu: some View {
        // Pickers en `.inline` dentro del Menu: SwiftUI renderiza ticks
        // nativos sobre la opción activa en iOS y macOS (el patrón previo
        // con `Label(systemImage:"checkmark")` se omitía en macOS porque
        // AppKit colapsa el `image` leading en items de NSMenu sin
        // selection state). Bindings de lectura/escritura puenteados a
        // `updateSortGroup` / `updateSortDirection` porque `sortMode` es
        // `private(set)` en el ViewModel.
        let groupBinding = Binding<FilesSortMode.Group>(
            get: { viewModel.sortMode.group },
            set: { viewModel.updateSortGroup($0) }
        )
        let directionBinding = Binding<FilesSortMode.Direction>(
            get: { viewModel.sortMode.direction },
            set: { viewModel.updateSortDirection($0) }
        )
        return Menu {
            Picker("Criterio", selection: groupBinding) {
                ForEach(FilesSortMode.Group.allCases, id: \.self) { group in
                    Text(group.title).tag(group)
                }
            }
            .pickerStyle(.inline)
            Picker("Dirección", selection: directionBinding) {
                ForEach(FilesSortMode.Direction.allCases, id: \.self) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Ordenar archivos")
    }

    var floatingActionMenu: some View {
        HStack(spacing: 12) {
            newFolderFAB
            uploadFAB
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    /// FAB iOS para nueva carpeta. El `.alert` va anclado al propio
    /// botón (no a la cadena central) para que la presentación
    /// funcione cuando el usuario está dentro de una subcarpeta —
    /// SwiftUI difiere alerts cuyo anchor está en una vista
    /// actualmente obscurecida por un push de NavigationStack.
    var newFolderFAB: some View {
        FloatingActionButton(systemImage: "folder.badge.plus") {
            isNewFolderDialogPresented = true
        }
        .accessibilityLabel("Nueva carpeta")
        .modifier(NewFolderAlertModifier(
            isPresented: $isNewFolderDialogPresented,
            newFolderName: $newFolderName
        ) { folderName in
            await viewModel.createFolder(named: folderName)
        })
    }

    /// FAB iOS para subir archivo. Mismo razonamiento que `newFolderFAB`.
    var uploadFAB: some View {
        FloatingActionButton(systemImage: "arrow.up.doc") {
            isFileImporterPresented = true
        }
        .accessibilityLabel("Subir archivo")
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImportListResult(result)
        }
    }

    /// Botón nueva carpeta para toolbar macOS. Mismo modificador
    /// que la FAB iOS, anclado al botón para que el alert se
    /// presente sobre el destino actual.
    var newFolderToolbarButton: some View {
        Button {
            isNewFolderDialogPresented = true
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .accessibilityLabel("Nueva carpeta")
        .help("Crear nueva carpeta en la ubicación actual")
        .modifier(NewFolderAlertModifier(
            isPresented: $isNewFolderDialogPresented,
            newFolderName: $newFolderName
        ) { folderName in
            await viewModel.createFolder(named: folderName)
        })
    }

    var uploadToolbarButton: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            Image(systemName: "arrow.up.doc")
        }
        .accessibilityLabel("Subir archivo")
        .help("Subir archivo a la ubicación actual")
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImportListResult(result)
        }
    }

    var generalStatusMessage: String? {
        featureNoticeMessage
            ?? viewModel.createFolderStatusMessage
            ?? viewModel.uploadStatusMessage
    }

    func clearGeneralStatus() {
        featureNoticeMessage = nil
        viewModel.clearCreateFolderStatus()
        viewModel.clearUploadStatus()
    }

    func handleFileImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            Task {
                await viewModel.uploadFile(from: url)
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

        case .failure(let error):
            featureNoticeMessage = "File selection failed: \(error.localizedDescription)"
        }
    }

    func handleFileImportListResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let firstURL = urls.first else {
                featureNoticeMessage = "No se seleccionó ningún archivo."
                return
            }
            handleFileImportResult(.success(firstURL))

        case .failure(let error):
            handleFileImportResult(.failure(error))
        }
    }

    // Factories `static func defaultViewModel()` etc. viven en
    // `FilesView+Factories.swift` para mantener este archivo navegable.
}

#Preview {
    StatefulPreviewWrapper([] as [String]) { binding in
        FilesView(folderStack: binding)
    }
}

/// Wrapper utilitario para Previews que necesitan un binding mutable.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}

/// Modifier que encapsula el alert "New Folder" con TextField. Se
/// ancla al botón que dispara la creación (FAB iOS o toolbar macOS)
/// para que la presentación funcione cuando el usuario está en una
/// subcarpeta — alerts cuyo anchor está en una vista obscurecida por
/// un push de NavigationStack se difieren hasta que el anchor vuelve
/// a ser visible (bug de SwiftUI + NavigationSplitView/NavigationStack).
private struct NewFolderAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var newFolderName: String
    let onCreate: (String) async -> Void

    func body(content: Content) -> some View {
        content.alert(
            "New Folder",
            isPresented: $isPresented,
            actions: {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let folderName = newFolderName
                    newFolderName = ""
                    Task { await onCreate(folderName) }
                }
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
            },
            message: {
                Text("Create a folder.")
            }
        )
    }
}
