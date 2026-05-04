import SwiftUI

struct FileItem: Identifiable {
    let id: String
    let name: String
    /// Path absoluto en el backend (`/folder/file.ext`). Necesario para
    /// invocar mutaciones (delete, rename) contra la API; los flows
    /// puramente UI (display, sort) usan sólo `name`. Default `""` para
    /// preservar fixtures existentes que no requieren path.
    let path: String
    let detail: String
    let systemImage: String
    let isFolder: Bool
    let isShared: Bool
    let isOffline: Bool
    /// Tamaño en bytes para el modo de orden por tamaño. 0 para carpetas
    /// y entries sin metadato (fixtures legacy).
    let sizeBytes: Int64
    /// Última modificación (backend `updatedAt`) para el modo de orden
    /// por fecha. `nil` en fixtures sin metadato → caen al final del
    /// orden por fecha.
    let updatedAt: Date?
    /// Versión incremental del backend (`FsEntryResponse.version`). `0`
    /// en fixtures legacy y entries sin metadato — el render oculta la
    /// "v0" para no ensuciar la UI.
    let version: Int64

    init(
        id: String = UUID().uuidString,
        name: String,
        path: String = "",
        detail: String,
        systemImage: String,
        isFolder: Bool,
        isShared: Bool,
        isOffline: Bool,
        sizeBytes: Int64 = 0,
        updatedAt: Date? = nil,
        version: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.detail = detail
        self.systemImage = systemImage
        self.isFolder = isFolder
        self.isShared = isShared
        self.isOffline = isOffline
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.version = version
    }
}

struct MoreItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}
