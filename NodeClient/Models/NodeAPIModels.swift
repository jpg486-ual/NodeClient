import Foundation

struct AuthLoginRequest: Encodable {
    let username: String
    let password: String
}

struct AuthLoginResponse: Decodable {
    let token: String
    let username: String
    let quotaMb: Int
    let expiresAt: Date
    /// El backend devuelve `role` en login (END_USER, etc.).
    /// Optional para preservar compatibilidad con fixtures de tests.
    let role: String?

    init(token: String, username: String, quotaMb: Int, expiresAt: Date, role: String? = nil) {
        self.token = token
        self.username = username
        self.quotaMb = quotaMb
        self.expiresAt = expiresAt
        self.role = role
    }
}

/// Registro con código de invitación.
struct AuthRegisterRequest: Encodable {
    let invitationCode: String
    let username: String
    let password: String
}

/// Respuesta del backend tras `POST /auth/register`.
/// **No incluye token** — el cliente debe `login(...)` después.
struct AuthRegisterResponse: Decodable {
    let username: String
    let quotaMb: Int
}

/// Respuesta de `GET /auth/me`.
/// Backend expone `quotaUsedBytes` (live RS-inflated consumption,
/// computed server-side desde el FragmentPlacement port). Es opcional en
/// el decode para back-compat con servers que no lo emiten —
/// en ese caso, el cliente cae al cómputo desde snapshot SQLite local. 
/// Cuando está presente, debería preferirse al
/// cómputo local (live, multi-device coherent).
struct AuthProfileResponse: Decodable {
    let username: String
    let quotaMb: Int
    let quotaUsedBytes: Int64?
    let role: String?
}

/// Payload para `PATCH /fs/entries/{id}` (rename / move).
/// Campo canónico **`newPath`** (no `path` — el backend rechaza shape errónea
/// con `400 FS_PATCH_INVALID_REQUEST: "path must not be blank"`).
struct FsPatchEntryRequest: Encodable {
    let newPath: String
}

/// Payload para `POST /fs/entries/delete-subtree`.
/// El backend cascada: marca el directorio + todos los descendientes como
/// tombstones, purga manifests locales, libera quota y best-effort-borra
/// los manifests del tutor en una sola roundtrip. Necesario para carpetas
/// porque `DELETE /fs/entries/{id}` único deja huérfanos los hijos.
struct FsDeleteSubtreeRequest: Encodable {
    let path: String
}

struct FsDeleteSubtreeResponse: Decodable {
    let deletedEntries: [FsEntryResponse]
}

/// Payload para `POST /fs/entries/move-subtree`.
/// Atomicidad estricta: el tutor confirma el bulk update antes de tocar
/// nada local; si falla → 503 `FILESYSTEM_TUTOR_REPLICATION_FAILED` y
/// cero efecto local. Imprescindible para renombrar/mover carpetas con
/// hijos: `PATCH /fs/entries/{id}` único sólo cambia el path del nodo
/// padre, dejando los hijos colgados del path antiguo.
struct FsMoveSubtreeRequest: Encodable {
    let fromPath: String
    let toPath: String
}

struct FsMoveSubtreeResponse: Decodable {
    let movedEntries: [FsEntryResponse]
}

struct FsTreeResponse: Decodable {
    let username: String
    let cursor: Int64
    let snapshotAt: Date
    let entries: [FsEntryResponse]
}

struct FsEntryResponse: Decodable, Identifiable {
    enum EntryType: String, Codable {
        case file = "FILE"
        case directory = "DIRECTORY"
    }

    let entryId: String
    let path: String
    let entryType: EntryType
    let sizeBytes: Int64
    let checksum: String?
    let version: Int64
    let updatedAt: Date
    let deleted: Bool

    var id: String { entryId }
}

struct FsUpsertEntryRequest: Encodable {
    enum EntryType: String, Encodable {
        case file = "FILE"
        case directory = "DIRECTORY"
    }

    let entryId: String
    let path: String
    let entryType: EntryType
    let sizeBytes: Int64?
    let checksum: String?
    let deleted: Bool
}

struct FileUploadSessionCreateRequest: Encodable {
    let entryId: String
}

struct FileUploadSessionResponse: Decodable {
    let sessionId: String
    let entryId: String
    let uploadedBytes: Int64
    let expectedSizeBytes: Int64
    let status: String
    let updatedAt: Date
}

struct FileContentUploadResponse: Decodable {
    let entryId: String
    let sizeBytes: Int64
    let checksum: String
}

extension FsEntryResponse {
    var displayName: String {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmedPath.split(separator: "/")
        if let name = components.last, !name.isEmpty {
            return String(name)
        }
        return "/"
    }

    var detailText: String {
        switch entryType {
        case .directory:
            return "Carpeta"

        case .file:
            return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    var systemImage: String {
        entryType == .directory ? "folder.fill" : "doc"
    }

    var isFolder: Bool {
        entryType == .directory
    }
}
