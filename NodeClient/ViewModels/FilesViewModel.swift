import Combine
import CryptoKit
import Foundation
import OSLog

private let downloadLog = Logger(subsystem: "es.ual.NodeClient.app", category: "download")

private func appTokenFingerprint(_ token: String) -> String {
    guard !token.isEmpty else { return "<empty>" }
    let digest = SHA256.hash(data: Data(token.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(8))
}

enum FilesUIState: Equatable {
    case loading
    case empty
    case error(String)
    case content
}

enum FilesSortMode: String, CaseIterable {
    case nameAscending = "name.asc"
    case nameDescending = "name.desc"
    case dateModifiedDescending = "date.desc"
    case dateModifiedAscending = "date.asc"
    case sizeDescending = "size.desc"
    case sizeAscending = "size.asc"

    var title: String {
        switch self {
        case .nameAscending:
            return "Nombre A-Z"

        case .nameDescending:
            return "Nombre Z-A"

        case .dateModifiedDescending:
            return "Más recientes primero"

        case .dateModifiedAscending:
            return "Más antiguos primero"

        case .sizeDescending:
            return "Más grandes primero"

        case .sizeAscending:
            return "Más pequeños primero"
        }
    }

    enum Group: CaseIterable {
        case name
        case date
        case size

        var title: String {
            switch self {
            case .name: return "Nombre"
            case .date: return "Fecha de modificación"
            case .size: return "Tamaño"
            }
        }
    }

    enum Direction: CaseIterable {
        case ascending
        case descending

        var title: String {
            switch self {
            case .ascending: return "A-Z (Ascendente)"
            case .descending: return "Z-A (Descendente)"
            }
        }
    }

    var group: Group {
        switch self {
        case .nameAscending, .nameDescending: return .name
        case .dateModifiedAscending, .dateModifiedDescending: return .date
        case .sizeAscending, .sizeDescending: return .size
        }
    }

    var direction: Direction {
        switch self {
        case .nameAscending, .dateModifiedAscending, .sizeAscending: return .ascending
        case .nameDescending, .dateModifiedDescending, .sizeDescending: return .descending
        }
    }

    /// Compone modo desde criterio + dirección. ascending: A-Z / antiguo→reciente / pequeño→grande.
    static func mode(group: Group, direction: Direction) -> Self {
        switch (group, direction) {
        case (.name, .ascending): return .nameAscending
        case (.name, .descending): return .nameDescending
        case (.date, .ascending): return .dateModifiedAscending
        case (.date, .descending): return .dateModifiedDescending
        case (.size, .ascending): return .sizeAscending
        case (.size, .descending): return .sizeDescending
        }
    }
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published private(set) var files: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadStatusMessage: String?
    @Published private(set) var downloadedFileURL: URL?
    @Published private(set) var shareStatusMessage: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadingFileID: String?
    @Published private(set) var visibleFiles: [FileItem] = []
    @Published private(set) var searchQuery: String = ""
    @Published private(set) var sortMode: FilesSortMode = .nameAscending
    @Published private(set) var projectionComputationCount: Int = 0
    @Published private(set) var createFolderStatusMessage: String?
    @Published private(set) var uploadStatusMessage: String?
    @Published private(set) var isUploading = false
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var deleteStatusMessage: String?
    @Published private(set) var renameStatusMessage: String?
    @Published private(set) var moveStatusMessage: String?
    /// Última `loadFiles` terminó con 401 — leído por el foreground sync loop para forzar logout.
    @Published private(set) var lastSyncFailedAuth: Bool = false
    /// Path de la carpeta visible. `/` = raíz; `visibleFiles` filtra a sus hijos directos.
    @Published private(set) var currentFolderPath: String = "/"
    /// Mensaje de "reconstruyendo desde fragmentos" mostrado tras
    /// `recoveryHintDelay` sin progreso. Se limpia al primer chunk o
    /// al completar/fallar/cancelar el download.
    @Published private(set) var downloadHintMessage: String?
    @Published private(set) var downloadHintFileName: String?
    /// Propuesta pendiente cuando un upload colisiona con un entry vivo;
    /// la View presenta confirmation dialog y reusa el `entryId` previo
    /// para sobreescribir.
    @Published var pendingOverwrite: PendingOverwrite?

    var uiState: FilesUIState {
        if isLoading {
            return .loading
        }
        if let errorMessage {
            return .error(errorMessage)
        }
        return files.isEmpty ? .empty : .content
    }

    private let apiClient: NodeAPIClientProtocol
    private let sessionTokenProvider: () -> String?
    private let syncNamespaceProvider: () -> String
    private let filesRepository: FilesRepositoryProtocol
    /// Snapshot store consultado para lookup de paths (incluyendo
    /// `deleted=true`) durante upload — backend reserva paths y hay
    /// que reusar el entryId canónico al sobreescribir.
    private let syncStateStore: FilesSyncStateStore
    private let fileSaver: (Data, String) throws -> URL
    private let observabilityStore: ObservabilityStore
    private let clock: () -> Date
    private var currentDownloadTask: Task<Void, Never>?
    private var lastProjectionSignature: ProjectionSignature?
    /// Delay tras el inicio del download antes de emitir el hint
    /// "Reconstruyendo desde fragmentos…". Inyectable para tests.
    private let recoveryHintDelayNanos: UInt64
    private let recoveryHintSleeper: (UInt64) async -> Void
    private var currentRecoveryHintTask: Task<Void, Never>?
    /// Vault de cifrado (singleton prod, inyectable tests). Cifra/descifra si tiene `currentKey`.
    private let encryptionKeyVault: EncryptionKeyVault?
    /// Resolutor de la preferencia "comprimir antes de cifrar". Lee la
    /// flag en cada upload (no se cachea) para que un toggle Settings
    /// surta efecto inmediato sin reciclar el VM.
    private let compressionEnabledProvider: () -> Bool
    /// Devuelve los bytes disponibles en la cuota del usuario, o `nil`
    /// si no hay datos suficientes (sin login completo, perfil aún no
    /// fetched). Usado por `uploadFile` para fail-fast cuando el
    /// archivo seleccionado claramente no cabe — evita ciclos
    /// desperdiciados de compresión + cifrado + upload sólo para que
    /// el server rechace al final por cuota.
    private let availableQuotaBytesProvider: () -> Int64?
    /// Path de carpeta a la que el usuario quiere navegar desde otra
    /// vista (típicamente al tocar una carpeta favorita en
    /// `FavoritesView`). Los shells observan este valor para cambiar
    /// la tab/sidebar selection a Files; `FilesView` observa el valor
    /// para hacer push al `folderStack`. Quien procesa el request lo
    /// resetea a `nil`.
    @Published var requestedFolderNavigation: String?

    init(
        apiClient: NodeAPIClientProtocol,
        sessionTokenProvider: @escaping () -> String?,
        syncStateStore: FilesSyncStateStore? = nil,
        syncNamespaceProvider: @escaping () -> String = { "anonymous" },
        telemetryStore: SyncTelemetryStore? = nil,
        filesRepository: FilesRepositoryProtocol? = nil,
        syncRetryPolicy: SyncRetryPolicy = .default,
        recoveryHintDelayNanos: UInt64 = 2 * 1_000_000_000,
        recoveryHintSleeper: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        fileSaver: ((Data, String) throws -> URL)? = nil,
        observabilityStore: ObservabilityStore? = nil,
        clock: @escaping () -> Date = Date.init,
        encryptionKeyVault: EncryptionKeyVault? = nil,
        compressionEnabledProvider: @escaping () -> Bool = {
            UserDefaultsEncryptionPreferencesStore().compressionEnabled
        },
        availableQuotaBytesProvider: @escaping () -> Int64? = { nil },
        retrySleeper: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.apiClient = apiClient
        self.sessionTokenProvider = sessionTokenProvider
        self.syncNamespaceProvider = syncNamespaceProvider
        self.fileSaver = fileSaver ?? Self.defaultFileSaver
        self.observabilityStore = observabilityStore ?? UserDefaultsObservabilityStore()
        self.clock = clock
        self.recoveryHintDelayNanos = recoveryHintDelayNanos
        self.recoveryHintSleeper = recoveryHintSleeper
        self.encryptionKeyVault = encryptionKeyVault
        self.compressionEnabledProvider = compressionEnabledProvider
        self.availableQuotaBytesProvider = availableQuotaBytesProvider

        let resolvedSyncStore = syncStateStore ?? SQLiteFilesSyncStateStore()
        let resolvedTelemetry = telemetryStore ?? UserDefaultsSyncTelemetryStore()
        self.syncStateStore = resolvedSyncStore

        self.filesRepository = filesRepository ?? DefaultFilesRepository(
            apiClient: apiClient,
            syncStateStore: resolvedSyncStore,
            telemetryStore: resolvedTelemetry,
            retryPolicy: syncRetryPolicy,
            sleeper: retrySleeper
        )
    }

    func startDownload(_ file: FileItem) {
        guard currentDownloadTask == nil else {
            return
        }

        currentDownloadTask = Task { [weak self] in
            guard let self else { return }
            await downloadFile(file)
            await MainActor.run {
                self.currentDownloadTask = nil
            }
        }
    }

    func cancelCurrentDownload() {
        currentDownloadTask?.cancel()
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        refreshVisibleFilesIfNeeded()
    }

    /// Notificación desde la View cuando el `NavigationStack` cambia su
    /// path activo (push/pop). El VM actualiza `currentFolderPath` para
    /// que las acciones que dependen de la carpeta actual (createFolder,
    /// uploads, manifests) operen sobre el folder correcto.
    func setCurrentFolder(_ path: String) {
        let normalized = path.isEmpty ? "/" : path
        guard normalized != currentFolderPath else { return }
        currentFolderPath = normalized
        refreshVisibleFilesIfNeeded(force: true)
    }

    /// Filtro puro: archivos hijos directos del path dado, ordenados por
    /// el sortMode global. Si hay búsqueda activa, devuelve scope global
    /// (ignora el path) — patrón "el usuario espera encontrar el archivo
    /// dondequiera que esté".
    func filesForFolder(_ path: String) -> [FileItem] {
        let query = normalizedSearchQuery
        let filtered: [FileItem]
        if query.isEmpty {
            filtered = files.filter { item in
                Self.parentPath(of: item.path) == path
            }
        } else {
            filtered = files.filter { item in
                item.name.localizedCaseInsensitiveContains(query)
            }
        }
        return filtered.sorted(by: Self.makeStableComparator(sortMode: sortMode))
    }

    func updateSortMode(_ mode: FilesSortMode) {
        sortMode = mode
        refreshVisibleFilesIfNeeded()
    }

    /// Cambia el criterio (nombre / fecha / tamaño) preservando la
    /// dirección actual.
    func updateSortGroup(_ group: FilesSortMode.Group) {
        updateSortMode(FilesSortMode.mode(group: group, direction: sortMode.direction))
    }

    /// Cambia la dirección (asc / desc) preservando el criterio actual.
    func updateSortDirection(_ direction: FilesSortMode.Direction) {
        updateSortMode(FilesSortMode.mode(group: sortMode.group, direction: direction))
    }

    func loadFiles(showsLoadingState: Bool = true) async {
        lastSyncFailedAuth = false  // se vuelve true solo en el catch de .unauthorized
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            files = []
            visibleFiles = []
            observabilityStore.log(
                level: .warning,
                category: "sync",
                event: "sync.skipped",
                message: "No active session",
                metadata: [:]
            )
            errorMessage = "No active session. Please login first."
            return
        }

        let namespace = syncNamespaceProvider()
        let startedAt = Date()
        let cachedFiles = filesRepository.readCachedFiles(namespace: namespace)
        if !cachedFiles.isEmpty {
            files = cachedFiles
            refreshVisibleFilesIfNeeded(force: true)
        }

        // showsLoadingState=false durante pull-to-refresh: SwiftUI muestra
        // el indicador nativo del swipe encima del ScrollView, así que
        // setear isLoading=true reemplazaría la lista por un ProgressView
        // a medio gesto y dejaría el spinner del refresh huérfano.
        if showsLoadingState {
            isLoading = true
            errorMessage = nil
        }

        do {
            files = try await filesRepository.synchronizeFiles(token: token, namespace: namespace)
            refreshVisibleFilesIfNeeded(force: true)
            if !showsLoadingState {
                errorMessage = nil
            }
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("sync.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .info,
                category: "sync",
                event: "sync.succeeded",
                message: nil,
                metadata: ["durationMs": String(Int(duration)), "entries": String(files.count)]
            )
        } catch is CancellationError {
            // Cancelación legítima (SwiftUI invalida la Task del .refreshable
            // o del .task durante un gesto). No es un fallo de sync — salir
            // silenciosamente sin tocar errorMessage ni emitir sync.failed.
            if showsLoadingState {
                isLoading = false
            }
            return
        } catch let error as NodeAPIError {
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("sync.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .error,
                category: "sync",
                event: "sync.failed",
                message: Self.message(for: error),
                metadata: ["durationMs": String(Int(duration)), "namespace": namespace]
            )
            errorMessage = Self.message(for: error)
            if case .unauthorized = error { lastSyncFailedAuth = true }
        } catch {
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("sync.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .error,
                category: "sync",
                event: "sync.failed",
                message: "Unexpected error while loading files.",
                metadata: ["durationMs": String(Int(duration)), "namespace": namespace]
            )
            errorMessage = "Unexpected error while loading files."
        }

        if showsLoadingState {
            isLoading = false
        }
    }

    func downloadFile(_ file: FileItem) async {
        guard !file.isFolder else {
            downloadStatusMessage = "Folders cannot be downloaded."
            return
        }

        guard let token = sessionTokenProvider(), !token.isEmpty else {
            downloadStatusMessage = "No active session. Please login first."
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadingFileID = file.id
        downloadHintMessage = nil
        downloadHintFileName = nil

        // Lanzar tarea paralela que tras
        // `recoveryHintDelayNanos` ns, si el progreso sigue en 0%, setea
        // un mensaje informando al usuario que el nodo está reconstruyendo
        // el archivo desde fragmentos remotos. Cuando el primer chunk
        // llega vía `onProgress`, se cancela y se limpia el hint.
        scheduleRecoveryHint(forFileNamed: file.name)

        defer {
            isDownloading = false
            downloadingFileID = nil
            cancelRecoveryHint()
        }

        downloadLog.error("download start entryId=\(file.id, privacy: .public) name=\(file.name, privacy: .public) tokenLen=\(token.count, privacy: .public) tokenFP=\(appTokenFingerprint(token), privacy: .public)")
        do {
            // Pipeline unificado: detecta magic NCE1/NCE2/NCE3, descifra y
            // descomprime per-frame (el flag LZFSE vive dentro del frame
            // NCE3 — solo se descomprime lo marcado). Sin magic devuelve
            // los bytes tal cual. Con magic NCE3 y sin key disponible
            // throws `keyRequiredButMissing` que mapeamos a UX legible.
            let activeKey = encryptionKeyVault?.currentKey
            let transfer = makeEncryptedFileTransfer()
            let plaintext: Data
            do {
                plaintext = try await transfer.downloadAndMaybeDecrypt(
                    entryId: file.id,
                    token: token,
                    key: activeKey,
                    onProgress: { [weak self] progress in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            self.downloadProgress = progress
                            if progress > 0 {
                                // Llegó el primer chunk: el server ya
                                // está streaming, ocultamos el hint de
                                // reconstrucción.
                                self.cancelRecoveryHint()
                            }
                        }
                    }
                )
            } catch EncryptedFileTransferError.keyRequiredButMissing {
                downloadStatusMessage = "Este archivo está cifrado. Desbloquea el cifrado en Settings → Cifrado para abrirlo."
                downloadProgress = 0
                return
            } catch EncryptedFileTransferError.decryptionFailed {
                downloadStatusMessage = "No se pudo descifrar el archivo (¿token distinto al del upload?)."
                downloadProgress = 0
                return
            }

            let saveURL = try fileSaver(plaintext, file.name)
            downloadedFileURL = saveURL
            downloadProgress = 1.0
            observabilityStore.incrementCounter("download.success")
            observabilityStore.log(
                level: .info,
                category: "download",
                event: "download.succeeded",
                message: nil,
                metadata: ["entryId": file.id, "name": file.name]
            )
            downloadStatusMessage = "Descargado: \(saveURL.lastPathComponent)"
        } catch is CancellationError {
            downloadedFileURL = nil
            downloadProgress = 0
            observabilityStore.log(
                level: .warning,
                category: "download",
                event: "download.canceled",
                message: nil,
                metadata: ["entryId": file.id, "name": file.name]
            )
            downloadStatusMessage = "Descarga cancelada."
        } catch let error as NodeAPIError {
            downloadedFileURL = nil
            downloadProgress = 0
            observabilityStore.incrementCounter("download.failure")
            observabilityStore.log(
                level: .error,
                category: "download",
                event: "download.failed",
                message: Self.message(for: error),
                metadata: ["entryId": file.id, "name": file.name]
            )
            downloadLog.error("download FAIL entryId=\(file.id, privacy: .public) name=\(file.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            downloadStatusMessage = Self.message(for: error)
        } catch {
            downloadedFileURL = nil
            downloadProgress = 0
            observabilityStore.incrementCounter("download.failure")
            observabilityStore.log(
                level: .error,
                category: "download",
                event: "download.failed",
                message: "Error inesperado mientras se descargaba el archivo.",
                metadata: ["entryId": file.id, "name": file.name]
            )
            downloadLog.error("download FAIL entryId=\(file.id, privacy: .public) name=\(file.name, privacy: .public) unexpected=\(String(describing: error), privacy: .public)")
            downloadStatusMessage = "Error inesperado mientras se descargaba el archivo."
        }
    }

    func clearDownloadStatus() {
        downloadStatusMessage = nil
    }

    func clearDownloadedFileURL() {
        downloadedFileURL = nil
    }

    func completeShare(completed: Bool, errorDescription: String?) {
        if let errorDescription, !errorDescription.isEmpty {
            shareStatusMessage = "Exportación fallida: \(errorDescription)"
            return
        }

        shareStatusMessage = completed
            ? "Archivo exportado satisfactoriamente."
            : "Exportación cancelada."
    }

    func clearShareStatus() {
        shareStatusMessage = nil
    }

    func createFolder(named rawName: String) async {
        let folderName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else {
            createFolderStatusMessage = "El nombre de la carpeta no puede estar vacio."
            return
        }

        guard let token = sessionTokenProvider(), !token.isEmpty else {
            createFolderStatusMessage = "No hay una sesión activa. Inicia sesión."
            return
        }

        do {
            // Respetar la carpeta actual al crear sub-folders.
            let folderPath = Self.composePath(parent: currentFolderPath, name: folderName)
            let request = FsUpsertEntryRequest(
                entryId: UUID().uuidString,
                path: folderPath,
                entryType: .directory,
                sizeBytes: 0,
                checksum: nil,
                deleted: false
            )
            _ = try await apiClient.upsertEntry(token: token, request: request)
            observabilityStore.log(
                level: .info,
                category: "filesystem",
                event: "folder.created",
                message: nil,
                metadata: ["path": request.path]
            )
            createFolderStatusMessage = "Carpeta creada: \(folderName)"
            await loadFiles()
        } catch let error as NodeAPIError {
            observabilityStore.log(
                level: .error,
                category: "filesystem",
                event: "folder.create.failed",
                message: Self.message(for: error),
                metadata: ["name": folderName]
            )
            createFolderStatusMessage = Self.message(for: error)
        } catch {
            observabilityStore.log(
                level: .error,
                category: "filesystem",
                event: "folder.create.failed",
                message: "Error inesperado mientras se creaba la carpeta.",
                metadata: ["name": folderName]
            )
            createFolderStatusMessage = "Error inesperado mientras se creaba la carpeta."
        }
    }

    /// Elimina permanentemente la entrada (no recuperable).
    /// Carpetas → bulk subtree; archivos → DELETE dedicado.
    func deleteFile(_ file: FileItem) async {
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            deleteStatusMessage = "No hay una sesión activa. Inicia sesión."
            return
        }

        do {
            // Carpetas → `delete-subtree` cascada; archivos → DELETE single.
            if file.isFolder {
                guard !file.path.isEmpty else {
                    deleteStatusMessage = "No se puede eliminar la carpeta: ruta desconocida."
                    return
                }
                let response = try await apiClient.deleteSubtree(token: token, path: file.path)
                observabilityStore.log(level: .info, category: "filesystem", event: "entry.subtree.deleted", message: nil, metadata: ["path": file.path, "deletedCount": "\(response.deletedEntries.count)"])
                deleteStatusMessage = "Carpeta eliminada: \(file.name) (\(response.deletedEntries.count) entradas)"
            } else {
                try await apiClient.deleteEntry(token: token, entryId: file.id)
                observabilityStore.log(level: .info, category: "filesystem", event: "entry.deleted", message: nil, metadata: ["entryId": file.id, "path": file.path])
                deleteStatusMessage = "Archivo eliminado: \(file.name)"
            }
            await loadFiles()
        } catch let error as NodeAPIError {
            observabilityStore.log(level: .error, category: "filesystem", event: "entry.delete.failed", message: Self.message(for: error), metadata: ["entryId": file.id, "path": file.path])
            deleteStatusMessage = "No se ha podido eliminar \(file.name): \(Self.message(for: error))"
        } catch {
            observabilityStore.log(level: .error, category: "filesystem", event: "entry.delete.failed", message: "Unexpected error while deleting entry.", metadata: ["entryId": file.id, "path": file.path])
            deleteStatusMessage = "Cannot delete \(file.name): unexpected error."
        }
    }

    func clearDeleteStatus() {
        deleteStatusMessage = nil
    }

    /// Renombra cambiando la última componente. Carpetas → subtree move
    /// atómico; archivos → PATCH `{newPath}`.
    func renameFile(_ file: FileItem, to rawNewName: String) async {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            renameStatusMessage = "New name cannot be empty."
            return
        }
        guard !newName.contains("/") else {
            renameStatusMessage = "Name cannot contain '/'."
            return
        }
        guard newName != file.name else {
            renameStatusMessage = nil
            return
        }
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            renameStatusMessage = "No active session. Please login first."
            return
        }
        guard !file.path.isEmpty else {
            renameStatusMessage = "Cannot rename: path missing."
            return
        }

        let newPath = Self.replaceLastPathComponent(in: file.path, with: newName)

        do {
            if file.isFolder {
                _ = try await apiClient.moveSubtree(token: token, fromPath: file.path, toPath: newPath)
            } else {
                _ = try await apiClient.patchEntry(token: token, entryId: file.id, request: FsPatchEntryRequest(newPath: newPath))
            }
            observabilityStore.log(level: .info, category: "filesystem", event: file.isFolder ? "entry.subtree.renamed" : "entry.renamed", message: nil, metadata: ["entryId": file.id, "from": file.path, "to": newPath])
            renameStatusMessage = "Renamed to: \(newName)"
            await loadFiles()
        } catch let error as NodeAPIError {
            observabilityStore.log(level: .error, category: "filesystem", event: "entry.rename.failed", message: Self.message(for: error), metadata: ["entryId": file.id, "to": newPath])
            renameStatusMessage = "Cannot rename: \(Self.message(for: error))"
        } catch {
            renameStatusMessage = "Cannot rename: unexpected error."
        }
    }

    func clearRenameStatus() {
        renameStatusMessage = nil
    }

    /// Mueve a otra carpeta padre manteniendo el nombre. Carpetas → subtree
    /// move atómico; archivos → PATCH. "/" o
    /// vacío en `newParentPath` mueve a raíz.
    func moveFile(_ file: FileItem, to newParentPath: String) async {
        let trimmed = newParentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParent = Self.normalizeParentPath(trimmed)
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            moveStatusMessage = "No active session. Please login first."
            return
        }
        guard !file.path.isEmpty else {
            moveStatusMessage = "Cannot move: path missing."
            return
        }

        let newPath = Self.composePath(parent: normalizedParent, name: file.name)
        guard newPath != file.path else {
            moveStatusMessage = nil
            return
        }

        do {
            if file.isFolder {
                _ = try await apiClient.moveSubtree(token: token, fromPath: file.path, toPath: newPath)
            } else {
                _ = try await apiClient.patchEntry(token: token, entryId: file.id, request: FsPatchEntryRequest(newPath: newPath))
            }
            observabilityStore.log(level: .info, category: "filesystem", event: file.isFolder ? "entry.subtree.moved" : "entry.moved", message: nil, metadata: ["entryId": file.id, "from": file.path, "to": newPath])
            moveStatusMessage = "Moved to: \(newPath)"
            await loadFiles()
        } catch let error as NodeAPIError {
            moveStatusMessage = "Cannot move: \(Self.message(for: error))"
        } catch {
            moveStatusMessage = "Cannot move: unexpected error."
        }
    }

    func clearMoveStatus() {
        moveStatusMessage = nil
    }

    /// Bulk upload secuencial reusando `uploadFile(from:)`. Secuencial
    /// porque `isUploading`/`uploadingFileID` son globales y la concurrencia
    /// haría thrashing. Caller principal: drag-drop desde Finder en macOS.
    /// Si surge un `PendingOverwrite` el bucle se detiene hasta que el
    /// usuario resuelva el dialog (una colisión por batch ya invalida la
    /// premisa de "subir todo lo soltado").
    func uploadFiles(from urls: [URL]) async {
        for url in urls {
            await uploadFile(from: url)
            if pendingOverwrite != nil { break }
        }
    }

    func uploadFile(from fileURL: URL) async {
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            uploadStatusMessage = "No active session. Please login first."
            return
        }

        let fileName = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            uploadStatusMessage = "Invalid file name."
            return
        }

        // Stat el archivo en lugar de cargarlo en memoria.
        let plaintextSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            plaintextSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            uploadStatusMessage = "Cannot read selected file."
            return
        }

        // Pre-check de cuota: si el archivo plain ya excede el espacio
        // disponible, asumimos que tampoco caben con compresión
        // (raramente reduce >25% en archivos del usuario) ni con
        // overhead RS server-side (~+25% inflation). Fail-fast con
        // popup en vez de gastar ciclos en compresión + cifrado +
        // upload para que el server lo rechace al final.
        if let available = availableQuotaBytesProvider(), plaintextSize > available {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .file
            let fileSizeStr = formatter.string(fromByteCount: plaintextSize)
            let availableStr = formatter.string(fromByteCount: available)
            uploadStatusMessage =
                "El archivo (\(fileSizeStr)) excede tu espacio disponible (\(availableStr)). " +
                "Libera cuota borrando archivos antes de volver a intentarlo."
            return
        }

        // Cifrado opcional + lookup de path
        // existente para detectar colisiones antes de generar UUID nuevo.
        let activeKey = encryptionKeyVault?.currentKey
        let isEncrypted = activeKey != nil

        // Prepara el wire (cifra streaming a temp si key != nil; calcula
        // SHA-256 sin cargar el archivo en RAM). El caller recibe ya el
        // checksum y tamaño wire que el server validará en upsert.
        let transfer = makeEncryptedFileTransfer()
        let prepared: PreparedUpload
        do {
            prepared = try await transfer.prepareWireUpload(
                plaintextURL: fileURL,
                key: activeKey,
                compressIfBeneficial: compressionEnabledProvider()
            )
        } catch {
            uploadStatusMessage = isEncrypted
                ? "No se pudo cifrar el archivo: \(error.localizedDescription)"
                : "No se pudo procesar el archivo: \(error.localizedDescription)"
            return
        }

        let parentPath = currentFolderPath
        let fullPath = Self.composePath(parent: parentPath, name: fileName)

        // Si hay un entry previo en este path:
        //  - `deleted=true` → silent overwrite (revivir + actualizar).
        //  - `deleted=false` → request user confirmation antes de sobreescribir.
        if let existing = findExistingEntry(at: fullPath) {
            if existing.deleted {
                await performUpload(
                    token: token,
                    fileName: fileName,
                    prepared: prepared,
                    plaintextSize: plaintextSize,
                    fullPath: fullPath,
                    reusingEntryId: existing.entryId,
                    isEncrypted: isEncrypted
                )
                return
            }
            pendingOverwrite = PendingOverwrite(
                existingEntryId: existing.entryId,
                path: fullPath,
                fileName: fileName,
                prepared: prepared,
                plaintextSize: plaintextSize,
                isEncrypted: isEncrypted
            )
            return
        }

        // Camino normal: archivo nuevo, UUID fresco.
        await performUpload(
            token: token,
            fileName: fileName,
            prepared: prepared,
            plaintextSize: plaintextSize,
            fullPath: fullPath,
            reusingEntryId: nil,
            isEncrypted: isEncrypted
        )
    }

    /// Confirma la sobreescritura del archivo pendiente. La View **debe**
    /// pasar el `PendingOverwrite` capturado **antes** de que SwiftUI
    /// dismisse el `confirmationDialog` — la dismissal automática del
    /// dialog ejecuta `cancelPendingOverwrite()` vía la binding set, lo
    /// que borraría `pendingOverwrite` antes de que esta `Task` async
    /// pudiera leerlo. Capturando el parámetro en el closure síncrono
    /// del botón el race se evita.
    func confirmPendingOverwrite(_ pending: PendingOverwrite) async {
        guard let token = sessionTokenProvider(), !token.isEmpty else {
            uploadStatusMessage = "No active session. Please login first."
            pendingOverwrite = nil
            pending.prepared.cleanup()
            return
        }
        pendingOverwrite = nil
        await performUpload(
            token: token,
            fileName: pending.fileName,
            prepared: pending.prepared,
            plaintextSize: pending.plaintextSize,
            fullPath: pending.path,
            reusingEntryId: pending.existingEntryId,
            isEncrypted: pending.isEncrypted
        )
    }

    func cancelPendingOverwrite() {
        // Liberar el temp wire del prepared si el usuario cancela.
        pendingOverwrite?.prepared.cleanup()
        pendingOverwrite = nil
        uploadStatusMessage = nil
    }

    private func performUpload(
        token: String,
        fileName: String,
        prepared: PreparedUpload,
        plaintextSize: Int64,
        fullPath: String,
        reusingEntryId: String?,
        isEncrypted: Bool,
        retryBudget: Int = 1
    ) async {
        isUploading = true
        uploadProgress = 0
        // Cleanup del wire al final del flow normal; en retry recursivo o
        // transferencia a `pendingOverwrite`, el callee asume su ciclo.
        var transferredPrepared = false
        defer {
            isUploading = false
            if !transferredPrepared {
                prepared.cleanup()
            }
        }

        do {
            let entryId = reusingEntryId ?? UUID().uuidString
            let request = FsUpsertEntryRequest(
                entryId: entryId,
                path: fullPath,
                entryType: .file,
                sizeBytes: prepared.wireSize,
                checksum: prepared.wireChecksum,
                deleted: false
            )

            // El backend puede canonicalizar el `entryId`; usar el local
            // lleva a `404 FILE_UPLOAD_ENTRY_NOT_FOUND`.
            let upsertedEntry = try await apiClient.upsertEntry(token: token, request: request)
            let canonicalEntryId = upsertedEntry.entryId

            // Streaming con FileHandle: RAM peak constante (4 MiB / chunk
            // HTTP) sin importar el tamaño total, plain o NCE3.
            let transfer = makeEncryptedFileTransfer()
            _ = try await transfer.uploadFromPreparedWire(
                prepared: prepared,
                entryId: canonicalEntryId,
                token: token
            ) { @Sendable [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.uploadProgress = min(1.0, progress)
                }
            }
            uploadProgress = 1.0

            observabilityStore.incrementCounter("upload.success")
            observabilityStore.log(
                level: .info,
                category: "upload",
                event: "upload.succeeded",
                message: nil,
                metadata: [
                    "name": fileName,
                    "sizeBytes": String(prepared.wireSize),
                    "plaintextSize": String(plaintextSize),
                    "encrypted": isEncrypted ? "true" : "false"
                ]
            )
            uploadStatusMessage = isEncrypted
                ? "Upload completed (encrypted): \(fileName)"
                : "Upload completed: \(fileName)"
            await loadFiles()
        } catch let error as NodeAPIError {
            // Auto-recovery silencioso para 409 — solo upload. Política y
            // mapeo de códigos en `Self.uploadConflictRecovery(for:)`.
            if retryBudget > 0,
               case let .api(409, code, _) = error,
               let recovery = Self.uploadConflictRecovery(for: code) {
                observabilityStore.incrementCounter("upload.autoRetry.attempted")
                await silentRefreshTree(token: token)

                switch recovery {
                case .retrySameOperation:
                    transferredPrepared = true
                    await performUpload(
                        token: token,
                        fileName: fileName,
                        prepared: prepared,
                        plaintextSize: plaintextSize,
                        fullPath: fullPath,
                        reusingEntryId: reusingEntryId,
                        isEncrypted: isEncrypted,
                        retryBudget: retryBudget - 1
                    )
                    return

                case .resolvePathCollision:
                    if let existing = findExistingEntry(at: fullPath) {
                        if existing.deleted {
                            // Resucitar silenciosamente reusando el entryId.
                            transferredPrepared = true
                            await performUpload(
                                token: token,
                                fileName: fileName,
                                prepared: prepared,
                                plaintextSize: plaintextSize,
                                fullPath: fullPath,
                                reusingEntryId: existing.entryId,
                                isEncrypted: isEncrypted,
                                retryBudget: retryBudget - 1
                            )
                            return
                        }
                        // Path ocupado: disparar el diálogo PendingOverwrite.
                        // `prepared` se transfiere a la pending; su cleanup
                        // queda a cargo de confirm/cancel.
                        transferredPrepared = true
                        pendingOverwrite = PendingOverwrite(
                            existingEntryId: existing.entryId,
                            path: fullPath,
                            fileName: fileName,
                            prepared: prepared,
                            plaintextSize: plaintextSize,
                            isEncrypted: isEncrypted
                        )
                        return
                    }
                    // Refetch no revela el supuesto entry → fall-through al
                    // toast estándar. Algo extraño pero no enmascarable.
                }
            }

            uploadProgress = 0
            observabilityStore.incrementCounter("upload.failure")
            if retryBudget == 0 {
                observabilityStore.incrementCounter("upload.autoRetry.exhausted")
            }
            observabilityStore.log(
                level: .error,
                category: "upload",
                event: "upload.failed",
                message: Self.message(for: error),
                metadata: ["name": fileName, "sizeBytes": String(plaintextSize)]
            )
            uploadStatusMessage = Self.message(for: error)
        } catch {
            uploadProgress = 0
            observabilityStore.incrementCounter("upload.failure")
            observabilityStore.log(
                level: .error,
                category: "upload",
                event: "upload.failed",
                message: "Unexpected error while uploading file.",
                metadata: ["name": fileName, "sizeBytes": String(plaintextSize)]
            )
            uploadStatusMessage = "Unexpected error while uploading file."
        }
    }

    /// Refetch silencioso (no toca `isLoading`/`errorMessage`/hint UI).
    /// Best-effort: cualquier error se traga para que el caller del
    /// auto-recovery 409 decida desde el error original.
    private func silentRefreshTree(token: String) async {
        let namespace = syncNamespaceProvider()
        do {
            let refreshed = try await filesRepository.synchronizeFiles(token: token, namespace: namespace)
            files = refreshed
        } catch {
            // No-op intencional.
        }
    }

    /// Construye un `EncryptedFileTransfer` ad-hoc reusando el `apiClient`
    /// inyectado.
    private func makeEncryptedFileTransfer() -> EncryptedFileTransfer {
        EncryptedFileTransfer(apiClient: apiClient)
    }

    func clearCreateFolderStatus() {
        createFolderStatusMessage = nil
    }

    func clearUploadStatus() {
        uploadStatusMessage = nil
    }

    private static func defaultFileSaver(_ data: Data, _ suggestedName: String) throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        let sanitizedName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizedName.isEmpty ? "download.bin" : sanitizedName

        let targetURL = documentsURL.appendingPathComponent(baseName)

        try data.write(to: targetURL, options: [.atomic])
        return targetURL
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Programa el hint de reconstrucción para que
    /// se muestre tras `recoveryHintDelayNanos` si el progreso sigue en 0%.
    private func scheduleRecoveryHint(forFileNamed fileName: String) {
        currentRecoveryHintTask?.cancel()
        let delay = recoveryHintDelayNanos
        let sleeper = recoveryHintSleeper
        currentRecoveryHintTask = Task { [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.isDownloading,
                      self.downloadProgress == 0
                else { return }
                self.downloadHintFileName = fileName
                self.downloadHintMessage = "Reconstruyendo «\(fileName)» desde fragmentos del nodo. Esto puede tardar unos segundos."
            }
        }
    }

    /// Cancela el hint pendiente y limpia el mensaje. Llamado cuando llega
    /// el primer chunk del response stream o al completar/fallar/cancelar.
    private func cancelRecoveryHint() {
        currentRecoveryHintTask?.cancel()
        currentRecoveryHintTask = nil
        downloadHintMessage = nil
        downloadHintFileName = nil
    }

    /// Lookup de un entry en el snapshot SQLite local
    /// **incluyendo entries `deleted=true`**. El backend reserva paths de
    /// por vida — para sobreescribir un archivo previo (vivo o deleted)
    /// hay que reusar su `entryId` canónico, no generar uno nuevo.
    /// Devuelve nil si no hay entry para ese path.
    func findExistingEntry(at path: String) -> FilesSyncEntry? {
        guard let snapshot = syncStateStore.readSnapshot(namespace: syncNamespaceProvider()) else {
            return nil
        }
        return snapshot.entries.first { $0.path == path }
    }

    /// Sustituye la última componente de un path (`/foo/bar.txt` con
    /// `baz.txt` → `/foo/baz.txt`). Si el path no contiene `/` retorna
    /// `/<newName>`.
    static func replaceLastPathComponent(in path: String, with newName: String) -> String {
        let cleaned = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let lastSlash = cleaned.lastIndex(of: "/") else {
            return "/\(newName)"
        }
        let parent = String(cleaned[..<lastSlash])
        if parent.isEmpty {
            return "/\(newName)"
        }
        return "\(parent)/\(newName)"
    }

    /// Normaliza el `parent path` para `moveFile`: vacío/"/" → "/",
    /// "/foo/" → "/foo".
    static func normalizeParentPath(_ raw: String) -> String {
        if raw.isEmpty { return "/" }
        if raw == "/" { return "/" }
        if raw.hasSuffix("/") {
            return String(raw.dropLast())
        }
        return raw.hasPrefix("/") ? raw : "/\(raw)"
    }

    /// Compone un path completo a partir de un parent normalizado y un
    /// nombre de archivo: ("/foo", "bar.txt") → "/foo/bar.txt"; ("/", "bar.txt") → "/bar.txt".
    static func composePath(parent: String, name: String) -> String {
        if parent == "/" {
            return "/\(name)"
        }
        return "\(parent)/\(name)"
    }

    private static func message(for error: NodeAPIError) -> String {
        switch error {
        case .unauthorized:
            return "Session expired or invalid token."

        case .notFound:
            return "Resource not found."

        case .invalidURL, .invalidResponse:
            return "Invalid node configuration."

        case let .api(_, errorCode, message):
            switch errorCode {
            case "FILE_ENTRY_NOT_FOUND":
                return "File entry not found on node."

            case "FS_TREE_INVALID_REQUEST", "SYNC_INVALID_SINCE":
                return "Sync cursor is no longer valid. Please retry sync."

            case "FS_PATH_CONFLICT":
                return "A file or folder with the same path already exists."

            case "FILE_UPLOAD_ENTRY_NOT_FOUND":
                return "Target file entry does not exist for upload."

            case "FILE_UPLOAD_CHUNK_CONFLICT", "FILE_UPLOAD_COMPLETE_CONFLICT", "FILE_CONTENT_CONFLICT":
                return "Upload conflict detected. Retry the upload."

            // Subtree-move sólo persiste si el tutor confirma.
            case "FILESYSTEM_TUTOR_REPLICATION_FAILED":
                return "El tutor no está disponible. Inténtalo más tarde."

            case "FS_ENTRY_NOT_FOUND":
                return "La entrada ya no existe en el nodo."

            case "FS_DELETE_INVALID_REQUEST", "FS_MOVE_INVALID_REQUEST":
                return message ?? "Solicitud inválida sobre el subtree."

            default:
                return message ?? "Node returned error \(errorCode)."
            }

        case .server(let statusCode):
            return "Node returned status \(statusCode)."

        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }

    private func refreshVisibleFilesIfNeeded(force: Bool = false) {
        let signature = ProjectionSignature(
            fileIDs: files.map(\.id),
            query: normalizedSearchQuery,
            sortMode: sortMode,
            folderPath: currentFolderPath
        )

        if !force, signature == lastProjectionSignature {
            return
        }
        lastProjectionSignature = signature
        projectionComputationCount += 1

        let query = normalizedSearchQuery
        let folderPath = currentFolderPath

        // - **Sin búsqueda**: filtrar por carpeta actual (drill-down).
        // - **Con búsqueda**: scope global, ignora `currentFolderPath`
        //   (el usuario espera "encontrar el archivo dondequiera que esté").
        let filtered: [FileItem]
        if query.isEmpty {
            filtered = files.filter { item in
                Self.parentPath(of: item.path) == folderPath
            }
        } else {
            filtered = files.filter { item in
                item.name.localizedCaseInsensitiveContains(query)
            }
        }

        visibleFiles = filtered.sorted(by: Self.makeStableComparator(sortMode: sortMode))
    }

    /// Devuelve el path padre de una ruta absoluta. `/foo/bar.txt` → `/foo`;
    /// `/bar.txt` → `/`; `/` → `/`.
    /// Si el path es vacío devuelve `/` (raíz, fallback seguro).
    static func parentPath(of path: String) -> String {
        if path.isEmpty || path == "/" { return "/" }
        let cleaned = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let lastSlash = cleaned.lastIndex(of: "/") else { return "/" }
        let parent = String(cleaned[..<lastSlash])
        return parent.isEmpty ? "/" : parent
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeStableComparator(sortMode: FilesSortMode) -> (FileItem, FileItem) -> Bool {
        // Invariante de todos los modos: carpetas siempre arriba del resto.
        // Dentro de cada grupo (carpetas, archivos), aplica el criterio
        // del mode. El tie-break final es por nombre + id para estabilidad.
        { left, right in
            if left.isFolder != right.isFolder {
                return left.isFolder
            }

            switch sortMode {
            case .nameAscending:
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedAscending }

            case .nameDescending:
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedDescending }

            case .dateModifiedDescending:
                if let l = left.updatedAt, let r = right.updatedAt, l != r {
                    return l > r
                }
                if left.updatedAt != nil, right.updatedAt == nil { return true }
                if left.updatedAt == nil, right.updatedAt != nil { return false }
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedAscending }

            case .dateModifiedAscending:
                if let l = left.updatedAt, let r = right.updatedAt, l != r {
                    return l < r
                }
                if left.updatedAt != nil, right.updatedAt == nil { return true }
                if left.updatedAt == nil, right.updatedAt != nil { return false }
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedAscending }

            case .sizeDescending:
                if left.sizeBytes != right.sizeBytes {
                    return left.sizeBytes > right.sizeBytes
                }
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedAscending }

            case .sizeAscending:
                if left.sizeBytes != right.sizeBytes {
                    return left.sizeBytes < right.sizeBytes
                }
                let byName = left.name.localizedCaseInsensitiveCompare(right.name)
                if byName != .orderedSame { return byName == .orderedAscending }
            }

            return left.id < right.id
        }
    }
}
