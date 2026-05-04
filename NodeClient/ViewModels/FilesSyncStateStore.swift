import Foundation

struct FilesSyncSnapshot: Codable {
    let cursor: Int64
    let entries: [FilesSyncEntry]
}

struct FilesSyncEntry: Codable {
    let entryId: String
    let path: String
    let entryType: FsEntryResponse.EntryType
    let sizeBytes: Int64
    let checksum: String?
    let version: Int64
    let updatedAt: Date
    let deleted: Bool

    init(
        entryId: String,
        path: String,
        entryType: FsEntryResponse.EntryType,
        sizeBytes: Int64,
        checksum: String?,
        version: Int64,
        updatedAt: Date,
        deleted: Bool
    ) {
        self.entryId = entryId
        self.path = path
        self.entryType = entryType
        self.sizeBytes = sizeBytes
        self.checksum = checksum
        self.version = version
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    init(response: FsEntryResponse) {
        self.entryId = response.entryId
        self.path = response.path
        self.entryType = response.entryType
        self.sizeBytes = response.sizeBytes
        self.checksum = response.checksum
        self.version = response.version
        self.updatedAt = response.updatedAt
        self.deleted = response.deleted
    }

    var asResponse: FsEntryResponse {
        FsEntryResponse(
            entryId: entryId,
            path: path,
            entryType: entryType,
            sizeBytes: sizeBytes,
            checksum: checksum,
            version: version,
            updatedAt: updatedAt,
            deleted: deleted
        )
    }
}

protocol FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot?
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String)
    func clearSnapshot(namespace: String)
}

struct UserDefaultsFilesSyncStateStore: FilesSyncStateStore {
    static let snapshotKeyPrefix = "node.files.syncSnapshot"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        guard let data = userDefaults.data(forKey: snapshotKey(namespace: namespace)) else {
            return nil
        }
        return try? decoder.decode(FilesSyncSnapshot.self, from: data)
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        userDefaults.set(data, forKey: snapshotKey(namespace: namespace))
    }

    func clearSnapshot(namespace: String) {
        userDefaults.removeObject(forKey: snapshotKey(namespace: namespace))
    }

    private let userDefaults: UserDefaults

    private func snapshotKey(namespace: String) -> String {
        let sanitized = namespace
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        let effective = sanitized.isEmpty ? "anonymous" : sanitized
        return "\(Self.snapshotKeyPrefix).\(effective)"
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
